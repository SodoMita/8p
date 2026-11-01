#!/usr/bin/env python3
"""Bake localized, lossless WebP page textures from the translation tables.

Run after page_blank.webp exists and before Godot imports the project.
"""
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

BASE = Path('assets/textures/page_blank.webp')
TEX = Path('assets/textures')


def wrap(draw, text, font, max_width, cjk=False):
    # CJK text has no inter-word spaces; wrap at character boundaries instead.
    units = list(text) if cjk else text.split()
    separator = '' if cjk else ' '
    lines, current = [], ''
    for unit in units:
        candidate = current + (separator if current else '') + unit
        if current and draw.textlength(candidate, font=font) > max_width:
            lines.append(current)
            current = unit
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def main():
    base = Image.open(BASE).convert('RGB')
    w, h = base.size
    for lang in ('en', 'ru', 'zh'):
        table = json.loads(Path(f'translations/{lang}.json').read_text(encoding='utf-8'))
        font_path = 'assets/fonts/NotoSansCJK-subset.otf' if lang == 'zh' else 'assets/fonts/DejaVuSerif-Bold.ttf'
        body, head = ImageFont.truetype(font_path, 34), ImageFont.truetype(font_path, 46)
        rng = np.random.default_rng(21)
        for i in range(1, 9):
            img = base.copy()
            draw = ImageDraw.Draw(img)
            lines = []
            for paragraph in table[f'note_{i}'].split('\n'):
                lines.extend(wrap(draw, paragraph, body, w - 120, lang == 'zh') if paragraph.strip() else [''])
            if lines and lines[0].isdigit():
                draw.text((w // 2, 86), lines.pop(0), font=head, fill=(29, 24, 19), anchor='mm')
            y = max(190, (h - 46 * len(lines)) // 2 + 10)
            if y + 46 * len(lines) > h - 30:
                raise ValueError(f'{lang} note {i} overflows its page')
            for text in lines:
                if text:
                    draw.text((w // 2, y), text, font=body, fill=(29, 24, 19), anchor='ma')
                y += 46
            img = img.rotate(float(rng.uniform(-1.1, 1.1)), resample=Image.Resampling.BICUBIC, fillcolor=(214, 204, 186))
            pixels = np.asarray(img, np.float32).copy()
            for _ in range(5):
                y0 = int(rng.integers(120, h - 120))
                pixels[y0:y0+1, :] *= float(rng.uniform(0.97, 1.0))
            suffix = '' if lang == 'en' else lang + '_'
            path = TEX / f'note_{suffix}{i}.webp'
            Image.fromarray(np.clip(pixels, 0, 255).astype(np.uint8)).save(path, 'WEBP', lossless=True, exact=True, method=6)
            print(path)


if __name__ == '__main__':
    main()
