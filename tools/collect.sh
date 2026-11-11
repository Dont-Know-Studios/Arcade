#!/bin/bash
# collect.sh — build the arcade site: the static pages in site/ plus every
# studio game's newest web build.
#
# A game is on the arcade when its repo has the `studio-game` topic and its
# latest (full, non-draft) GitHub Release has a web-build.zip asset — the studio
# template's Web release workflow attaches one when a release is published.
#
# Usage: bash tools/collect.sh [--out DIR] [--local DIR]
#   --out DIR    where to write the site (default: _site)
#   --local DIR  read games from DIR instead of GitHub, for testing:
#                DIR/<repo>/web-build.zip and DIR/<repo>/release.json
#                ({"tag_name","name","published_at"}, optional "description")
#
# Needs: gh logged in with a token that can read the game repos (in Actions:
# the studio GitHub App's installation token), jq, unzip.
# Output: one TSV row per game seen — added <repo> <tag>, or skipped <repo> <why>.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT=_site; LOCAL=""; TOPIC=studio-game
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --local) LOCAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "collect: unknown argument: $1" >&2; exit 2 ;;
  esac
done

rm -rf "$OUT"; mkdir -p "$OUT/games"
cp -R site/. "$OUT/"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
: > "$WORK/games.jsonl"

# Rows: full_name <TAB> repo description <TAB> private(true/false)
list_repos() {
  if [ -n "$LOCAL" ]; then
    for d in "$LOCAL"/*/; do d="${d%/}"; n="${d##*/}"; [ -f "$d/release.json" ] || continue
      printf 'local/%s\t%s\t%s\n' "$n" "$(jq -r '.description // ""' "$d/release.json")" false
    done
  else
    gh api /installation/repositories --paginate \
      --jq ".repositories[] | select((.topics // []) | index(\"$TOPIC\")) | select(.archived | not)
            | [.full_name, (.description // \"\"), (.private|tostring)] | @tsv"
  fi
}

latest_release() {  # $1 full_name → release JSON on stdout, or nothing
  if [ -n "$LOCAL" ]; then cat "$LOCAL/${1#local/}/release.json"
  else gh api "repos/$1/releases/latest" 2>/dev/null || true; fi
}

fetch_zip() {  # $1 full_name, $2 tag, $3 dest dir
  if [ -n "$LOCAL" ]; then cp "$LOCAL/${1#local/}/web-build.zip" "$3/"
  else gh release download "$2" -R "$1" -p web-build.zip -D "$3" --clobber; fi
}

list_repos | sort | while IFS=$'\t' read -r full desc private; do
  [ -n "$full" ] || continue
  rel=$(latest_release "$full")
  tag=$(printf '%s' "$rel" | jq -r '.tag_name // empty' 2>/dev/null || true)
  if [ -z "$tag" ]; then printf 'skipped\t%s\tno published release\n' "$full"; continue; fi
  if [ -z "$LOCAL" ] && ! printf '%s' "$rel" | jq -e '.assets[]? | select(.name=="web-build.zip")' >/dev/null; then
    printf 'skipped\t%s\t%s has no web-build.zip (see the Web release workflow run in that repo)\n' "$full" "$tag"; continue
  fi

  name="${full##*/}"
  slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g')
  dl="$WORK/$slug"; mkdir -p "$dl"
  if ! fetch_zip "$full" "$tag" "$dl"; then printf 'skipped\t%s\tdownload of %s failed\n' "$full" "$tag"; continue; fi
  dest="$OUT/games/$slug"; mkdir -p "$dest"
  if ! unzip -q -o "$dl/web-build.zip" -d "$dest" || [ ! -f "$dest/index.html" ]; then
    rm -rf "$dest"; printf 'skipped\t%s\t%s web-build.zip has no index.html at its top\n' "$full" "$tag"; continue
  fi

  meta='{}'; [ -f "$dest/arcade.json" ] && meta=$(jq -c . "$dest/arcade.json" 2>/dev/null || echo '{}')
  cover=""
  for c in "$dest"/arcade-cover.*; do [ -f "$c" ] && cover="games/$slug/${c##*/}"; done
  # Release notes only link out for public repos: a private repo's page would 404 for players.
  notes=""; [ "$private" = false ] && notes=$(printf '%s' "$rel" | jq -r '.html_url // ""')
  pretty=$(printf '%s' "$name" | sed -E 's/[-_]+/ /g')

  jq -nc --arg slug "$slug" --arg pretty "$pretty" --arg desc "$desc" --arg cover "$cover" \
        --arg notes "$notes" --argjson meta "$meta" --argjson rel "$rel" '{
      slug: $slug,
      title: (if ($meta.title // "") != "" then $meta.title else $pretty end),
      description: (if ($meta.description // "") != "" then $meta.description else $desc end),
      version: (if ($rel.name // "") != "" then $rel.name else $rel.tag_name end),
      released: ($rel.published_at // ""),
      url: ("games/" + $slug + "/"),
      cover: (if $cover != "" then $cover else null end),
      notes: (if $notes != "" then $notes else null end)
    }' >> "$WORK/games.jsonl"
  printf 'added\t%s\t%s\n' "$full" "$tag"
done

jq -s --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{updated: $now, games: (sort_by(.released) | reverse)}' "$WORK/games.jsonl" > "$OUT/games.json"
touch "$OUT/.nojekyll"
echo "collect: $(jq '.games | length' "$OUT/games.json") game(s) in $OUT" >&2
