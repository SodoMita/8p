> Historical pass. Geometry/counts/screenshots below precede continuous Anny anatomy.
> Current source, licensing and validation: [slender-anny.md](slender-anny.md).

# Slender: procedural locomotion and secondary physics

Replaces the rejected fixed alternating sine walk from `caeb02d`.

## Locomotion / body

- Motion is sampled from the actual gameplay-root displacement and yaw after AI movement. A stationary chase does **not** walk or pump its arms.
- Independent foot-contact/swing states, predicted footholds, low-clearance eased recovery, and analytical two-bone leg IK. Contacts transform opposite root translation/yaw while planted. At faster travel the recovery phases may overlap rather than holding the support foot beyond reach while waiting for the other foot.
- IK clamps unreachable targets and has a stable knee bend direction. Shoe counter-rotation keeps soles level. This is a flat-map visual contact solver, not a general terrain raycast/full-body balance controller; very high supernatural chase speeds remain reach-limited. No claim of perfect physical foot locking beyond the model's leg reach.
- Spring-damped pelvis height/weight shift, upper-body acceleration lean and turn roll, quieter counter-stabilized head. Arms trail acceleration/turns with damped spring lag instead of opposing rhythmic swings. Torso lean <= 0.09 radians, lateral roll <= 0.035 radians; body drop <= 0.19 local units. No root hopping.
- The AI root, speed, collision, chase, catch distance, head target and camera/input remain unchanged. Model-space deformation only.

## Necktie

The tie uses **a CPU constrained-particle pendulum**, not Godot RigidBody3D/PinJoint3D nodes. Five nodes and four fixed-length distance constraints provide joint-like physical motion with a fixed knot. This is intentionally safer for a teleporting, non-uniformly scaled procedural creature than attaching a dynamic rigid body to its gameplay root.

- Gravity (7.2 model units/s², ~9.8 world units/s² at the model's Y scale), acceleration/turn inertia, and chest-spring acceleration.
- Exponential damping (3.5/s), 120 Hz-or-smaller substeps, 12 constraint iterations per substep, timestep-scaled Verlet history.
- Analytic chest contact, lateral and upward excursion limits prevent the blade passing through the shirt or whipping into the face.
- Corrected an existing shirt/torso overlap exposed by the close-up, so the shirt no longer shows a dark diamond-shaped intersection behind the tie.
- The blade is subdivided at the five constraint nodes and labeled as region 8. GPU deformation follows these node positions inside the existing satin batch. The knot is not simulated and stays attached to the chest.
- Sudden apparition relocations, teleports, large yaw cuts or stalls clear spring/contact/particle histories. Hidden reset/reappearance also clears histories.
- This is constrained flexible secondary motion, not a full cloth/self-collision simulation.

## Rendering / performance

Still five material batches, now **5,696 triangles** (five extra triangles for the segmented tie). No per-frame mesh rebuild, compute shader, external skeleton asset or additional rigid-body scene. Positions and normals are transformed by the GPU; vertex labels select nine anatomical regions. All materials remain double-sided. Explicit clocks/physics freeze with the game, inactive/hidden/dead states.

## Validation

- `tools/test_slender_model.gd`: passes batch/triangle budget, finite normals, winding, deterministic construction and standing bounds.
- `tools/test_slender_animation.gd`: passes nine regions/triangle labels, five batches, observation suppression, stationary chase, world-contact invariance before liftoff, body and tie settling, nonzero inertial tie response, fixed knot, 5 mm link-length tolerance, chest/side limits, 30/60/144 Hz reversal/high-speed/turn stress, teleport history reset, stable mesh and gameplay-root isolation.
- Godot 4.5.1 GL compatibility / llvmpipe, under actual headless Sway with `WLR_RENDERER=pixman`: side-view motion study and tie close-up rendered (216 frames each, accelerate/travel/turn/brake/settle). Inspected representative poses and a real forest capture with the merged camcorder; shader compiles without errors.
- Existing gameplay selftest passes 29/29 on the original base. Merged current main `79b2fc6` (camcorder/input work) non-destructively into this branch and reran the expanded suite: **32 passed / 0 failed**. Main itself is not modified by this branch merge.
- OpenCode subagent completed an integration-risk review. Its baseline assumptions (no velocity input, unsplit tie, retained sine gait) were addressed by this pass. GPU analytical joint deformation is used instead of adding a Skeleton3D; a separate tie surface is unnecessary because per-vertex region 8 selects the chain.
- Exact Godot 4.7 exports, physical hardware performance and uneven-terrain locomotion are not claimed tested. Existing shutdown resource warnings remain.

## Reproduce

```sh
GODOT=/path/to/godot
"$GODOT" --headless --path . --audio-driver Dummy --script tools/test_slender_animation.gd
"$GODOT" --headless --path . --audio-driver Dummy --script tools/test_slender_model.gd
"$GODOT" --headless --path . --audio-driver Dummy res://scenes/World.tscn -- --autotest=selftest
# In a Sway/pixman Wayland session (capture is a stationary treadmill-style motion study):
"$GODOT" --path . --display-driver wayland --rendering-method gl_compatibility --audio-driver Dummy --resolution 1280x900 --script tools/preview_slender.gd -- --label=procedural --view=side --animate
"$GODOT" --path . --display-driver wayland --rendering-method gl_compatibility --audio-driver Dummy --resolution 1280x900 --script tools/preview_slender.gd -- --label=procedural --view=tie --animate
```
