#!/usr/bin/env bash
# Launch a headless sway compositor and run Godot inside it (Wayland session
# used for every render / screenshot test).
# usage: run_sway.sh <scene|""> [godot args...]
set -u
GODOT=/home/user/tools/Godot_v4.7.2-stable_linux.x86_64
PROJECT=/home/user/eight_pages
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# --- clean leftovers (patterns avoid matching this script's own cmdline) ---
pgrep -f 'sway --unsupported[-]gpu' | xargs -r kill 2>/dev/null
pgrep -f 'Godot_v4[.]7[.]2' | xargs -r kill 2>/dev/null
sleep 0.5
rm -f "$XDG_RUNTIME_DIR"/wayland-* "$XDG_RUNTIME_DIR"/sway-ipc.*

WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman \
  sway --unsupported-gpu -c /home/user/tools/swaycfg/config > /tmp/sway.log 2>&1 &
SWAY_PID=$!

# wait for the wayland socket (max 10 s) and pick whichever name sway made
SOCK=""
for _ in $(seq 1 40); do
  SOCK=$(ls "$XDG_RUNTIME_DIR"/wayland-? 2>/dev/null | grep -v '\.lock$' | head -1)
  [ -n "$SOCK" ] && break
  sleep 0.25
done
if [ -z "$SOCK" ]; then
  echo "run_sway: sway failed to start"; tail -5 /tmp/sway.log; kill "$SWAY_PID" 2>/dev/null; exit 1
fi
export WAYLAND_DISPLAY=$(basename "$SOCK")
sleep 1

"$GODOT" --path "$PROJECT" --display-driver wayland --rendering-driver opengl3 \
  --resolution 1280x720 "$@" &
GODOT_PID=$!
echo "run_sway: sway=$SWAY_PID godot=$GODOT_PID display=$WAYLAND_DISPLAY"

# hard ceiling so a hung game can never stall the whole suite.
# NOTE: keep the watchdog's stdout closed, otherwise it keeps the caller's
# pipe open for the whole sleep duration.
( sleep 240; kill -9 $GODOT_PID 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
wait $GODOT_PID
CODE=$?
kill $WATCHDOG 2>/dev/null
wait $WATCHDOG 2>/dev/null
kill $SWAY_PID 2>/dev/null
wait 2>/dev/null
exit $CODE
