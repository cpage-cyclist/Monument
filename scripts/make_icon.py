"""Draws the Run Guide app icon (1024×1024 PNG).

The mark is a session profile, the way a structured run looks on a chart:
an easy warm-up block, three tall rep bars with low floats between, and an
easy cool-down, with voice-cue arcs above the last rep.

Usage: python3 scripts/make_icon.py OUTPUT.png
"""
import sys

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4                      # draw large, then downsample for smooth edges
S = SIZE * SCALE

TOP = (16, 33, 46)             # deep blue-slate
BOTTOM = (6, 14, 22)
EASY = (64, 120, 150)          # muted blue for warm-up/floats/cool-down
REP = (200, 248, 74)           # bright lime for the reps
CUE = (236, 244, 248)          # near-white voice arcs


def px(v):
    return int(v * SCALE)


def main(out):
    img = Image.new("RGB", (S, S))
    draw = ImageDraw.Draw(img)

    # Vertical gradient background (full bleed; iOS applies the rounded mask).
    for y in range(S):
        t = y / (S - 1)
        colour = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        draw.line([(0, y), (S, y)], fill=colour)

    baseline = 760
    radius = 22
    # (x_start, width, height, colour)
    blocks = [
        (168, 132, 150, EASY),   # warm-up
        (324, 84, 430, REP),     # rep 1
        (432, 48, 110, EASY),    # float
        (504, 84, 430, REP),     # rep 2
        (612, 48, 110, EASY),    # float
        (684, 84, 430, REP),     # rep 3
        (792, 64, 150, EASY),    # cool-down
    ]
    for x, w, h, colour in blocks:
        draw.rounded_rectangle(
            [px(x), px(baseline - h), px(x + w), px(baseline)],
            radius=px(radius),
            fill=colour,
        )

    # Ground line.
    draw.rounded_rectangle(
        [px(168), px(baseline + 34), px(856), px(baseline + 52)],
        radius=px(9),
        fill=EASY,
    )

    # Voice-cue arcs radiating from above the last rep.
    cx, cy = 726, 250
    for i, r in enumerate((62, 112, 162)):
        width = 22
        draw.arc(
            [px(cx - r), px(cy - r), px(cx + r), px(cy + r)],
            start=-62, end=-8,
            fill=CUE if i < 2 else (150, 175, 190),
            width=px(width),
        )

    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(out, "PNG")
    print(f"wrote {out}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "icon.png")
