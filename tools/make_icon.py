"""Draws the Fellowship minimap icon: a sea-green shield with a gold rim and a gold "F".
Run: python3 tools/make_icon.py  -> Fellowship/Media/icon.tga (64x64, 32-bit) + docs/icon-preview.png
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

S = 512  # draw large, then downsample for smooth edges
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEAL_TOP, TEAL_BOTTOM = (95, 225, 200), (20, 110, 100)
GOLD, GOLD_DARK = (255, 209, 0), (150, 100, 10)


def shield(scale=1.0, cx=S / 2, top=40):
    w, h = 400 * scale, 440 * scale
    x0, x1 = cx - w / 2, cx + w / 2
    y0 = top + (1 - scale) * 220
    pts = [(x0, y0 + 30 * scale), (cx - w * 0.18, y0), (cx, y0 + 18 * scale), (cx + w * 0.18, y0),
           (x1, y0 + 30 * scale)]
    # curved sides down to the point
    steps = 40
    for i in range(1, steps + 1):
        t = i / steps
        x = x1 - (w / 2) * (t ** 1.8)
        y = y0 + 30 * scale + (h - 30 * scale) * t
        pts.append((x, y))
    for i in range(steps - 1, 0, -1):
        t = i / steps
        x = x0 + (w / 2) * (t ** 1.8)
        y = y0 + 30 * scale + (h - 30 * scale) * t
        pts.append((x, y))
    return pts


img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# drop shadow
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).polygon([(x + 8, y + 10) for x, y in shield()], fill=(0, 0, 0, 170))
img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(10)))

d = ImageDraw.Draw(img)
d.polygon(shield(1.0), fill=GOLD_DARK)          # outer dark edge
d.polygon(shield(0.95), fill=GOLD)              # gold rim
# teal gradient body
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = y / S
    c = tuple(int(TEAL_TOP[i] * (1 - t) + TEAL_BOTTOM[i] * t) for i in range(3))
    gd.line([(0, y), (S, y)], fill=c + (255,))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).polygon(shield(0.84), fill=255)
img.paste(grad, (0, 0), mask)

# soft highlight on the upper-left of the shield
hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(hl).ellipse((90, 40, 300, 230), fill=(255, 255, 255, 60))
hl_mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(hl_mask).polygon(shield(0.84), fill=255)
img.paste(hl.filter(ImageFilter.GaussianBlur(30)), (0, 0), Image.composite(hl.split()[3], Image.new("L", (S, S), 0), hl_mask))

# the "F"
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf", 300)
text = "F"
bbox = d.textbbox((0, 0), text, font=font)
tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
tx, ty = S / 2 - tw / 2 - bbox[0], 235 - th / 2 - bbox[1]
d.text((tx, ty), text, font=font, fill=GOLD, stroke_width=16, stroke_fill=(40, 25, 5))
d.text((tx, ty), text, font=font, fill=GOLD)

icon = img.resize((64, 64), Image.LANCZOS)
media = os.path.join(ROOT, "Fellowship", "Media")
os.makedirs(media, exist_ok=True)
icon.save(os.path.join(media, "icon.tga"))  # uncompressed 32-bit TGA, which WoW reads
img.resize((256, 256), Image.LANCZOS).save(os.path.join(ROOT, "docs", "icon-preview.png"))
print("wrote", os.path.join(media, "icon.tga"))
