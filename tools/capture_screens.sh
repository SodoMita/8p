#!/usr/bin/env bash
# Full screenshot capture inside headless sway: title screen, gameplay tour,
# pause / jumpscare / death, and the win screen.
set -u
GODOT=/home/user/tools/Godot_v4.7.2-stable_linux.x86_64
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SHOTS=$PROJECT/screenshots
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" "$SHOTS"
chmod 700 "$XDG_RUNTIME_DIR"

cleanup() {
  [ -n "${GPID:-}" ] && kill "$GPID" 2>/dev/null
  [ -n "${SWAY_PID:-}" ] && kill "$SWAY_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

SWAYCFG=$(mktemp -d)/config
cat > "$SWAYCFG" <<'CFG'
output * bg #000000 solid_color
output HEADLESS-1 resolution 1280x720 position 0 0
font pango:monospace 8
CFG
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman \
  sway --unsupported-gpu -c "$SWAYCFG" >/tmp/sway.log 2>&1 &
SWAY_PID=$!
sleep 3
export WAYLAND_DISPLAY=wayland-1

# ---------------- title screen -------------------------------------------
timeout 90 "$GODOT" --path "$PROJECT" --display-driver wayland --rendering-driver opengl3 \
  --resolution 1280x720 >/tmp/title.log 2>&1 &
GPID=$!
sleep 8
grim "$SHOTS/00_title.png"
kill "$GPID" 2>/dev/null
wait "$GPID" 2>/dev/null
GPID=""
sleep 1

# ---------------- gameplay tour ------------------------------------------
EIGHT_PAGES_SHOTS="$SHOTS" timeout 150 "$GODOT" --path "$PROJECT" --display-driver wayland \
  --rendering-driver opengl3 --resolution 1280x720 res://scenes/World.tscn \
  -- --autotest=shots --quality=1 >/tmp/shots.log 2>&1
sleep 1

# ---------------- pause + death ------------------------------------------
EIGHT_PAGES_SHOTS="$SHOTS" timeout 150 "$GODOT" --path "$PROJECT" --display-driver wayland \
  --rendering-driver opengl3 --resolution 1280x720 res://scenes/World.tscn \
  -- --autotest=endings --quality=1 >/tmp/endings.log 2>&1
sleep 1

# ---------------- win screen ------------------------------------------
EIGHT_PAGES_SHOTS="$SHOTS" timeout 150 "$GODOT" --path "$PROJECT" --display-driver wayland \
  --rendering-driver opengl3 --resolution 1280x720 res://scenes/World.tscn \
  -- --autotest=winscreen --quality=1 >/tmp/winscreen.log 2>&1
sleep 1

# ---------------- phone resolution, touch UI ---------------------------
EIGHT_PAGES_SHOTS="$SHOTS/mobile" timeout 150 "$GODOT" --path "$PROJECT" --display-driver wayland \
  --rendering-driver opengl3 --resolution 960x432 res://scenes/World.tscn \
  -- --autotest=shots --quality=0 --touch >/tmp/mobile.log 2>&1
sleep 1

# ---------------- contact sheet + gif ----------------------------------
if command -v montage >/dev/null 2>&1; then
  # the tour is procedural, so page shot names change with the seed: build the
  # sheet from whatever frames actually exist
  pages=()
  for f in "$SHOTS"/[0-9][0-9]_page_*.png; do [ -f "$f" ] && pages+=("$f"); done
  select=("$SHOTS/00_spawn.png")
  [ -f "$SHOTS/00_title.png" ] && select=("$SHOTS/00_title.png" "${select[@]}")
  for i in 0 2 4 6 8; do
    [ ${#pages[@]} -gt $i ] && select+=("${pages[$i]}")
  done
  [ -f "$SHOTS/09_slender_apparition.png" ] && select+=("$SHOTS/09_slender_apparition.png")
  [ -f "$SHOTS/12_note.png" ] && select+=("$SHOTS/12_note.png")
  [ -f "$SHOTS/02_death_screen.png" ] && select+=("$SHOTS/02_death_screen.png")
  # montage tiles 2x4 -> at most eight inputs, otherwise it writes -0/-1 files
  select=("${select[@]:0:10}")
  montage "${select[@]}" -tile 2x5 -geometry 640x360+6+6 -background '#0a0a0a' \
    "$SHOTS/contact_sheet.jpg"
  # short looping gif for the README
  gif_frames=("$SHOTS/00_spawn.png")
  for i in 0 2 4 6; do
    [ ${#pages[@]} -gt $i ] && gif_frames+=("${pages[$i]}")
  done
  convert "${gif_frames[@]}" -resize 960x540 -delay 140 -loop 0 \
    -layers optimize "$SHOTS/gameplay.gif" 2>/dev/null || true
fi
# PNGs -> JPEG keeps the repo light; docs reference the .jpg files
for f in "$SHOTS"/*.png "$SHOTS"/mobile/*.png; do
  [ -f "$f" ] && convert "$f" -strip -quality 90 "${f%.png}.jpg" && rm -f "$f"
done

echo "captured:"
ls "$SHOTS"
