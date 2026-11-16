#!/bin/bash
# mirror.sh — copy desktop builds from the (often private) game repos into
# public releases on this repo, where the arcade's download buttons point.
#
# Usage: bash tools/mirror.sh PLAN [SITE]
#   PLAN   the TSV that `collect.sh --mirror PLAN` wrote (one row per build)
#   SITE   the built site (default _site): checksums missing from its
#          games.json are filled in from the mirrored files
#
# For each row: release <public tag> on ARCADE_REPO gets the build as
# <public file name> plus <public file name>.sha256. A release that already has
# the same source (repo, tag, size, upload time) is left alone. Then older
# mirrored releases of the same game are deleted, keeping the one in use and
# the one before it (pages still open, or a saved games.json, may link there).
# Only releases this script made are touched: their notes carry the line
# "arcade-mirror: <slug>".
#
# Env: SRC_TOKEN   reads the game repos (the studio GitHub App's token)
#      DEST_TOKEN  writes releases on ARCADE_REPO (the workflow's GITHUB_TOKEN,
#                  contents: write)
#      ARCADE_REPO default $GITHUB_REPOSITORY
#      ITCH_API_KEY (not used yet) — see push_itch below.
# Needs: gh, jq, sha256sum.

set -euo pipefail
PLAN="$1"; SITE="${2:-_site}"
DEST="${ARCADE_REPO:-${GITHUB_REPOSITORY:?set ARCADE_REPO}}"
: "${SRC_TOKEN:?}" "${DEST_TOKEN:?}"
RETRIES=${ARCADE_RETRIES:-4}; DELAY=${ARCADE_RETRY_DELAY:-5}; KEEP_OLDER=1
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

retry() {
  local i=1
  until "$@"; do
    if [ "$i" -ge "$RETRIES" ]; then return 1; fi
    echo "mirror: failed, retrying ($i/$((RETRIES - 1))): $*" >&2
    sleep $((DELAY * i)); i=$((i + 1))
  done
}
die() { echo "mirror: $*" >&2; exit 1; }
src()  { GH_TOKEN="$SRC_TOKEN" "$@"; }
dest() { GH_TOKEN="$DEST_TOKEN" "$@"; }
list_releases() { dest gh api "repos/$DEST/releases?per_page=100" --paginate --jq '.[]' > "$WORK/pub.jsonl"; }

# Hook for later: push the same build to itch.io with butler
# (`butler push <zip> <itch user>/<game>:windows --userversion <tag>`), with
# ITCH_API_KEY from this repo's secrets and the itch page from arcade.json's
# links.itch. Not set up yet, so it does nothing.
push_itch() { :; }

[ -s "$PLAN" ] || { echo "mirror: no desktop builds to mirror"; exit 0; }
retry list_releases || die "could not list $DEST's releases"

while IFS= read -r line; do
  # Split on a non-whitespace separator: tabs would merge around an empty field.
  IFS=$'\x1f' read -r slug full tag asset bytes updated sha pubtag pubname <<< "${line//$'\t'/$'\x1f'}"
  [ -n "$slug" ] || continue
  source_line="source: $full $tag $asset $bytes $updated"
  have=$(jq -c --arg t "$pubtag" 'select(.tag_name == $t)' "$WORK/pub.jsonl" | head -n 1)
  if [ -n "$have" ] &&
     printf '%s' "$have" | jq -e --arg s "$source_line" --arg n "$pubname" --argjson b "$bytes" '
       (.body // "" | split("\n") | map(sub("\r$"; "")) | index($s) != null)
       and any(.assets[]; .name == $n and .size == $b)
       and any(.assets[]; .name == ($n + ".sha256"))' >/dev/null; then
    echo "mirror: $pubtag/$pubname is up to date"
    sum=$(printf '%s' "$have" | jq -r '.body // "" | capture("(?m)^sha256: (?<s>[0-9a-f]{64})").s // ""')
  else
    echo "mirror: copying $full $tag $asset → $DEST $pubtag/$pubname"
    rm -rf "$WORK/dl"; mkdir -p "$WORK/dl"
    retry src gh release download "$tag" -R "$full" -p "$asset" -D "$WORK/dl" --clobber ||
      die "download of $full $tag $asset failed"
    got=$(wc -c < "$WORK/dl/$asset" | tr -d ' ')
    [ "$got" = "$bytes" ] || die "$full $tag $asset: downloaded $got bytes, the release says $bytes"
    sum=$(sha256sum "$WORK/dl/$asset" | cut -d' ' -f1)
    if [ -n "$sha" ] && [ "$sha" != "$sum" ]; then
      die "$full $tag $asset: SHA-256 $sum does not match the release's checksum $sha; not publishing it"
    fi
    mv "$WORK/dl/$asset" "$WORK/dl/$pubname"
    printf '%s  %s\n' "$sum" "$pubname" > "$WORK/dl/$pubname.sha256"
    body=$(printf 'Windows build of %s %s, copied here by the arcade'\''s Publish workflow so players can download it.\n\nThe build is not code-signed: Windows SmartScreen may warn. Check the download against the SHA-256 below.\n\narcade-mirror: %s\n%s\nsha256: %s\n' \
      "${full##*/}" "$tag" "$slug" "$source_line" "$sum")
    if [ -z "$have" ]; then
      retry dest gh release create "$pubtag" -R "$DEST" --title "${full##*/} $tag (Windows)" \
        --notes "$body" --latest=false || die "could not create release $pubtag"
    fi
    retry dest gh release upload "$pubtag" -R "$DEST" --clobber "$WORK/dl/$pubname" "$WORK/dl/$pubname.sha256" ||
      die "upload to $pubtag failed"
    # Notes last: they mark the release complete for the next run.
    retry dest gh release edit "$pubtag" -R "$DEST" --notes "$body" >/dev/null || die "could not update $pubtag's notes"
    push_itch "$slug" "$WORK/dl/$pubname" "$tag"
  fi

  # The site lists the checksum even when the game's release had none.
  if [ -n "$sum" ] && [ -f "$SITE/games.json" ]; then
    jq --arg slug "$slug" --arg sum "$sum" '(.games[] | select(.slug == $slug) | .platforms[]?
        | select(.os == "windows" and (.sha256 // "") == "")).sha256 = $sum' "$SITE/games.json" > "$WORK/g.json"
    mv "$WORK/g.json" "$SITE/games.json"
  fi

  # Keep the release in use and the newest one before it; delete older ones.
  jq -r --arg m "arcade-mirror: $slug" --arg t "$pubtag" '
      select((.body // "" | split("\n") | map(sub("\r$"; "")) | index($m) != null) and .tag_name != $t)
      | [.created_at, .tag_name] | @tsv' "$WORK/pub.jsonl" | sort -r | tail -n +$((KEEP_OLDER + 1)) | cut -f2 |
  while read -r old; do
    echo "mirror: deleting older $old"
    retry dest gh release delete "$old" -R "$DEST" --yes --cleanup-tag || echo "mirror: could not delete $old (left for next time)" >&2
  done
done < "$PLAN"
