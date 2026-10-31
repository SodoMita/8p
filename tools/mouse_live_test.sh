#!/usr/bin/env bash
# Real-pointer end-to-end test: drives the ACTUAL X pointer with xdotool and asks
# the game whether its camera turned.
#
# This exists because injected InputEventMouseMotion is not the same thing as a
# real one. Injected events from a test carry position (0,0) and skip the GUI
# hover machinery; a real captured pointer sits at the centre of the screen,
# where a single non-IGNORE Control will swallow every motion event. That exact
# difference hid "mouse does not rotate the camera" from a green test suite.
#
# usage: tools/mouse_live_test.sh [--quality=N]
# needs: Xvfb, xdotool, a GL driver (llvmpipe is fine). Skips (exit 0) if absent.
set -u
cd "$(dirname "$0")/.." || exit 1
GODOT=${GODOT:-/home/user/tools/Godot_v4.7.2-stable_linux.x86_64}
QUALITY=1
for a in "$@"; do case "$a" in --quality=*) QUALITY=${a#--quality=};; esac; done

for bin in Xvfb xdotool; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP mouse_live: $bin not installed"; exit 0; }
done
[ -x "$GODOT" ] || { echo "SKIP mouse_live: no Godot at $GODOT"; exit 0; }

DISPLAY_ID=:97
LOG=/tmp/eight_mouse_live.log
Xvfb $DISPLAY_ID -screen 0 1280x720x24 >/tmp/eight_xvfb.log 2>&1 &
XPID=$!
trap 'kill $XPID 2>/dev/null' EXIT
sleep 1

export DISPLAY=$DISPLAY_ID
"$GODOT" --path . --rendering-driver opengl3 --resolution 1280x720 \
  res://scenes/World.tscn -- --autotest=mouselive --quality=$QUALITY >"$LOG" 2>&1 &
GPID=$!

# wait for the probe to say it is ready (llvmpipe is slow to boot)
for _ in $(seq 1 60); do
  grep -q '\[live\] READY' "$LOG" && break
  sleep 0.5
done
if ! grep -q '\[live\] READY' "$LOG"; then
  echo "FAIL mouse_live: the game never reached READY (see $LOG)"
  kill $GPID 2>/dev/null; exit 1
fi

# move the REAL pointer: 15 x 40 px to the right, the way a hand would
for _ in $(seq 1 15); do
  xdotool mousemove_relative -- 40 0
  sleep 0.2
done

# the probe prints progress every second and a RESULT at the end; take whichever
# is available so a slow renderer cannot make the test hang without a verdict
for _ in $(seq 1 24); do
  grep -q '\[live\] RESULT' "$LOG" && break
  sleep 0.5
done
kill $GPID 2>/dev/null

events=$(grep -oE 'events=[0-9]+' "$LOG" | grep -oE '[0-9]+' | tail -1)
yaw=$(grep -oE 'yaw_delta=-?[0-9.]+' "$LOG" | grep -oE '\-?[0-9.]+' | tail -1)
[ -z "${yaw:-}" ] && yaw=$(grep -oE 'yaw=-?[0-9.]+' "$LOG" | grep -oE '\-?[0-9.]+' | tail -1)
hovered=$(grep -oE 'hovered=[^ ]+' "$LOG" | head -1 | cut -d= -f2)

echo "real pointer: ${events:-0} motion events reached the game, camera yaw moved ${yaw:-0} rad"
[ -n "${hovered:-}" ] && echo "control under the captured pointer: $hovered"

fail=0
[ "${events:-0}" -ge 5 ] || { echo "FAIL mouse_live: the pointer produced no events at all"; fail=1; }
awk -v y="${yaw:-0}" 'BEGIN{exit !(y < -0.05)}' \
  && echo "PASS mouse_live: a real pointer move rotates the camera" \
  || { echo "FAIL mouse_live: events arrived but the camera did not turn (yaw $yaw)"; fail=1; }
exit $fail
