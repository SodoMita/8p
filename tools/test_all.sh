#!/usr/bin/env bash
# One-shot verification: headless logic tests + sway (Wayland) render tests.
# Every check runs exactly once; output is captured and then inspected.
# usage: tools/test_all.sh [--with-web] [--with-android]
set -u
cd "$(dirname "$0")/.." || exit 1
GODOT=/home/user/tools/Godot_v4.7.2-stable_linux.x86_64
OUT=/tmp/eight_test_out
mkdir -p "$OUT"
FAIL=0
log() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; FAIL=1; }

run() { # run <tag> <cmd...>
  local tag=$1; shift
  "$@" >"$OUT/$tag.log" 2>&1
}

log "1/9 functional self-test (headless)"
run selftest "$GODOT" --headless --path . res://scenes/World.tscn -- --autotest=selftest
grep -E '^\[selftest\] (PASS|FAIL)' "$OUT/selftest.log" | tail -25
n_checks=$(grep -oE 'RESULT [0-9]+ passed, 0 failed' "$OUT/selftest.log" | grep -oE '[0-9]+' | head -1)
grep -q 'RESULT [0-9]\+ passed, 0 failed' "$OUT/selftest.log" && ok "selftest ($n_checks checks)" || bad "selftest"

log "2/9 handheld camera rig (headless)"
run camtest "$GODOT" --headless --path . res://scenes/World.tscn -- --autotest=camtest
grep -E '^\[camtest\] (PASS|FAIL)' "$OUT/camtest.log" | grep FAIL
n_rig=$(grep -cE '^\[camtest\] PASS' "$OUT/camtest.log")
grep -q 'RESULT [0-9]\+ passed, 0 failed' "$OUT/camtest.log" && ok "camera rig ($n_rig checks)" || bad "camera rig"

log "3/9 control paths: mouse, keyboard, touch, pause (headless)"
run controls "$GODOT" --headless --path . res://scenes/World.tscn -- --autotest=controls
grep -E '^\[controls\] (PASS|FAIL)' "$OUT/controls.log" | grep FAIL
n_ctl=$(grep -cE '^\[controls\] PASS' "$OUT/controls.log")
grep -q 'RESULT [0-9]\+ passed, 0 failed' "$OUT/controls.log" && ok "controls ($n_ctl checks)" || bad "controls"

log "4/9 full play-through: collect 8 pages -> win screen (headless)"
run win "$GODOT" --headless --path . res://scenes/World.tscn -- --autotest=win
grep -E '^\[autotest\]' "$OUT/win.log" | tail -4
grep -q 'win screen visible=true' "$OUT/win.log" && ok "win path" || bad "win path"

log "5/9 death path: chase -> jumpscare -> death screen (headless)"
run lose "$GODOT" --headless --path . res://scenes/World.tscn -- --autotest
grep -E 'dead=|lose path' "$OUT/lose.log" | tail -2
grep -q 'autotest lose path OK' "$OUT/lose.log" && ok "death path" || bad "death path"

log "6/9 title -> BEGIN -> world -> pause -> pickup (sway / Wayland)"
run flow bash tools/run_sway.sh res://scenes/Title.tscn -- --flow --quality=1
grep -E '^\[flow\]' "$OUT/flow.log"
grep -q 'RESULT PASS' "$OUT/flow.log" && ok "flow" || bad "flow"

log "7/9 screenshot tour inside sway (desktop)"
rm -rf /tmp/eight_verify/desktop
run shots env EIGHT_PAGES_SHOTS=/tmp/eight_verify/desktop \
  bash tools/run_sway.sh res://scenes/World.tscn -- --autotest=shots --quality=1
n_frames=$(grep -c '^\[autotest\] shot' "$OUT/shots.log")
grep -q 'shots done' "$OUT/shots.log" && ok "desktop shots ($n_frames frames)" || bad "desktop shots"

log "8/9 phone resolution + touch controls inside sway"
rm -rf /tmp/eight_verify/mobile
run mobile env EIGHT_PAGES_SHOTS=/tmp/eight_verify/mobile \
  bash tools/run_sway.sh res://scenes/World.tscn -- --autotest=shots --quality=0 --touch
grep -E 'touch stick vector' "$OUT/mobile.log"
grep -q 'shots done' "$OUT/mobile.log" && ok "mobile shots" || bad "mobile shots"
grep -q 'touch stick vector=(0.1' "$OUT/mobile.log" && ok "virtual stick input" || bad "virtual stick input"

log "9/9 endings: pause menu, jumpscare, death screen, win screen (sway)"
rm -rf /tmp/eight_verify/endings
run endings env EIGHT_PAGES_SHOTS=/tmp/eight_verify/endings \
  bash tools/run_sway.sh res://scenes/World.tscn -- --autotest=endings --quality=1
grep -q 'endings shots done' "$OUT/endings.log" && ok "endings shots" || bad "endings shots"
rm -rf /tmp/eight_verify/winscreen
run winscreen env EIGHT_PAGES_SHOTS=/tmp/eight_verify/winscreen \
  bash tools/run_sway.sh res://scenes/World.tscn -- --autotest=winscreen --quality=1
grep -q 'collected=8' "$OUT/winscreen.log" && ok "win screen shots" || bad "win screen shots"

for arg in "$@"; do
  case "$arg" in
    --with-web)
      log "web export"
      "$GODOT" --headless --path . --export-release "Web" build/web/index.html >"$OUT/web.log" 2>&1 \
        && ok "web export ($(du -h build/web/index.pck | cut -f1) pck + wasm)" || bad "web export"
      ;;
    --with-android)
      log "android export"
      "$GODOT" --headless --path . --export-release "Android" build/android/eight_pages.apk >"$OUT/android.log" 2>&1 \
        && ok "android export (build/android/eight_pages.apk)" || bad "android export (see $OUT/android.log)"
      ;;
  esac
done

printf '\n'
if [ $FAIL -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED (logs in $OUT)"; fi
exit $FAIL
