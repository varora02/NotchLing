#!/usr/bin/env python3
"""Draws the DMG window background (660x420 pt, written at 2x with 144 dpi).

Developer tool, not part of the build: run it only when the artwork changes, then
regenerate the layout with settings.py. Needs Pillow:
  python3 -m venv /tmp/dmgenv && /tmp/dmgenv/bin/pip install pillow
  /tmp/dmgenv/bin/python Distribution/dmg/make-background.py
"""
import pathlib

from PIL import Image, ImageDraw, ImageFont

POINTS_W, POINTS_H, SCALE = 660, 420, 2
APP_CENTER, APPLICATIONS_CENTER = (170, 205), (490, 205)  # keep in sync with settings.py
OUT = pathlib.Path(__file__).resolve().parent / "background.png"


def font(size, bold=False):
    return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size * SCALE, index=1 if bold else 0)


def centered(draw, text, y, face, fill):
    width = draw.textlength(text, font=face)
    draw.text(((POINTS_W * SCALE - width) / 2, y * SCALE), text, font=face, fill=fill)


image = Image.new("RGB", (POINTS_W * SCALE, POINTS_H * SCALE))
draw = ImageDraw.Draw(image)
for y in range(POINTS_H * SCALE):  # soft vertical gradient
    t = y / (POINTS_H * SCALE)
    draw.line([(0, y), (POINTS_W * SCALE, y)], fill=(int(247 - 12 * t), int(247 - 12 * t), int(250 - 10 * t)))

ink, muted, accent = (34, 34, 40), (110, 110, 122), (96, 82, 214)
centered(draw, "Drag NotchLing to Applications", 38, font(24, bold=True), ink)
centered(draw, "Then open it from your Applications folder to connect your coding agents.", 76, font(13), muted)

# Arrow between the two icons.
y = APP_CENTER[1] * SCALE
x0, x1 = (APP_CENTER[0] + 78) * SCALE, (APPLICATIONS_CENTER[0] - 78) * SCALE
draw.line([(x0, y), (x1 - 10 * SCALE, y)], fill=accent, width=5 * SCALE)
draw.polygon([(x1, y), (x1 - 22 * SCALE, y - 15 * SCALE), (x1 - 22 * SCALE, y + 15 * SCALE)], fill=accent)

centered(draw, "NotchLing sits at the notch at the top of your screen.", 372, font(12), muted)
image.save(OUT, dpi=(144, 144))
print(f"wrote {OUT} {image.size}")
