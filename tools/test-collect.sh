#!/bin/bash
# test-collect.sh — check tools/collect.sh against --local fixtures.
#
# Usage: bash tools/test-collect.sh [--keep DIR]
#   --keep DIR   also build a browsable site from the fixtures into DIR
#                (then: python3 -m http.server -d DIR)
#
# The fixtures are made here, in a temp folder, so the repo holds no zips:
#   alpha    one release, old fixture layout (release.json + web-build.zip)
#   beta     newest release has no web-build.zip yet → shows the one before
#   gamma    newest is a pre-release; the full release before it is shown
#   delta    the API fails once (FLAKY-API) → retried, still listed
#   epsilon  a release with no recognised asset → skipped
#   zeta     the API always fails (FAIL-API) → the run stops (own folder)
# Needs: jq, unzip, and zip or python3.

set -euo pipefail
cd "$(dirname "$0")/.."
KEEP=""; [ "${1:-}" = --keep ] && KEEP="$2"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export ARCADE_RETRY_DELAY=0
fails=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fails=$((fails + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

zipdir() {  # $1 folder → $2 zip with the folder's contents at its top
  local out; out="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
  if command -v zip >/dev/null; then (cd "$1" && zip -qr "$out" .)
  else python3 -c 'import os,sys,zipfile
src,out=sys.argv[1],sys.argv[2]
with zipfile.ZipFile(out,"w") as z:
  for d,_,fs in os.walk(src):
    for f in fs: p=os.path.join(d,f); z.write(p,os.path.relpath(p,src))' "$1" "$out"; fi
}
webzip() {  # $1 dest zip, $2 title, $3 colour
  local b="$T/build.$RANDOM"; mkdir -p "$b"
  cat > "$b/index.html" <<EOF
<!doctype html><meta charset="utf-8"><title>$2</title>
<body style="margin:0;display:grid;place-items:center;height:100vh;background:$3;color:#fff;font:24px sans-serif">$2</body>
EOF
  printf '{"title":"%s","pitch":"A fixture game called %s."}\n' "$2" "$2" > "$b/arcade.json"
  zipdir "$b" "$1"; rm -rf "$b"
}
release() {  # $1 dir, $2 tag, $3 published_at, [$4 extra JSON fields]
  mkdir -p "$1"
  jq -n --arg t "$2" --arg p "$3" --argjson x "${4:-{\}}" '{tag_name: $t, name: $t, published_at: $p} + $x' > "$1/release.json"
}

F="$T/games"
# alpha: the old layout, one release.
release "$F/alpha" v1.0 2026-11-01T10:00:00Z '{"description":"Alpha, old fixture layout."}'
webzip "$F/alpha/web-build.zip" Alpha '#2a6'
# beta: v2 is out but its web build hasn't been attached yet.
release "$F/beta/releases/1" v1.0 2026-11-02T10:00:00Z
webzip "$F/beta/releases/1/web-build.zip" Beta '#a62'
release "$F/beta/releases/2" v2.0 2026-11-10T10:00:00Z
echo "notes" > "$F/beta/releases/2/notes.txt"
# gamma: a newer pre-release is ignored.
release "$F/gamma/releases/1" v0.9 2026-11-03T10:00:00Z
webzip "$F/gamma/releases/1/web-build.zip" Gamma '#26a'
release "$F/gamma/releases/2" v1.0-rc1 2026-11-11T10:00:00Z '{"prerelease":true}'
webzip "$F/gamma/releases/2/web-build.zip" "Gamma RC" '#000'
# delta: one API failure, then fine.
release "$F/delta" v3.1 2026-11-04T10:00:00Z
webzip "$F/delta/web-build.zip" Delta '#a2a'
echo '{"description":"Delta, from repo.json."}' > "$F/delta/repo.json"
touch "$F/delta/FLAKY-API"
# epsilon: nothing the arcade can use.
release "$F/epsilon" v0.1 2026-11-05T10:00:00Z
echo "source" > "$F/epsilon/source.tar"

cp -R "$F" "$T/pristine"
reset() { rm -rf "$F"; cp -R "$T/pristine" "$F"; }

echo "== build"
out=$(bash tools/collect.sh --local "$F" --out "$T/site" 2>"$T/err") || { cat "$T/err"; bad "collect exits 0"; }
echo "$out" | sed 's/^/   | /'
G="$T/site/games.json"
check "4 games listed"            [ "$(jq '.games | length' "$G")" = 4 ]
check "alpha, old layout"         [ "$(jq -r '.games[] | select(.slug=="alpha") | .version' "$G")" = v1.0 ]
check "beta falls back to v1.0"   [ "$(jq -r '.games[] | select(.slug=="beta") | .version' "$G")" = v1.0 ]
check "beta fallback is noted"    grep -q $'^added\tlocal/beta\tv1.0\tnewest release v2.0' <<<"$out"
check "gamma skips pre-release"   [ "$(jq -r '.games[] | select(.slug=="gamma") | .version' "$G")" = v0.9 ]
check "delta retried and added"   grep -q 'retrying' "$T/err"
check "delta text from repo.json" [ "$(jq -r '.games[] | select(.slug=="delta") | .description' "$G")" = "Delta, from repo.json." ]
check "epsilon skipped"           grep -q $'^skipped\tlocal/epsilon\tv0.1 has no web-build.zip' <<<"$out"
check "builds unpacked"           [ -f "$T/site/games/beta/index.html" ]
check "state file, 4 lines"       [ "$(wc -l < "$T/site/arcade-state.txt")" = 4 ]

echo "== --state matches the built site"
reset
bash tools/collect.sh --local "$F" --state > "$T/state.txt" 2>/dev/null
check "--state = arcade-state.txt" cmp -s "$T/state.txt" "$T/site/arcade-state.txt"

echo "== fewer games than the live site"
reset
set +e; bash tools/collect.sh --local "$F" --out "$T/site2" --min-games 5 >/dev/null 2>"$T/err"; rc=$?; set -e
check "exits 3"                   [ "$rc" = 3 ]
check "leaves no site to deploy"  [ ! -e "$T/site2" ]
check "says why"                  grep -q 'live site has 5' "$T/err"
reset
check "--force builds anyway"     bash tools/collect.sh --local "$F" --out "$T/site2" --min-games 5 --force >/dev/null 2>&1
check "--min-games 4 is enough"   bash tools/collect.sh --local "$F" --out "$T/site3" --min-games 4 >/dev/null 2>&1

echo "== an API that keeps failing"
reset
mkdir -p "$T/broken"; cp -R "$F/alpha" "$T/broken/alpha"
release "$T/broken/zeta" v1.0 2026-11-06T10:00:00Z; touch "$T/broken/zeta/FAIL-API"
set +e; bash tools/collect.sh --local "$T/broken" --out "$T/site4" >/dev/null 2>"$T/err"; rc=$?
bash tools/collect.sh --local "$T/broken" --state >/dev/null 2>&1; src=$?; set -e
check "build stops (exit 1)"      [ "$rc" = 1 ]
check "--state stops too"         [ "$src" = 1 ]
check "names the repo"            grep -q 'GitHub API failed for local/zeta' "$T/err"

if [ -n "$KEEP" ]; then
  reset; bash tools/collect.sh --local "$F" --out "$KEEP" >/dev/null
  echo "site from the fixtures: $KEEP"
fi

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
