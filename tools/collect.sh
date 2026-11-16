#!/bin/bash
# collect.sh — build the arcade site: the static pages in site/ plus every
# studio game's newest build.
#
# A game is on the arcade when its repo has the `studio-game` topic and one of
# its full (non-draft, non-prerelease) GitHub Releases has a build: the studio
# template's release workflows attach them when a release is published.
#   web-build.zip               browser build, unpacked into games/<slug>/
#   windows-build.zip           desktop build, never on the site: tools/mirror.sh
#                               copies it into a public release on this repo
#   windows-build.zip.sha256    its checksum (else the asset's GitHub digest)
#   arcade.json                 card metadata {title, description, pitch,
#                               profiles, links}; else the copy in web-build.zip
#   arcade-cover.(png|jpg|webp) card cover; else the copy in web-build.zip
# The newest release with a build is used: when the newest release has none yet
# (its build is still running, or failed), the game stays on the arcade with the
# release before it.
#
# Usage: bash tools/collect.sh [--out DIR] [--mirror FILE] [--local DIR] [--state]
#                              [--min-games N] [--force]
#   --out DIR       where to write the site (default: _site)
#   --mirror FILE   write the desktop builds to mirror, one TSV row each, for
#                   tools/mirror.sh (slug, repo, tag, asset, bytes, updated_at,
#                   sha256, public tag, public file name)
#   --state         write nothing; print one line per game (repo, tag, upload
#                   times of its arcade assets, repo description): what the site would hold.
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

OUT=_site; MIRROR=""; LOCAL=""; STATE=0; TOPIC=studio-game; MIN_GAMES=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --mirror) MIRROR="$2"; shift 2 ;;
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

# Release assets the arcade uses. A release is listable when it has a build;
# the rest only add to it. Every one counts for change detection (--state).
BUILDS='["web-build.zip","windows-build.zip"]'
RECOGNISED='["web-build.zip","windows-build.zip","windows-build.zip.sha256","arcade.json","arcade-cover.png","arcade-cover.jpg","arcade-cover.webp"]'
# The public repo whose releases carry mirrored desktop builds (tools/mirror.sh).
ARCADE_REPO=${ARCADE_REPO:-${GITHUB_REPOSITORY:-Dont-Know-Studios/Arcade}}

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

# Choose the release to show: the newest full release with a build.
# Sets: rel (its JSON), tag, newest (the newest full release's tag), stamp.
resolve() {  # $1 full_name
  releases "$1" || die "GitHub API failed for $1 (after $RETRIES tries); stopping so the site doesn't lose the game"
  local pick
  pick=$(jq -c --argjson names "$BUILDS" '
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

has_asset() { printf '%s' "$rel" | jq -e --arg n "$1" 'any(.assets[]?; .name == $n)' >/dev/null; }
asset() { printf '%s' "$rel" | jq -c --arg n "$1" '[.assets[]? | select(.name == $n)][0] // {}'; }
need() {  # fetch_asset, or stop the run: a missing download must not drop the game
  fetch_asset "$full" "$tag" "$1" "$dl" ||
    die "download of $full $tag $1 failed (after $RETRIES tries); stopping so the site doesn't lose the game"
}

rm -rf "$OUT"; mkdir -p "$OUT/games" "$OUT/covers"
cp -R site/. "$OUT/"
: > "$WORK/games.jsonl"; : > "$WORK/state.txt"
[ -n "$MIRROR" ] && : > "$MIRROR"
list_repos

while IFS="$US" read -r full desc private; do
  [ -n "$full" ] || continue
  resolve "$full"
  if [ -z "$newest" ]; then printf 'skipped\t%s\tno published release\n' "$full"; continue; fi
  if [ -z "$tag" ]; then
    printf 'skipped\t%s\t%s has no web-build.zip or windows-build.zip, nor does any earlier release (see the release workflows in that repo)\n' "$full" "$newest"; continue
  fi
  note=""; [ "$tag" != "$newest" ] && note="newest release $newest has no build yet; showing $tag"
  printf '%s\t%s\t%s\t%s\n' "$full" "$tag" "$stamp" "$desc" >> "$WORK/state.txt"

  name="${full##*/}"
  slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g')
  dl="$WORK/$slug"; mkdir -p "$dl"
  web=0; has_asset web-build.zip && web=1
  win=0; has_asset windows-build.zip && win=1
  meta='{}'; cover=""; rev=""; size=0

  # The browser build: unpacked into games/<slug>/, played in play.html.
  if [ "$web" = 1 ]; then
    need web-build.zip
    dest="$OUT/games/$slug"; mkdir -p "$dest"
    if ! unzip -q -o "$dl/web-build.zip" -d "$dest" || [ ! -f "$dest/index.html" ]; then
      rm -rf "$dest"; web=0
      if [ "$win" = 0 ]; then printf 'skipped\t%s\t%s web-build.zip has no index.html at its top\n' "$full" "$tag"; continue; fi
      note="${note:+$note; }web-build.zip has no index.html at its top, so download only"
    fi
  fi
  if [ "$web" = 1 ]; then
    # Offline play: the build's file list (path, bytes) and a revision that changes
    # whenever any file does. The site's "Save for offline" downloads every file on
    # the list; a new revision tells saved copies to update.
    rm -f "$dest/arcade-files.json"
    ( cd "$dest" && find . -type f -printf '%P\t%s\n' | LC_ALL=C sort ) > "$WORK/$slug.files"
    rev=$( cd "$dest" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -c1-16 )
    jq -Rn --arg rev "$rev" '[inputs | split("\t") | [.[0], (.[1] | tonumber)]]
        | {rev: $rev, size: (map(.[1]) | add // 0), files: .}' "$WORK/$slug.files" > "$dest/arcade-files.json"
    size=$(jq '.size' "$dest/arcade-files.json")
    # Older games carry their card's metadata and cover inside the web build.
    [ -f "$dest/arcade.json" ] && meta=$(jq -c 'if type == "object" then . else {} end' "$dest/arcade.json" 2>/dev/null || echo '{}')
    for c in "$dest"/arcade-cover.*; do [ -f "$c" ] && cover="games/$slug/${c##*/}"; done
  fi

  # Standalone release assets win over the copies inside the web build.
  if has_asset arcade.json; then
    need arcade.json
    m=$(jq -c 'if type == "object" then . else empty end' "$dl/arcade.json" 2>/dev/null || true)
    if [ -n "$m" ]; then meta="$m"; else note="${note:+$note; }arcade.json is not a JSON object, ignored"; fi
  fi
  for ext in png jpg webp; do
    has_asset "arcade-cover.$ext" || continue
    need "arcade-cover.$ext"
    cp "$dl/arcade-cover.$ext" "$OUT/covers/$slug.$ext"; cover="covers/$slug.$ext"; break
  done

  # The Windows build: never on the site itself. tools/mirror.sh copies it into
  # a public release on this repo; the card links there.
  platforms='[]'
  if [ "$win" = 1 ]; then
    a=$(asset windows-build.zip)
    bytes=$(printf '%s' "$a" | jq '.size // 0')
    sha=""
    if has_asset windows-build.zip.sha256; then
      need windows-build.zip.sha256
      sha=$(head -c 200 "$dl/windows-build.zip.sha256" | tr -d '\r' | awk 'NR==1 {print tolower($1)}')
    fi
    [ -n "$sha" ] || sha=$(printf '%s' "$a" | jq -r '.digest // "" | select(startswith("sha256:")) | ltrimstr("sha256:")')
    printf '%s' "$sha" | grep -qE '^[0-9a-f]{64}$' || sha=""
    vtag=$(printf '%s' "$tag" | sed -E 's/[^A-Za-z0-9._-]+/-/g')
    pubtag="$slug-$vtag"; pubname="$name-$vtag-windows.zip"
    url="https://github.com/$ARCADE_REPO/releases/download/$pubtag/$pubname"
    platforms=$(jq -nc --arg file "$pubname" --argjson bytes "$bytes" --arg sha "$sha" --arg url "$url" \
      '[{os: "windows", file: $file, bytes: $bytes, sha256: (if $sha != "" then $sha else null end), url: $url}]')
    if [ -n "$MIRROR" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$full" "$tag" windows-build.zip "$bytes" \
        "$(printf '%s' "$a" | jq -r '.updated_at // ""')" "$sha" "$pubtag" "$pubname" >> "$MIRROR"
    fi
  fi

  # Release notes only link out for public repos: a private repo's page would 404 for players.
  notes=""; [ "$private" = false ] && notes=$(printf '%s' "$rel" | jq -r '.html_url // ""')
  pretty=$(printf '%s' "$name" | sed -E 's/[-_]+/ /g')

  jq -nc --arg slug "$slug" --arg pretty "$pretty" --arg desc "$desc" --arg cover "$cover" \
        --arg notes "$notes" --arg rev "$rev" --argjson size "$size" --argjson web "$web" \
        --argjson platforms "$platforms" --argjson meta "$meta" --argjson rel "$rel" '
    def known: ["desktop", "browser", "browser-mobile"];
    ($meta.profiles // [] | if type == "string" then [.] elif type == "array" then . else [] end
       | map(select(type == "string" and (. as $p | known | index($p))))) as $given
    | (if ($given | length) > 0 then $given
       else (if $web == 1 then ["browser-mobile"] else [] end) + (if ($platforms | length) > 0 then ["desktop"] else [] end)
       end) as $profiles
    | ($meta.links // {} | if type == "object" then . else {} end
       | with_entries(select((.value | type) == "string" and (.value | test("^https://[^\\s\"<>]+$"))))) as $links
    | {
      slug: $slug,
      title: (if ($meta.title // "") != "" then $meta.title else $pretty end),
      # Card text: release.description from the game, else the GitHub repo description,
      # else the pitch from the game brief.
      description: (if ($meta.description // "") != "" then $meta.description
                    elif $desc != "" then $desc else ($meta.pitch // "") end),
      version: (if ($rel.name // "") != "" then $rel.name else $rel.tag_name end),
      released: ($rel.published_at // ""),
      url: (if $web == 1 then "games/" + $slug + "/" else null end),
      cover: (if $cover != "" then $cover else null end),
      notes: (if $notes != "" then $notes else null end),
      kind: (if $web == 1 and ($platforms | length) > 0 then "both" elif $web == 1 then "web" else "desktop" end),
      profiles: $profiles
    }
    + (if $web == 1 then {rev: $rev, size: $size} else {} end)
    + (if ($platforms | length) > 0 then {platforms: $platforms} else {} end)
    + (if ($links | length) > 0 then {links: $links} else {} end)' >> "$WORK/games.jsonl"
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
