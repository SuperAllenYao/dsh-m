#!/usr/bin/env python3
"""Generate the DSH-m App Store icon.

Design asset source for `apps/ios/DSHm/Resources/Assets.xcassets/AppIcon.appiconset/`.
The committed `AppIcon-1024.png` is what Xcode builds into `Assets.car`, so every
build (and every install) ships this icon. Re-run this script only when changing
the design, then rebuild.

Style: dark gradient background + cyan→blue neon terminal prompt (`>_`), glassy
specular edge and soft accent bloom. References: Raycast / Warp / Linear /
Termius / Blink Shell (single bold gradient glyph, dark plate, neon accent).

Requirements: Python 3.9+ and Pillow (`python3 -m pip install pillow`).

Usage:
    python3 apps/ios/Design/AppIcon/generate.py            # write the asset PNG
    python3 apps/ios/Design/AppIcon/generate.py --preview  # + size-ladder preview sheet
"""
import argparse
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
DEFAULT_OUT = os.path.join(
    REPO_ROOT, "apps", "ios", "DSHm", "Resources", "Assets.xcassets",
    "AppIcon.appiconset", "AppIcon-1024.png",
)
DEFAULT_PREVIEW = os.path.join(REPO_ROOT, "apps", "ios", "Design", "AppIcon", "preview.png")

S = 4096                 # render size (downscaled to 1024 at the end)
SS = 2                   # supersample factor for the glyph mask
BG_CENTER = (13, 22, 38)
BG_EDGE = (4, 6, 11)
CYAN_TOP = (103, 232, 249)   # #67E8F9
BLUE_DEEP = (37, 99, 235)    # #2563EB
ACCENT = (34, 211, 238)      # #22D3EE


def background():
    """Dark radial plate with a soft accent bloom (no border, no rounded corners:
    iOS applies the icon mask itself)."""
    small = Image.new("RGB", (256, 256), BG_EDGE)
    px = small.load()
    cx, cy, r = 128, 88, 240
    for y in range(256):
        for x in range(256):
            d = math.hypot((x - cx) / r, (y - cy) / r)
            t = min(1.0, max(0.0, (d - 0.12) / 0.95))
            px[x, y] = tuple(int(BG_CENTER[i] * (1 - t) + BG_EDGE[i] * t) for i in range(3))
    img = small.resize((S, S), Image.BICUBIC)
    bloom = Image.new("L", (S, S), 0)
    ImageDraw.Draw(bloom).ellipse([S * 0.10, S * 0.18, S * 0.90, S * 0.86], fill=70)
    bloom = bloom.filter(ImageFilter.GaussianBlur(S // 6))
    img.paste(Image.new("RGB", (S, S), ACCENT), (0, 0), bloom.point(lambda v: int(v * 0.55)))
    return img


def glyph_mask():
    """`>_` with round caps."""
    m = Image.new("L", (S * SS, S * SS), 0)
    d = ImageDraw.Draw(m)
    w = int(S * SS * 0.092)
    r = w // 2
    pts = [
        (int(S * SS * 0.225), int(S * SS * 0.285)),
        (int(S * SS * 0.445), int(S * SS * 0.500)),
        (int(S * SS * 0.225), int(S * SS * 0.715)),
    ]
    for a, b in zip(pts, pts[1:]):
        d.line([a, b], fill=255, width=w, joint="curve")
    for p in pts:
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=255)
    d.rounded_rectangle(
        [int(S * SS * 0.545), int(S * SS * 0.645), int(S * SS * 0.800), int(S * SS * 0.737)],
        radius=r, fill=255,
    )
    return m.resize((S, S), Image.LANCZOS)


def vertical_gradient(mask, top, bottom):
    grad = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3)))
    out = Image.new("RGB", (S, S), (0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def build():
    bg = background()
    mask = glyph_mask()

    # neon outer glow
    glow = mask.filter(ImageFilter.GaussianBlur(S // 42))
    bg.paste(Image.new("RGB", (S, S), ACCENT), (0, 0), glow.point(lambda v: int(v * 0.40)))

    # cyan -> blue gradient glyph
    glyph = vertical_gradient(mask, CYAN_TOP, BLUE_DEEP)

    # specular highlight along the top edge
    top_band = Image.new("L", (S, S), 0)
    ImageDraw.Draw(top_band).rectangle([0, 0, S, int(S * 0.52)], fill=255)
    spec = ImageChops.subtract(ImageChops.multiply(mask, top_band), mask.filter(ImageFilter.MinFilter(9)))
    glyph.paste(Image.new("RGB", (S, S), (238, 254, 255)), (0, 0), spec.point(lambda v: int(v * 0.60)))

    # subtle bottom-edge depth
    bottom_band = Image.new("L", (S, S), 0)
    ImageDraw.Draw(bottom_band).rectangle([0, int(S * 0.55), S, S], fill=255)
    depth = ImageChops.subtract(ImageChops.multiply(mask, bottom_band), mask.filter(ImageFilter.MinFilter(9)))
    glyph.paste(Image.new("RGB", (S, S), (2, 12, 22)), (0, 0), depth.point(lambda v: int(v * 0.30)))

    bg.paste(glyph, (0, 0), mask)
    return bg


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=DEFAULT_OUT, help="output PNG (1024x1024, RGB)")
    ap.add_argument("--preview", action="store_true", help="also write a size-ladder preview sheet")
    ap.add_argument("--preview-out", default=DEFAULT_PREVIEW, help="preview sheet path")
    args = ap.parse_args()

    icon = build().resize((1024, 1024), Image.LANCZOS)
    if icon.mode != "RGB":
        icon = icon.convert("RGB")
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    icon.save(args.out, "PNG")
    print("wrote", args.out, icon.size, icon.mode)

    if args.preview:
        sheet = Image.new("RGB", (1500, 1100), (8, 10, 15))
        sheet.paste(icon, (30, 38))
        for i, size in enumerate([180, 120, 80, 60]):
            sheet.paste(icon.resize((size, size), Image.LANCZOS), (1100, 60 + i * 200))
        os.makedirs(os.path.dirname(os.path.abspath(args.preview_out)), exist_ok=True)
        sheet.save(args.preview_out, "PNG")
        print("wrote", args.preview_out)


if __name__ == "__main__":
    sys.exit(main())
