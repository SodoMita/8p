# Continuous Anny anatomy and fitted suit

## Scope

Replaces the segmented primitive body with genuine free Anny 0.6.2 / MakeHuman
anatomy, retargeted to the extreme Slender proportions. Retains the faceless
skull profile, tendrils, gameplay root and restrained contact/secondary-motion
solver. No changes to AI, catch rules, camera, controls, environment or materials
outside the creature. Source/license notice: assets/models/SLENDER_ANATOMY_NOTICE.md.

## Geometry

- Skin, fingers, shoulders, arms, legs, neck and connected faceless skull form
  **one watertight component**, Euler characteristic 2; 10,419 vertices and
  20,834 indexed faces. Internal mouth remnants were removed before joining.
- Real Anny topology is retargeted from its 104-bone source. Continuous per-vertex
  joint influence replaces the former hard region transitions. Skin and clothes
  share joint labels and weights, including at material splits.
- Offset fitted jacket/sleeves, trousers and actual anatomical undershirt;
  exact edge-cached polygon clipping makes the V opening and tapered neckline,
  rather than dropping whole triangles. Rounded dress shoes deform with legs.
- Physical tie blade retained; a **closed 48-segment solid annular band** wraps
  around the neck under the collar and feeds into a solid beveled knot through
  two modeled straps. Band topology has no boundary edges and Euler 0 (torus),
  independently checked from actual runtime vertices, not metadata alone.
- Cervical skin and skull bridge are welded, with arc-length ordering to avoid
  folded transition triangles. Collar/band are centered on the real neck axis.
- Baked body/garments: 31,065 triangles. Whole runtime creature: 35,337 triangles,
  five material batches. All creature materials remain double-sided. No runtime
  Python/Anny/PyTorch, no per-frame mesh regeneration, no extra rigid-body nodes.
- All export presets explicitly include the baked non-resource JSON asset.

## Reproduce

Generation dependencies: anny==0.6.2, torch, numpy, scipy, trimesh.
`python tools/gen_slender_anny.py --regenerate-source` regenerates and retargets.
The original phenotype basis and two CPU threads avoid the optional large SVD.
A cached source can instead be passed via `--source /path/to/anny_neutral.npz`.

Validation commands:

```
python tools/test_slender_anatomy.py
GODOT --headless --path . --audio-driver Dummy --script tools/test_slender_model.gd
GODOT --headless --path . --audio-driver Dummy --script tools/test_slender_attachment.gd
GODOT --headless --path . --audio-driver Dummy --script tools/test_slender_animation.gd
```

Godot 4.5.1 GL compatibility, actual Sway pixman / Wayland / llvmpipe. Studio
front/back/side and tie views rendered and visually inspected; screenshots are
`screenshots/slender_anny_*.png`. OpenCode integration review completed. Model,
anatomy topology, actual closed tie band, 30/60/144 Hz contact/secondary-motion,
pinned knot, chest limits, teleport reset and gameplay-root isolation pass.

Limitations: no physical mobile GPU or Godot 4.7 export validation. Contact IK
remains a flat-ground visual solver, not arbitrary-terrain balance. The tie is a
constrained-particle solver, not full cloth/self-collision. Godot standalone
model scripts report pre-existing shutdown ObjectDB/resource warnings.

Latest-base gameplay/camera/packaging results are appended after integration.

## Latest-base integration results

Changes were replayed onto **main e71822d** as a new branch
`improve/slender-anny`; no merge of an old environment/material tree and no
changes to main. Latest audio calls and input/camera changes are preserved.

- Gameplay selftest: **43 passed, 0 failed** (latest controls add two checks to
  the previously announced 41). Separate headless Godot run, fixed 60 Hz,
  `--quality=0 --autotest=selftest`.
- Camera test: **30 passed, 0 failed**, separate headless fixed-60-Hz run with
  `--quality=1 --autotest=camtest`. Quality 1 is required by this suite's physics
  assertions: quality 0 deliberately disables the physical camera and yielded
  26/30, not a Slender regression. No camera code was changed.
- All anatomy/model/attachment/animation tests rerun on this base: PASS.
- **Export-pack check PASS**: Web PCK exports successfully, contains actual
  JSON anatomy data, and packaged `slender_model.gd` builds five material
  batches when loaded from the PCK. This is not a browser/WebAssembly or mobile
  device test, nor a full executable/template export.
- Actual GL rendering under Sway/pixman: front/back/side/tie, 216-frame
  accelerate/travel/turn/brake/settle study and actual latest forest/camcorder
  scene. Representative moving poses and forest capture visually inspected.
  `screenshots/slender_anny_motion.gif`, `slender_anny_game.png`.
- High-concurrency rendering/export/review exceeded this small sandbox's memory;
  final functional and packaging tests were therefore run separately. Initial
  GL functional attempts were stopped, not counted as passing.
- Native Wayland forest capture reports `pointed_win is null` on mouse capture
  in this virtual compositor, plus existing shutdown resource warnings; actual
  forest and model images render correctly. No new shader/mesh errors observed.

Push of the new branch currently requires GitHub authentication (HTTPS remote
reports no username/credential). The local branch/commits are complete; this
must not be described as merged or published until an authenticated push.

OpenCode: the original integration-risk review completed and informed the seam,
weight, topology and tie-band checks. A second final read-only review read the
four requested source/config files but did not return a final assessment within
several minutes; it was stopped. No claim of a completed final sign-off.

## Revision: doubled fingers, pointed nails, doubled legs

- All ten digits are extended along their own Anny phalange axes, with the
  knuckles fixed and source-weight blending at their bases. Actual pre/post
  distal extents are recorded and verified **2.00000x** for every digit.
  Palm/wrist dimensions and finger thickness are not globally scaled.
- Ten closed, tapered black nail shells overlap the real fingertips. Their
  attachment points and axes come from the generated anatomical digits; they
  inherit the matching hand region and finger motion. Adds only 60 triangles.
- Runtime geometry doubles hip/knee/ankle heights (2.26 / 1.20 / .14), making
  both .53-unit leg bones **1.06 units**. Above-hip body, head, hands, collar,
  tie and tendrils translate upward by 1.13 without being stretched. Shoe
  vertical geometry follows the same lower-body stretch. Height is now 3.903
  local units (5.308 world units with the pre-existing Y scale).
- Vertex normals receive inverse-transpose Y correction and winding is checked
  after the morph. Shader inverse rest-coordinate thresholds retain canonical
  joint weighting, but actual physical pivots match the taller runtime mesh.
  CPU IK and tie anchors match; the head-position helper follows the taller head.
  AI root speed/catch rules, environment, controls and camera code unchanged.
- **35,397 triangles / five batches**, still one watertight anatomical skin.
- New `tools/test_slender_proportions.gd` verifies every actual runtime skin
  vertex against the source morph, every digit's 2x extent, ten nail anchors,
  doubled CPU leg bones/foot height and translated tie root. PASS. Model,
  anatomy, attachment, 30/60/144-Hz animation tests also PASS.
- Latest functional rerun: selftest **43/43**, camtest quality 1 **30/30**.
- Godot GL compatibility under actual Sway/pixman: full front, detailed hand,
  216-frame side locomotion study rendered; front/hand/moving pose visually
  inspected. `screenshots/slender_claws_front.png`, `_hands.png`, `_motion.gif`.
- OpenCode focused source review read the changed source and checked reference
  heights, but did not return a final assessment after several minutes; stopped.
  No final external sign-off claimed. The visibility-ray policy remains unchanged.
  The earlier Web pack result predates this revision; JSON inclusion path and
  runtime dependency mechanism are unchanged. No new mobile/browser claim.
