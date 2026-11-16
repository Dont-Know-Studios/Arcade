#!/bin/bash
# test-mirror.sh — check tools/mirror.sh with a stand-in `gh` that keeps
# releases in folders, so nothing touches GitHub.
#
# Usage: bash tools/test-mirror.sh
# Needs: jq, sha256sum.

set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# The stand-in gh. Source builds: $T/src/<repo>/<tag>/<asset>.
# This repo's releases: $T/pub/<tag>/{release.json,<assets>}. Calls go to $T/calls.
mkdir -p "$T/bin" "$T/src" "$T/pub"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "$*" >> "$FAKE/calls"
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "api repos/"*)
    for d in "$FAKE"/pub/*/; do [ -f "$d/release.json" ] || continue
      for f in "$d"*; do n="${f##*/}"; [ "$n" = release.json ] || printf '%s\t%s\n' "$n" "$(wc -c < "$f" | tr -d ' ')"; done |
        jq -Rn --slurpfile r "$d/release.json" '$r[0] + {assets: [inputs | split("\t") | {name: .[0], size: (.[1] | tonumber)}]}'
    done | jq -c . ;;
  "release download")
    repo=$(arg -R "$@"); p=$(arg -p "$@"); dir=$(arg -D "$@")
    cp "$FAKE/src/${repo##*/}/$3/$p" "$dir/" ;;
  "release create")
    mkdir -p "$FAKE/pub/$3"; n=$(ls "$FAKE/pub" | wc -l)
    jq -n --arg t "$3" --arg b "$(arg --notes "$@")" --arg c "2026-11-16T10:$(printf %02d "$n"):00Z" \
      '{tag_name: $t, body: $b, created_at: $c}' > "$FAKE/pub/$3/release.json" ;;
  "release upload")
    tag="$3"; shift 3
    for f in "$@"; do [ -f "$f" ] && cp "$f" "$FAKE/pub/$tag/"; done ;;
  "release edit")
    jq --arg b "$(arg --notes "$@")" '.body = $b' "$FAKE/pub/$3/release.json" > "$FAKE/x" && mv "$FAKE/x" "$FAKE/pub/$3/release.json" ;;
  "release delete")
    rm -rf "$FAKE/pub/$3" ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" FAKE="$T" SRC_TOKEN=s DEST_TOKEN=d ARCADE_REPO=Dont-Know-Studios/Arcade ARCADE_RETRY_DELAY=0

build() {  # $1 repo, $2 tag, $3 bytes → its sha256
  mkdir -p "$T/src/$1/$2"; head -c "$3" /dev/urandom > "$T/src/$1/$2/windows-build.zip"
  sha256sum "$T/src/$1/$2/windows-build.zip" | cut -d' ' -f1
}
plan() {  # $1 repo, $2 tag, $3 bytes, $4 sha (may be empty), $5 updated
  local slug; slug=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "Dont-Know-Studios/$1" "$2" windows-build.zip "$3" "$5" "$4" \
    "$slug-$2" "$1-$2-windows.zip" > "$T/plan.tsv"
}
site() {  # games.json with lastout's platform, sha256 $1 (or null)
  mkdir -p "$T/site"
  jq -n --arg s "$1" '{games: [{slug: "last-out", platforms: [{os: "windows", sha256: (if $s == "" then null else $s end)}]}]}' > "$T/site/games.json"
}
run() { bash tools/mirror.sh "$T/plan.tsv" "$T/site" > "$T/out" 2>&1; }

echo "== first copy"
s1=$(build Last-Out v1.0 3000); plan Last-Out v1.0 3000 "$s1" 2026-11-16T09:00:00Z; site "$s1"
check "runs"                       run
check "release made"               [ -f "$T/pub/last-out-v1.0/Last-Out-v1.0-windows.zip" ]
check "same bytes"                 cmp -s "$T/src/Last-Out/v1.0/windows-build.zip" "$T/pub/last-out-v1.0/Last-Out-v1.0-windows.zip"
check ".sha256 beside it"          grep -q "^$s1  Last-Out-v1.0-windows.zip$" "$T/pub/last-out-v1.0/Last-Out-v1.0-windows.zip.sha256"
check "marked as a mirror"         grep -q 'arcade-mirror: last-out' "$T/pub/last-out-v1.0/release.json"
check "not the repo's Latest"      grep -q -- '--latest=false' "$T/calls"

echo "== run again: nothing to do"
: > "$T/calls"
check "runs"                       run
check "no download or upload"      bash -c "! grep -q 'release \(download\|upload\|create\)' '$T/calls'"
check "says up to date"            grep -q 'up to date' "$T/out"

echo "== the same tag re-uploaded (new size)"
s1b=$(build Last-Out v1.0 3100); plan Last-Out v1.0 3100 "$s1b" 2026-11-16T09:30:00Z
check "runs"                       run
check "replaced"                   cmp -s "$T/src/Last-Out/v1.0/windows-build.zip" "$T/pub/last-out-v1.0/Last-Out-v1.0-windows.zip"

echo "== no checksum in the game's release: computed, and filled into games.json"
s2=$(build Last-Out v1.1 2000); plan Last-Out v1.1 2000 "" 2026-11-16T10:00:00Z; site ""
check "runs"                       run
check "games.json gets the sha"    [ "$(jq -r '.games[0].platforms[0].sha256' "$T/site/games.json")" = "$s2" ]
: > "$T/calls"; site ""
check "again: fill from notes"     run
check "  … without downloading"    bash -c "! grep -q 'release download' '$T/calls'"
check "  … sha filled"             [ "$(jq -r '.games[0].platforms[0].sha256' "$T/site/games.json")" = "$s2" ]

echo "== a third version: the oldest copy goes"
mkdir -p "$T/pub/other-v1"; jq -n '{tag_name: "other-v1", body: "not ours", created_at: "2026-01-01T00:00:00Z"}' > "$T/pub/other-v1/release.json"
s3=$(build Last-Out v1.2 2500); plan Last-Out v1.2 2500 "$s3" 2026-11-16T11:00:00Z; site "$s3"
check "runs"                       run
check "v1.2 there"                 [ -f "$T/pub/last-out-v1.2/Last-Out-v1.2-windows.zip" ]
check "v1.1 kept (one before)"     [ -d "$T/pub/last-out-v1.1" ]
check "v1.0 deleted"               [ ! -d "$T/pub/last-out-v1.0" ]
check "other releases untouched"   [ -d "$T/pub/other-v1" ]

echo "== a checksum that doesn't match"
build Last-Out v1.3 1000 >/dev/null; plan Last-Out v1.3 1000 "$(printf '0%.0s' {1..64})" 2026-11-16T12:00:00Z
check "stops"                      bash -c "! bash tools/mirror.sh '$T/plan.tsv' '$T/site' > '$T/out' 2>&1"
check "says why"                   grep -q 'does not match' "$T/out"
check "publishes nothing"          [ ! -f "$T/pub/last-out-v1.3/Last-Out-v1.3-windows.zip" ]

echo "== an empty plan"
: > "$T/plan.tsv"
check "runs, does nothing"         run

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
