> Historical pass. Geometry/counts/screenshots below precede continuous Anny anatomy.
> Current source, licensing and validation: [slender-anny.md](slender-anny.md).

# Slender model pass

## Changes

- Replaces the original capsule torso / open-looking cylinder arms / straight tendril sticks with a deterministic procedural mesh builder in `scripts/slender_model.gd`.
- Structured shoulder-to-waist jacket silhouette, flattened chest, notch lapels, white shirt inset and collar, pointed tie, small welt pockets.
- Smooth tapered sleeves and trousers with subtle elbow/knee shapes; white cuffs; flattened palms with four individually tapered fingers and a hooked thumb on each hand.
- Smooth egg-shaped faceless head with a narrower chin, preserving the original head center and overall height. Rounded dress shoes sit on the ground.
- Six smooth cubic back tendrils with pointed ends. No random per-frame geometry or external texture dependencies.
- Five opaque double-sided material batches; **5,691 triangles total**. Rough wool, satin lapels, shirt, pale skin and darker leather/tendrils. Small emission keeps the figure legible without making the face a lamp.
- Only `_build_model()` and obsolete mesh-building helpers change in `slender.gd`. Spawning, visibility, head targeting, scale, movement, chase, signals and idle sway are unchanged.

## Validation

Tested with Godot **4.5.1** (the available stable binary), OpenGL compatibility renderer / llvmpipe, under an actual headless Sway compositor using `WLR_RENDERER=pixman`.

- Existing gameplay selftest: **29 passed / 0 failed**, including Slender visibility, catching the player and death screen.
- `tools/test_slender_model.gd`: passes geometry batch count, triangle budget, finite/unit normals, clockwise winding, double-sided materials, standing bounds/head height and deterministic construction checks.
- Front/rear studio renders and a real `World.tscn` forest render inspected visually. An initial winding issue was found and corrected before final captures.
- OpenCode subagents invoked for baseline and final static audit. Their review is supplementary; automated Godot checks and direct render inspection are the validation basis.

Existing project teardown emits ObjectDB / 5-resources-in-use warnings. Headless Wayland may also report missing FIFO protocol and a null pointed window while the game captures the mouse. These did not prevent screenshots or passing tests. Exact Godot 4.7, Android/Web exports and hardware performance are not claimed tested.

## Reproduce

```sh
GODOT=/path/to/godot
"$GODOT" --headless --path . --audio-driver Dummy --script tools/test_slender_model.gd
"$GODOT" --headless --path . --audio-driver Dummy res://scenes/World.tscn -- --autotest=selftest
# In an active Sway/pixman Wayland session:
"$GODOT" --path . --display-driver wayland --rendering-method gl_compatibility --audio-driver Dummy --resolution 1280x900 --script tools/preview_slender.gd -- --label=after --view=front
"$GODOT" --path . --display-driver wayland --rendering-method gl_compatibility --audio-driver Dummy --resolution 1280x900 --script tools/preview_slender.gd -- --label=after --view=back
"$GODOT" --path . --display-driver wayland --rendering-method gl_compatibility --audio-driver Dummy --resolution 1280x900 --script tools/preview_slender_game.gd
```

## Parallel branch integration

This pass is based on main `0dcaa12`. It intentionally does not take or overwrite ModelPass's environment/pumpkin/concrete changes or Delta07's camera/HUD/input work. If `improve/3d-models` lands first, resolve `slender.gd`'s model-section conflict by keeping the single delegation to `slender_model.gd` from this branch and removing the old model helpers. Keep all behavior sections from the target branch.
