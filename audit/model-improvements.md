# 3D model improvement pass

## Changes
- Truck: hollow cargo bed, cabin glazing/pillars, mirrors, handles, bed ribs, grille, lamps, bumper, hubs, and corrected wheel axes. Simple gameplay collision remains separate from cosmetic geometry.
- Standing stones: deterministic irregular eroded ring meshes with closed top surfaces, generated normals/tangents, and existing PBR stone maps. Existing collision proxies retained.
- Silo: rolled-metal seam rings.
- Metal: world-space paint/corrosion shader with mottled rust, vertical streaks, pits, and material-dependent roughness/metallic response. No external textures/dependencies.
- Trees: 14-sided trunks, smoother axial bends, ground-flared bases and six tapered buttress roots. Six tree and two snag baked meshes regenerated.
- Creature: OpenCode-assisted model-only pass. Narrow tailored jacket, shoulders, lapels/collar/tie, hands/fingers, shoes, higher-resolution blank head, segmented bending tendrils. Arm height corrected during review. AI and head-position API unchanged.
- Added cosmetic truck pieces and creature details batched by material to avoid one draw call per detail/segment.

## Validation
- Godot 4.5.1 stable, GL Compatibility (project declares 4.7; exact target version unavailable here).
- Gameplay selftest: **29 passed, 0 failed** after geometry/shader/batching changes.
- Actual OpenGL renders on Mesa llvmpipe via Xvfb: truck, stones, silo, creature, tree. See `screenshots/models/`.
- `git diff --check` clean.
- Unchanged upstream also passes 29/29 and produces the same ObjectDB / five resources-in-use shutdown warning. This warning predates this model pass.
- Not validated: Android/Web exports, hardware-device frame rates, exact Godot 4.7 behavior.

## Reproduce
```sh
godot --headless --path . --script tools/gen_trees.gd
godot --headless --path . res://scenes/World.tscn -- --autotest=selftest
xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy --script tools/model_preview.gd
```

OpenCode: `opencode/glm-5.3-flash-free` stalled after reading; retried successfully with `opencode/big-pickle`, restricted to model helpers in `scripts/slender.gd`. Reviewed and refined the generated code locally. Camera, HUD, player controller and game rules untouched.

## Pumpkin / concrete follow-up
- Three pumpkin variants rebuilt at 24 axial rings / 72 radial segments. Smooth analytical profile with numerical-derivative normals, deeper narrow ribs, closed flat base, sunken stem socket and tapered curved stem.
- Vertex alpha selects rind vs woody stem inside one opaque shader/material. Mottling, rib shading, soil at the base and variable roughness; explicit outward shader normals preserve lighting with double-sided rendering and existing baked-mesh winding convention.
- Concrete no longer reuses the natural stone material: world-space aggregate, pores, narrow cracks, formwork joints, rain streaks, ground damp and moss. Shader authored by OpenCode big-pickle, reviewed and GL-compiled locally; made double-sided.
- Concrete boxes have actual 44-triangle chamfered silhouettes (faces/edge strips/corner facets), original simple box collision retained. No random-number consumption or layout changes.
- Both new shaders are double-sided. This follow-up does not attempt the channel's broader all-materials/input requests, which belong to other agents.
- Validation: structural mesh checks zero failures, gameplay suite 29/29, actual GL close-ups in screenshots/models/pumpkins.png and concrete.png. Godot 4.5.1 / llvmpipe. Same pre-existing exit resource warning. Mobile performance and exports not measured.
