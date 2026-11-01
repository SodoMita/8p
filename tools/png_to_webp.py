#!/usr/bin/env python3
"""Convert generated texture intermediates to lossless WebP, preserving alpha."""
from pathlib import Path
from PIL import Image

for path in Path('assets/textures').glob('*.png'):
    with Image.open(path) as image:
        image.save(path.with_suffix('.webp'), 'WEBP', lossless=True, exact=True, method=6)
    path.unlink()
