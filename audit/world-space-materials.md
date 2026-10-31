# Scale-independent world material mapping

Base: pumpkin/concrete environment branch, e0f01c6. No camera, input or creature behavior changes.

## Fix
- `_pbr` now enables Godot world-space triplanar projection, with isotropic XYZ density in repeats per metre. Albedo, normal and roughness share the projection. Covers stone, bark, wood and ground. No mesh UVs or scale compensation heuristics.
- Bark/wood density: 1 / 0.55 repeats/metre. Ground: 26 repeats over 120 metres (preserves the original large-map density). Stone: 1.6 repeats/metre.
- Concrete and corroded metal shaders already evaluate `MODEL_MATRIX * VERTEX` world coordinates; retained and explicitly regression-tested.
- Pumpkin noise, flecks, patches, stem veins and ground dirt now sample world coordinates. Rind/stem vertex labels remain anatomical masks, not texture coordinates.
- PBR world surfaces and metal remain double-sided. Grass/litter alpha-cutout images, paper/text and flat untextured colors deliberately do not receive triplanar projection.

## Validation
Godot 4.5.1 GL Compatibility / Mesa llvmpipe via Xvfb:
- `tools/world_material_test.gd`: **24/24 image equivalence comparisons pass** across 8 materials, using translated/rotated geometry and non-uniform node, parent, and MultiMesh instance scales. Reference is a BoxMesh with dimensions baked into its vertices, compared against a scaled unit BoxMesh with different UVs. Mean absolute RGB error 0 to 0.000004 (threshold 0.003). Both normals and material response participate in the rendered comparison.
- Negative control: after capturing the reference, disable `uv1_world_triplanar`; regression detects stretched mapping for all four textured PBR materials (12 comparisons fail). Thus this is not simply a test of matching silhouettes.
- Existing gameplay suite: **29 passed, 0 failed** on this branch. Current main's additional input checks are not in this branch.
- Same pre-existing shutdown ObjectDB / five resource warnings as upstream.
- OpenCode audit invoked, but no completed final review available at documentation time; not counted as validation.
- Mobile performance and exact Godot 4.7 behavior not measured. Triplanar uses three planar samples per PBR map; budget accordingly on low-end hardware. World-anchored textures deliberately slide relative to a moving prop; these environmental props are static.

Reproduce:
```
xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy --script tools/world_material_test.gd
godot --headless --path . res://scenes/World.tscn -- --autotest=selftest
```

Generated test renders are under `screenshots/world_materials/`; selected stone and concrete reference/scaled renders are committed. Remaining images regenerate with the test.
