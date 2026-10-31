# Main-based concrete revision

Base: latest origin/main fetched for this pass, **e71822d**. New focused branch, no old branch merge. Preserves current fence, streamed terrain, cloth, input and camera. No creature changes.

## Requested appearance
- Keeps main's **unchanged 2048px stone albedo, normal and roughness maps** as the concrete/stone base. No texture regeneration or replacement.
- Continuous blend of offset/rotated, incommensurately scaled texture samples reduces recognizable repetition. Both layers always contribute. This reduces repetition; it is not a mathematical guarantee of no recognizable texture features.
- Restores the prior sparse procedural crack/halo field with screen-derivative antialiasing.
- No formwork seam grid, tile borders, grout or board-band shading.
- Base density is still **1.2 metres per repeat** through the existing `_triplanar()` factory. `_pbr()` signature unchanged. Ground's existing world material unchanged.

## Coordinates
Concrete/stone now use an orthonormal material frame extracted from MODEL_MATRIX. Removing rotation from the transformed position (but retaining world-metre scale and shear) gives metric coordinates that **rotate/move with the object without texture stretching under scale**. Normals are transformed through material, world and view frames. Negative transforms keep the residual reflection in the metric coordinates; collapsed zero-scale geometry is not supported.

This intentionally replaces strictly world-anchored concrete/stone projection; moving an object no longer makes its surface slide through a stationary world texture. Ground stays world anchored. Other materials untouched.

## Validation
Godot 4.5.1 GL Compatibility / Mesa llvmpipe, Xvfb:
- Latest-base **selftest: 43 passed, 0 failed**, q1 fixed60.
- Latest-base **camtest: 30 passed, 0 failed**, q1 fixed60.
- Real GL `tools/concrete_mapping_test.gd`: **9 scale comparisons + 2 rotation-follow comparisons pass**, mean absolute RGB error zero in this run. Node scale, parent scale and MultiMesh instance scale match equivalent baked dimensions. Rotating the object/camera/light together preserves texture appearance. Includes rotated/translated non-uniform test geometry; not a comprehensive arbitrary-shear test.
- Close (3 m) and 20 m main/revised renders saved under screenshots/concrete_revision and visually inspected.
- Controlled material-only benchmark: 1280x720 near-fullscreen wall, same light/camera/maps, 10 warmup + 40 measured frames, q1/llvmpipe. **Main 78.01 ms/frame (12.82 FPS); revision 59.05 ms/frame (16.94 FPS)**. This is not full-game FPS. Initial implementation sampled all three projections and was slower (131.57 ms); final shader skips invisible planes (6 fetches on a flat axis-aligned face). Angled/rounded surfaces can sample more planes. No mobile hardware benchmark.
- Shutdown ObjectDB/five-resource warnings remain, same as baseline.
- OpenCode read-only review invoked and inspected sources, but returned no final assessment. Not counted as signoff.

Reproduce:
```
godot --headless --path . --import
godot --headless --path . --fixed-fps 60 res://scenes/World.tscn -- --autotest=selftest --quality=1
godot --headless --path . --fixed-fps 60 res://scenes/World.tscn -- --autotest=camtest --quality=1
xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy --script tools/concrete_mapping_test.gd
xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy --script tools/concrete_preview.gd
```
