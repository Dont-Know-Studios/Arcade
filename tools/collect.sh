#!/bin/bash
# collect.sh — build the arcade site: the static pages in site/ plus every
# studio game's newest web build.
#
# A game is on the arcade when its repo has the `studio-game` topic and one of
# its full (non-draft, non-prerelease) GitHub Releases has a web-build.zip asset
# — the studio template's Web release workflow attaches one when a release is
# published. The newest such release is used: when the newest release has no
# web-build.zip yet (its build is still running, or failed), the game stays on
# the arcade with the release before it.
#
# Usage: bash tools/collect.sh [--out DIR] [--local DIR] [--state]
#                              [--min-games N] [--force]
#   --out DIR       where to write the site (default: _site)
#   --state         write nothing; print one line per game (repo, tag, build
#                   upload time, repo description): what the site would hold.
#                   The publish workflow compares it with the live site's
#                   arcade-state.txt and skips the deploy when nothing changed.
#   --min-games N   fail (exit 3, nothing usable in --out) when the site would
#                   hold fewer than N games. The publish workflow passes the
#                   live site's count, so a run that lost games never deploys.
#   --force         build even when fewer than --min-games games were found
#                   (a game was retired or renamed on purpose).
#   --local DIR     read games from DIR instead of GitHub, for testing (see
#                   tools/test-collect.sh). One folder per repo:
#                     DIR/<repo>/release.json + its assets (web-build.zip, …)
#                         one release: {"tag_name","name","published_at"},
#                         optional "description", "draft", "prerelease",
#                         "asset_times": {"<asset>": "<updated_at>"}
#                     DIR/<repo>/releases/<any>/release.json + its assets
#                         several releases, newest by published_at first
#                     DIR/<repo>/repo.json   optional {"description"}
#                     DIR/<repo>/FAIL-API    the repo's API call always fails
#                     DIR/<repo>/FLAKY-API   it fails once, then works
#
# GitHub API calls and downloads are retried (ARCADE_RETRIES tries, default 4,
# ARCADE_RETRY_DELAY seconds apart, growing). One that still fails stops the
# run with an error: a site built from partial answers would drop games.
#
# Needs: gh logged in with a token that can read the game repos (in Actions:
# the studio GitHub App's installation token), jq, unzip.
# Output: one TSV row per game seen — added <repo> <tag> [note], or
# skipped <repo> <why>.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT=_site; LOCAL=""; STATE=0; TOPIC=studio-game; MIN_GAMES=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --local) LOCAL="$2"; shift 2 ;;
    --state) STATE=1; shift ;;
    --min-games) MIN_GAMES="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "collect: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$MIN_GAMES" in ''|*[!0-9]*) echo "collect: --min-games needs a number" >&2; exit 2 ;; esac

RETRIES=${ARCADE_RETRIES:-4}; DELAY=${ARCADE_RETRY_DELAY:-5}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

retry() {  # run "$@" until it succeeds, RETRIES tries in all
  local i=1
  until "$@"; do
    if [ "$i" -ge "$RETRIES" ]; then return 1; fi
    echo "collect: failed, retrying ($i/$((RETRIES - 1))): $*" >&2
    sleep $((DELAY * i)); i=$((i + 1))
  done
}
die() { echo "collect: $*" >&2; exit 1; }

# A release asset the arcade can use.
RECOGNISED='["web-build.zip"]'

# Rows: full_name, repo description, private(true/false), joined by US (\x1f):
# a tab would collapse when the description is empty, shifting the fields.
US=$'\x1f'
gh_repos() {
  gh api /installation/repositories --paginate \
    --jq ".repositories[] | select((.topics // []) | index(\"$TOPIC\")) | select(.archived | not)
          | [.full_name, (.description // \"\" | gsub(\"[\\u001f\\n]\"; \" \")), (.private|tostring)] | join(\"\\u001f\")" > "$WORK/repos.raw"
}
list_repos() {  # → $WORK/repos, sorted
  if [ -n "$LOCAL" ]; then
    : > "$WORK/repos.raw"
    for d in "$LOCAL"/*/; do d="${d%/}"; n="${d##*/}"
      [ -f "$d/release.json" ] || [ -d "$d/releases" ] || continue
      desc=$(jq -r '.description // ""' "$d/repo.json" 2>/dev/null || true)
      [ -n "$desc" ] || desc=$(jq -r '.description // ""' "$d/release.json" 2>/dev/null || true)
      printf 'local/%s\037%s\037%s\n' "$n" "$desc" false >> "$WORK/repos.raw"
    done
  else
    retry gh_repos || die "could not list the studio's repos from GitHub; nothing built"
  fi
  sort "$WORK/repos.raw" > "$WORK/repos"
}

# Releases as GitHub's list API gives them (an array, assets included).
local_releases() {  # $1 full_name
  local d="$LOCAL/${1#local/}" r f
  if [ -f "$d/FAIL-API" ]; then echo "collect: (fixture) API error for $1" >&2; return 1; fi
  if [ -f "$d/FLAKY-API" ]; then rm -f "$d/FLAKY-API"; echo "collect: (fixture) one-off API error for $1" >&2; return 1; fi
  { [ -f "$d/release.json" ] && echo "$d"
    for r in "$d"/releases/*/; do [ -f "$r/release.json" ] && echo "${r%/}"; done; true; } |
  while read -r r; do
    for f in "$r"/*; do
      case "${f##*/}" in release.json|repo.json|FAIL-API|FLAKY-API|releases) continue ;; esac
      if [ -f "$f" ]; then printf '%s\t%s\n' "${f##*/}" "$(wc -c < "$f" | tr -d ' ')"; fi
    done | jq -Rn --slurpfile rel "$r/release.json" --arg dir "$r" '$rel[0] as $r | $r + {
        draft: ($r.draft // false), prerelease: ($r.prerelease // false),
        assets: [inputs | split("\t") | {name: .[0], size: (.[1] | tonumber),
                 updated_at: ($r.asset_times[.[0]] // $r.published_at), local_path: ($dir + "/" + .[0])}]}'
  done | jq -s '.'
}
local_releases_to() { local_releases "$1" > "$WORK/releases.json"; }
gh_releases() { gh api "repos/$1/releases?per_page=20" > "$WORK/releases.json"; }
releases() {  # $1 full_name → $WORK/releases.json, or fail
  if [ -n "$LOCAL" ]; then
    retry local_releases_to "$1"
  else
    retry gh_releases "$1"
  fi
}

# Choose the release to show: the newest full release with a recognised asset.
# Sets: rel (its JSON), tag, newest (the newest full release's tag), stamp.
resolve() {  # $1 full_name
  releases "$1" || die "GitHub API failed for $1 (after $RETRIES tries); stopping so the site doesn't lose the game"
  local pick
  pick=$(jq -c --argjson names "$RECOGNISED" '
      [.[] | select((.draft | not) and (.prerelease | not))] | sort_by(.published_at // "") | reverse
      | {newest: (.[0].tag_name // ""),
         use: (map(select(any(.assets[]?; .name as $n | $names | index($n)))) | .[0])}' "$WORK/releases.json")
  newest=$(printf '%s' "$pick" | jq -r '.newest')
  rel=$(printf '%s' "$pick" | jq -c '.use // {}')
  tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""')
  # What changes when a build is (re)uploaded: the recognised assets' upload times.
  stamp=$(printf '%s' "$rel" | jq -r --argjson names "$RECOGNISED" \
    '[.assets[]? | select(.name as $n | $names | index($n)) | .updated_at] | join(",")')
}

if [ "$STATE" = 1 ]; then
  list_repos
  while IFS="$US" read -r full desc private; do
    [ -n "$full" ] || continue
    resolve "$full"
    [ -n "$tag" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$full" "$tag" "$stamp" "$desc"
  done < "$WORK/repos"
  exit 0
fi

fetch_asset() {  # $1 full_name, $2 tag, $3 asset name, $4 dest dir
  if [ -n "$LOCAL" ]; then
    cp "$(printf '%s' "$rel" | jq -r --arg n "$3" '.assets[] | select(.name == $n) | .local_path')" "$4/"
  else
    retry gh release download "$2" -R "$1" -p "$3" -D "$4" --clobber
  fi
}

rm -rf "$OUT"; mkdir -p "$OUT/games"
cp -R site/. "$OUT/"
: > "$WORK/games.jsonl"; : > "$WORK/state.txt"
list_repos

while IFS="$US" read -r full desc private; do
  [ -n "$full" ] || continue
  resolve "$full"
  if [ -z "$newest" ]; then printf 'skipped\t%s\tno published release\n' "$full"; continue; fi
  if [ -z "$tag" ]; then
    printf 'skipped\t%s\t%s has no web-build.zip, nor does any earlier release (see the Web release workflow run in that repo)\n' "$full" "$newest"; continue
  fi
  note=""; [ "$tag" != "$newest" ] && note="newest release $newest has no web-build.zip yet; showing $tag"
  printf '%s\t%s\t%s\t%s\n' "$full" "$tag" "$stamp" "$desc" >> "$WORK/state.txt"

  name="${full##*/}"
  slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g')
  dl="$WORK/$slug"; mkdir -p "$dl"
  fetch_asset "$full" "$tag" web-build.zip "$dl" || die "download of $full $tag web-build.zip failed (after $RETRIES tries); stopping so the site doesn't lose the game"
  dest="$OUT/games/$slug"; mkdir -p "$dest"
  if ! unzip -q -o "$dl/web-build.zip" -d "$dest" || [ ! -f "$dest/index.html" ]; then
    rm -rf "$dest"; printf 'skipped\t%s\t%s web-build.zip has no index.html at its top\n' "$full" "$tag"; continue
  fi

  # Offline play: the build's file list (path, bytes) and a revision that changes
  # whenever any file does. The site's "Save for offline" downloads every file on
  # the list; a new revision tells saved copies to update.
  rm -f "$dest/arcade-files.json"
  ( cd "$dest" && find . -type f -printf '%P\t%s\n' | LC_ALL=C sort ) > "$WORK/$slug.files"
  rev=$( cd "$dest" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -c1-16 )
  jq -Rn --arg rev "$rev" '[inputs | split("\t") | [.[0], (.[1] | tonumber)]]
      | {rev: $rev, size: (map(.[1]) | add // 0), files: .}' "$WORK/$slug.files" > "$dest/arcade-files.json"
  size=$(jq '.size' "$dest/arcade-files.json")

  meta='{}'; [ -f "$dest/arcade.json" ] && meta=$(jq -c . "$dest/arcade.json" 2>/dev/null || echo '{}')
  cover=""
  for c in "$dest"/arcade-cover.*; do [ -f "$c" ] && cover="games/$slug/${c##*/}"; done
  # Release notes only link out for public repos: a private repo's page would 404 for players.
  notes=""; [ "$private" = false ] && notes=$(printf '%s' "$rel" | jq -r '.html_url // ""')
  pretty=$(printf '%s' "$name" | sed -E 's/[-_]+/ /g')

  jq -nc --arg slug "$slug" --arg pretty "$pretty" --arg desc "$desc" --arg cover "$cover" \
        --arg notes "$notes" --arg rev "$rev" --argjson size "$size" \
        --argjson meta "$meta" --argjson rel "$rel" '{
      slug: $slug,
      title: (if ($meta.title // "") != "" then $meta.title else $pretty end),
      # Card text: release.description from the game, else the GitHub repo description,
      # else the pitch from the game brief (packed into the build by its release).
      description: (if ($meta.description // "") != "" then $meta.description
                    elif $desc != "" then $desc else ($meta.pitch // "") end),
      version: (if ($rel.name // "") != "" then $rel.name else $rel.tag_name end),
      released: ($rel.published_at // ""),
      url: ("games/" + $slug + "/"),
      cover: (if $cover != "" then $cover else null end),
      notes: (if $notes != "" then $notes else null end),
      rev: $rev,
      size: $size
    }' >> "$WORK/games.jsonl"
  printf 'added\t%s\t%s\t%s\n' "$full" "$tag" "$note"
done < "$WORK/repos"

count=$(jq -s 'length' "$WORK/games.jsonl")
if [ "$count" -lt "$MIN_GAMES" ]; then
  if [ "$FORCE" = 1 ]; then
    echo "collect: $count game(s), fewer than the $MIN_GAMES required; building anyway (--force)" >&2
  else
    rm -rf "$OUT"
    echo "collect: only $count game(s) found but the live site has $MIN_GAMES; not building, so the site keeps them." >&2
    echo "collect: if a game was retired or renamed on purpose, run again with --force (Run workflow → force)." >&2
    exit 3
  fi
fi

jq -s --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{updated: $now, games: (sort_by(.released) | reverse)}' "$WORK/games.jsonl" > "$OUT/games.json"
cp "$WORK/state.txt" "$OUT/arcade-state.txt"
touch "$OUT/.nojekyll"
echo "collect: $count game(s) in $OUT" >&2
