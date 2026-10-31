#!/usr/bin/env python3
"""Bake the eight page notes into assets/textures/note_N.png.

Run after tools/gen_textures_real.py (it uses page_blank.png as the stock) and
before godot --import. Kept as a tool rather than done at runtime: capturing a
live SubViewport per page proved unreliable in GL Compatibility, and the notes
never change, so there is no reason to pay for it every run.
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFont

NOTES = [
    "1\n\nHELP ME.\n\nI cannot find the way out. The trees keep moving.",
    "2\n\nHe is tall. Taller than the trees.\n\nDo not look at his face.",
    "3\n\nIt only moves when you look away.\n\nKeep your eyes on the path.",
    "4\n\nI counted eight. There were eight.\n\nNow there are seven.",
    "5\n\nDon't run. He hears running.\n\nWalk. Breathe. Count.",
    "6\n\nThe static in your ears is his voice.\n\nWhen it gets loud, close your eyes.",
    "7\n\nIt is always behind you.\n\nAlways.",
    "8\n\nI found them all. Eight pages.\n\nWhy is he still here?",
]
BASE = "assets/textures/page_blank.png"
FONT = "assets/fonts/DejaVuSerif-Bold.ttf"


def wrap(draw, text, font, maxw):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=font) <= maxw:
            cur = t
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def main() -> None:
    base = Image.open(BASE).convert("RGB")
    w, h = base.size
    rng = np.random.default_rng(21)
    for i, note in enumerate(NOTES, start=1):
        img = base.copy()
        d = ImageDraw.Draw(img)
        body = ImageFont.truetype(FONT, 34)
        head = ImageFont.truetype(FONT, 46)
        ink = (29, 24, 19)
        lines = []
        for para in note.split("\n"):
            if para.strip():
                for ln in wrap(d, para, body, w - 120):
                    lines.append(ln)
            else:
                lines.append("")
        if lines and lines[0].isdigit():
            d.text((w // 2, 86), lines[0], font=head, fill=ink, anchor="mm")
            lines = lines[1:]
        y = max(190, (h - 46 * len(lines)) // 2 + 10)
        for text in lines:
            if text:
                d.text((w // 2, y), text, font=body, fill=ink, anchor="ma")
            y += 46
        img = img.rotate(float(rng.uniform(-1.1, 1.1)), resample=Image.BICUBIC,
                         fillcolor=(214, 204, 186))
        a = np.asarray(img, np.float32)
        for _ in range(5):
            y0 = int(rng.integers(120, h - 120))
            a[y0:y0 + 1, :] *= float(rng.uniform(0.97, 1.0))
        Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).save(f"assets/textures/note_{i}.png")
        print("note_%d.png" % i)
    print("done.")


if __name__ == "__main__":
    main()
