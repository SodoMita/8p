> Historical pass. Geometry/counts/screenshots below precede continuous Anny anatomy.
> Current source, licensing and validation: [slender-anny.md](slender-anny.md).

# Slender animation pass

Follow-up to `7da1abf`, on `improve/slender-model`. User chose a blend of unnatural stillness under observation and articulated chase motion.

## What moves

- Idle: restrained ribcage breathing, small skull tilt, relaxed arm drift/finger curl, independent curved tendril motion.
- Watched apparition: exponentially blends almost to stillness (clock at 4.5% speed and motion amplitude heavily reduced).
- Chase: smooth blend into opposing hip/shoulder swing, knee/elbow bends, returning foot lift, slight forward lean, finger curl and stronger tendril movement. Deliberately gliding/inhuman rather than a naturalistic sprint. Gait tempo increases when enraged.
- Hidden/inactive/dead: animation clocks do not advance. Reset restores the neutral animation state. Pausing the scene also freezes the clock. Jumpscare holds the last pose once dead, matching the existing frozen-creature presentation.

## Implementation

`slender_model.gd` adds an anatomical region ID to vertex color red (ID / 8), including tube/loft end caps. It does not tint the model. `slender_motion.gdshader` deforms the five existing batches on the GPU; rotations also rotate normals. Head/arm/leg/tendril roots are restrained with blend weights to avoid separating parts. Skin/material colors, roughness, emission and double-sided rendering are preserved.

`slender_animation.gd` owns per-instance materials and explicit CPU clock/gait/activity uniforms, with frame-rate-independent exponential transition blending. No global shader TIME, per-frame mesh reconstruction, imported skeleton dependency or new draw-call batches. Expanded culling margins accommodate the animated pose.

The lifecycle/AI still owns root translation, yaw, visibility, detection targets, spawn/chase speeds and catch distance. The old whole-root vertical sine bob is replaced by local visual animation, so it no longer offsets the gameplay root. Head movement is small and `head_position()` is unchanged. Force helpers preserve their existing active/dead semantics rather than waking AI as a side effect.

## Validation

- Godot 4.5.1 compatibility renderer under Sway/pixman with llvmpipe: shader compiled and 144 rendered frames captured (idle → watched → chase), inspected at multiple poses.
- Six-second looping preview: `screenshots/slender_animation.gif`.
- `tools/test_slender_animation.gd`: all eight regions present, every vertex/triangle labeled consistently, five shader materials, culling margins, watched suppression, chase blend, gait phase, mesh reuse, root isolation, separate instance clocks, reset and invalid-delta guard.
- Original model structural test still passes: 5 batches, 5,691 triangles, winding/normals/bounds/determinism/double-sided base materials.
- Gameplay regression: **29 passed / 0 failed headlessly**, and **29 passed / 0 failed in rendered Sway/pixman GL with fixed 60 Hz simulation** (`--fixed-fps 60 --resolution 640x360`).
- OpenCode review subagent completed a static integration audit. Checked its concerns against implementation: per-vertex anatomical labels (not material IDs), rounded decoding, per-batch uniforms, explicit frozen clocks, isolated instances, rotating normals and static gameplay targets. Root continuity and deformation were also inspected in GL renders.
- Existing ObjectDB/resource teardown warnings remain. Exact Godot 4.7, exported mobile/web runtime and physical hardware frame rates have not been tested.

## Reproduce

```sh
GODOT=/path/to/godot
"$GODOT" --headless --path . --audio-driver Dummy --script tools/test_slender_animation.gd
"$GODOT" --headless --path . --audio-driver Dummy --script tools/test_slender_model.gd
"$GODOT" --headless --path . --audio-driver Dummy res://scenes/World.tscn -- --autotest=selftest
# Active Sway/pixman session:
"$GODOT" --path . --display-driver wayland --rendering-method gl_compatibility --audio-driver Dummy --resolution 1280x900 --script tools/preview_slender.gd -- --label=animated --animate
```

Capture produces 144 PNGs under `screenshots/animation_frames/` for preview assembly; they are scratch output, not committed. Five original model batches and the new anatomical labels remain deterministic.

### Software-renderer timing note

An unrestricted full-resolution GL run produced 25 passes / 4 failures in timing-sensitive movement/death-screen assertions while rendering on llvmpipe (the headless suite passes 29/29). This is not used as a performance claim. Re-running the rendered suite with `--fixed-fps 60 --resolution 640x360` keeps simulation time/physics deterministic instead of skipping physics catch-up under software rendering. Shader capture itself completes without shader compile/runtime errors. Wayland's pre-existing `pointed_win` mouse-capture warning also appears in this environment.
