# Slender anatomy source and licenses

`slender_anny.json` is generated with **Anny 0.6.2** from its free, MakeHuman-derived
`anny-notongue` topology and `anny` rig. Source: https://github.com/naver/anny .
Anny code is Copyright (c) 2025 NAVER Corp., Apache License 2.0. Its bundled
MakeHuman/MPFB2 anatomical assets are CC0 1.0 Universal. Full notices are in
`licenses/ANNY-APACHE-2.0.txt` and `licenses/MAKEHUMAN-CC0.txt`.

No SMPL, SMPL-X, non-commercial assets, external faces, or human photos are used.
The free generated anatomy is retargeted to the game's proportions, the face is
removed, and the existing faceless skull profile is connected to the real neck.
The fitted suit, collar, necktie, shoes and tendrils are game-specific geometry.

Reproduce: `python tools/gen_slender_anny.py --regenerate-source` (requires the
Anny/PyTorch generation dependencies). The baked JSON is committed; **the game
has no Python, PyTorch, Anny or Blender runtime dependency**. Export presets
explicitly include the JSON so exported games retain the anatomy data.
