# Restore approved pumpkin material on current main

Base main: 4957548 (1.5.4). User explicitly asked main to use the earlier pumpkin material.

Restored the double-sided procedural rind/woody-stem shader from the approved model pass, including world-coordinate detail from the subsequent scale fix. Restored its three e0f01c6 companion meshes (vertex alpha distinguishes stem/rind), and only `_pumpkin` / `_pumpkin_point` generator functions. Replaced only the pumpkin material slot; concrete, bark, terrain, fence, pages, input, camera and creature untouched.

Regression protection: selftest now checks the actual pumpkin material shader path and both mesh alpha regions. Counts: **55/55 selftest** (53 prior + 2), **30/30 camtest**, quality1 fixed60 on Godot4.5.1. Real GL/Mesa llvmpipe `tools/pumpkin_material_test.gd` renders the three variants using actual MultiMesh and per-instance color tint; masks/normals/vertices check with zero failures. Screenshot: screenshots/pumpkin_restore/material.png.

The generation source and baked mesh labels must remain paired with the shader. No audio/font/texture regeneration. Same existing exit resource warnings. OpenCode read-only audit was attempted but stopped after no final report; no audit sign-off claimed. No Web/Android build requested or performed.
