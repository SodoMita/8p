#!/usr/bin/env bash
# Rebuilds EVERY generated asset from source, in the only order that works.
#
#   tools/regen_all.sh            # textures + audio + meshes + imports
#   tools/regen_all.sh --title    # also re-render the menu backdrop (needs sway)
#
# Order matters: gen_assets.py writes the flat placeholder textures and the
# audio/fonts, gen_textures_real.py replaces them with the PBR sets, and
# gen_concrete.py replaces stone_* with the 2048 px concrete. Running them the
# other way round silently throws the good maps away.
set -eu
cd "$(dirname "$0")/.."
GODOT=${GODOT:-/home/user/tools/Godot_v4.7.2-stable_linux.x86_64}
if [ ! -x "$GODOT" ]; then
  echo "== unpacking Godot"
  ( cd /home/user/tools && unzip -o -q godot.zip )
fi

mkdir -p assets/textures assets/models assets/audio assets/fonts

echo "== 1/5 base textures, audio, UI art"
python3 tools/gen_assets.py | tail -3

echo "== 2/5 PBR sets (bark, ground, stone, pumpkin, chainlink, grass, litter)"
python3 tools/gen_textures_real.py | tail -3

echo "== 3/5 high-res concrete"
python3 - >/dev/null <<'EOP' || true
EOP
python3 tools/gen_notes.py   # page notes on top of page_blank.png
python3 tools/gen_concrete.py | tail -2

echo "== 4/5 fonts"
for f in DejaVuSans.ttf DejaVuSerif-Bold.ttf; do
  [ -f "assets/fonts/$f" ] || cp "/usr/share/fonts/truetype/dejavu/$f" assets/fonts/
done

echo "== 5/5 meshes + imports"
"$GODOT" --headless --path . --script tools/gen_trees.gd | grep gen_trees | tail -2
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true

if [ "${1:-}" = "--title" ]; then
  echo "== menu backdrop (sway)"
  export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
  WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman \
    sway --unsupported-gpu -c /home/user/tools/swaycfg/config >/tmp/sway.log 2>&1 &
  SW=$!
  sleep 3
  WAYLAND_DISPLAY=wayland-1 timeout 180 "$GODOT" --path . --display-driver wayland \
    --rendering-driver opengl3 --resolution 1280x720 --script tools/gen_title_bg.gd 2>&1 |
    grep -E "title_bg" || true
  kill $SW 2>/dev/null || true
  "$GODOT" --headless --path . --import >/dev/null 2>&1 || true
fi

echo "assets: $(ls assets/textures/*.png | wc -l) textures, $(ls assets/audio/*.wav | wc -l) sounds, $(ls assets/models/*.res | wc -l) meshes"
