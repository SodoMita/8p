#!/usr/bin/env bash
# Launch a headless sway compositor and run Godot inside it (Wayland session
# used for every render / screenshot test).
# usage: run_sway.sh <scene|""> [godot args...]
set -u
GODOT=/home/user/tools/Godot_v4.7.2-stable_linux.x86_64
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# --- clean leftovers (patterns avoid matching this script's own cmdline) ---
pgrep -f 'sway --unsupported[-]gpu' | xargs -r kill 2>/dev/null
pgrep -f 'Godot_v4[.]7[.]2' | xargs -r kill 2>/dev/null
sleep 0.5
rm -f "$XDG_RUNTIME_DIR"/wayland-* "$XDG_RUNTIME_DIR"/sway-ipc.*

# sway config: a bare headless output, no bar, no keybindings to steal input
SWAYCFG=$(mktemp -d)/config
cat > "$SWAYCFG" <<'CFG'
output * bg #000000 solid_color
output HEADLESS-1 resolution 1280x720 position 0 0
font pango:monospace 8
CFG
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman \
  sway --unsupported-gpu -c "$SWAYCFG" > /tmp/sway.log 2>&1 &
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

# GNU timeout owns the lifetime ceiling, so a completed preview does not leave
# a sleeping watchdog subprocess behind while the caller waits for cleanup.
timeout --kill-after=2s 240s "$GODOT" --path "$PROJECT" \
  --display-driver wayland --rendering-driver opengl3 --resolution 1280x720 "$@" &
GODOT_PID=$!
echo "run_sway: sway=$SWAY_PID godot=$GODOT_PID display=$WAYLAND_DISPLAY"
wait "$GODOT_PID"
CODE=$?
kill "$SWAY_PID" 2>/dev/null
wait 2>/dev/null
exit $CODE
