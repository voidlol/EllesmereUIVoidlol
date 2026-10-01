"""Builds the horizontal logo (icon + wordmark) from icon.svg.

Usage: python3 build_logo.py <icon448.png rendered from icon.svg> <out.png>
Fonts are the addon's own bundled Fira Sans (Media/Fonts).
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, "..", "..", "Fonts")

W, H = 2048, 512
WHITE = (246, 240, 255, 255)
MUTED = (170, 160, 195, 255)
TEAL = (12, 210, 159, 255)  # EllesmereUI accent, matches the TOC title

icon_path, out_path = sys.argv[1], sys.argv[2]
img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
icon = Image.open(icon_path).convert("RGBA")
img.alpha_composite(icon, (32, (H - icon.height) // 2))

d = ImageDraw.Draw(img)
title = ImageFont.truetype(os.path.join(FONTS, "FiraSans-Heavy.ttf"), 230)
sub = ImageFont.truetype(os.path.join(FONTS, "FiraSansCondensed-Medium.ttf"), 78)

x = 32 + icon.width + 56
d.text((x, 248), "Voidlol", font=title, fill=WHITE, anchor="ls")

prefix = "PLUGIN FOR "
y = 372
d.text((x + 6, y), prefix, font=sub, fill=MUTED, anchor="ls")
px = x + 6 + d.textlength(prefix, font=sub)
d.text((px, y), "ELLESMEREUI", font=sub, fill=TEAL, anchor="ls")

img.save(out_path)
