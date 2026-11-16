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
#   lastout  desktop only: windows-build.zip (+ .sha256), standalone arcade.json
#            (profiles, itch link, an unsafe link) and arcade-cover.png
#   hybrid   both: web-build.zip and windows-build.zip (no .sha256); the
#            standalone arcade.json and cover win over the ones in the web build
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
png() { printf %s iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkqP9fDwAEsQHUxjFMAgAAAABJRU5ErkJggg== | base64 -d > "$1"; }
# lastout: a Windows game only (the shape the studio template will release).
release "$F/lastout/releases/1" v0.9 2026-11-06T10:00:00Z
head -c 5000 /dev/urandom > "$F/lastout/releases/1/windows-build.zip"
release "$F/lastout/releases/2" v1.0 2026-11-12T10:00:00Z '{"asset_times":{"windows-build.zip":"2026-11-12T11:00:00Z"}}'
head -c 123456 /dev/urandom > "$F/lastout/releases/2/windows-build.zip"
LASTOUT_SHA=$(sha256sum "$F/lastout/releases/2/windows-build.zip" | cut -d" " -f1)
printf '%s  windows-build.zip
' "$LASTOUT_SHA" > "$F/lastout/releases/2/windows-build.zip.sha256"
cat > "$F/lastout/releases/2/arcade.json" <<'EOF'
{"title":"Last Out","pitch":"Hold the last outpost.","profiles":["desktop"],
 "links":{"itch":"https://dont-know-studios.itch.io/last-out","steam":"javascript:alert(1)"}}
EOF
png "$F/lastout/releases/2/arcade-cover.png"
# hybrid: browser and Windows builds in one release.
release "$F/hybrid" v2.0 2026-11-13T10:00:00Z
b="$T/hybrid-web"; mkdir -p "$b"; echo "<!doctype html><title>Hybrid</title><body>Hybrid</body>" > "$b/index.html"
echo '{"title":"Old Hybrid title","pitch":"From inside the web build."}' > "$b/arcade.json"; png "$b/arcade-cover.png"
zipdir "$b" "$F/hybrid/web-build.zip"
head -c 4000 /dev/urandom > "$F/hybrid/windows-build.zip"
echo '{"title":"Hybrid","description":"Plays in the browser or on Windows.","profiles":"browser"}' > "$F/hybrid/arcade.json"
png "$F/hybrid/arcade-cover.png"

cp -R "$F" "$T/pristine"
reset() { rm -rf "$F"; cp -R "$T/pristine" "$F"; }

echo "== build"
out=$(bash tools/collect.sh --local "$F" --out "$T/site" --mirror "$T/mirror.tsv" 2>"$T/err") || { cat "$T/err"; bad "collect exits 0"; }
echo "$out" | sed 's/^/   | /'
G="$T/site/games.json"
check "6 games listed"            [ "$(jq '.games | length' "$G")" = 6 ]
check "alpha, old layout"         [ "$(jq -r '.games[] | select(.slug=="alpha") | .version' "$G")" = v1.0 ]
check "beta falls back to v1.0"   [ "$(jq -r '.games[] | select(.slug=="beta") | .version' "$G")" = v1.0 ]
check "beta fallback is noted"    grep -q $'^added\tlocal/beta\tv1.0\tnewest release v2.0' <<<"$out"
check "gamma skips pre-release"   [ "$(jq -r '.games[] | select(.slug=="gamma") | .version' "$G")" = v0.9 ]
check "delta retried and added"   grep -q 'retrying' "$T/err"
check "delta text from repo.json" [ "$(jq -r '.games[] | select(.slug=="delta") | .description' "$G")" = "Delta, from repo.json." ]
check "epsilon skipped"           grep -q $'^skipped\tlocal/epsilon\tv0.1 has no web-build.zip' <<<"$out"
check "builds unpacked"           [ -f "$T/site/games/beta/index.html" ]
check "state file, 6 lines"       [ "$(wc -l < "$T/site/arcade-state.txt")" = 6 ]
q() { jq -r --arg s "$1" '.games[] | select(.slug == $s) | '"$2" "$G"; }
echo "== web, desktop and both games"
check "alpha: kind web"           [ "$(q alpha .kind)" = web ]
check "alpha: browser-mobile"     [ "$(q alpha '.profiles | join(",")')" = browser-mobile ]
check "alpha: no platforms"       [ "$(q alpha '.platforms // "none"')" = none ]
check "alpha: still has rev"      [ -n "$(q alpha .rev)" ]
check "lastout: kind desktop"     [ "$(q lastout .kind)" = desktop ]
check "lastout: v1.0"             [ "$(q lastout .version)" = v1.0 ]
check "lastout: no url, no rev"   [ "$(q lastout '[.url, .rev] | map(. // "x") | join("")')" = xx ]
check "lastout: title from json"  [ "$(q lastout .title)" = "Last Out" ]
check "lastout: pitch as text"    [ "$(q lastout .description)" = "Hold the last outpost." ]
check "lastout: profiles"         [ "$(q lastout '.profiles | join(",")')" = desktop ]
check "lastout: windows bytes"    [ "$(q lastout '.platforms[0].bytes')" = 123456 ]
check "lastout: sha256 from file" [ "$(q lastout '.platforms[0].sha256')" = "$LASTOUT_SHA" ]
check "lastout: public url"       [ "$(q lastout '.platforms[0].url')" = "https://github.com/Dont-Know-Studios/Arcade/releases/download/lastout-v1.0/lastout-v1.0-windows.zip" ]
check "lastout: itch link kept"   [ "$(q lastout .links.itch)" = "https://dont-know-studios.itch.io/last-out" ]
check "lastout: unsafe link gone" [ "$(q lastout '.links.steam // "gone"')" = gone ]
check "lastout: standalone cover" [ "$(q lastout .cover)" = covers/lastout.png ] && [ -f "$T/site/covers/lastout.png" ]
check "lastout: no binary on site" [ -z "$(find "$T/site" -name '*windows*')" ]
check "hybrid: kind both"         [ "$(q hybrid .kind)" = both ]
check "hybrid: standalone title"  [ "$(q hybrid .title)" = Hybrid ]
check "hybrid: profile string ok" [ "$(q hybrid '.profiles | join(",")')" = browser ]
check "hybrid: standalone cover"  [ "$(q hybrid .cover)" = covers/hybrid.png ]
check "hybrid: no sha → null"     [ "$(q hybrid '.platforms[0].sha256')" = null ]
check "hybrid: playable"          [ "$(q hybrid .url)" = games/hybrid/ ]
check "mirror plan: 2 builds"     [ "$(wc -l < "$T/mirror.tsv")" = 2 ]
check "mirror plan: lastout row"  grep -q $'^lastout\tlocal/lastout\tv1.0\twindows-build.zip\t123456\t2026-11-12T11:00:00Z\t'"$LASTOUT_SHA"$'\tlastout-v1.0\tlastout-v1.0-windows.zip$' "$T/mirror.tsv"
check "state counts every asset"  grep -qE $'^local/lastout\tv1.0\t([^\t]*,)?2026-11-12T11:00:00Z[,\t]' "$T/site/arcade-state.txt"

echo "== --state matches the built site"
reset
bash tools/collect.sh --local "$F" --state > "$T/state.txt" 2>/dev/null
check "--state = arcade-state.txt" cmp -s "$T/state.txt" "$T/site/arcade-state.txt"

echo "== fewer games than the live site"
reset
set +e; bash tools/collect.sh --local "$F" --out "$T/site2" --min-games 7 >/dev/null 2>"$T/err"; rc=$?; set -e
check "exits 3"                   [ "$rc" = 3 ]
check "leaves no site to deploy"  [ ! -e "$T/site2" ]
check "says why"                  grep -q 'live site has 7' "$T/err"
reset
check "--force builds anyway"     bash tools/collect.sh --local "$F" --out "$T/site2" --min-games 7 --force >/dev/null 2>&1
check "--min-games 6 is enough"   bash tools/collect.sh --local "$F" --out "$T/site3" --min-games 6 >/dev/null 2>&1

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
