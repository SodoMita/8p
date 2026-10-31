#!/usr/bin/env bash
# Launch EIGHT PAGES with the local Godot binary (or your own `godot`).
set -eu
cd "$(dirname "$0")"
GODOT=${GODOT:-/home/user/tools/Godot_v4.7.2-stable_linux.x86_64}
[ -x "$GODOT" ] || GODOT=godot
exec "$GODOT" --path . "$@"
