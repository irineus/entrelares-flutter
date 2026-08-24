#!/usr/bin/env python3
"""F-54 — derive the app icons and the Play store icon from the official
Entrelares brand artwork.

Two masters, both AI-generated and approved by the owner (no vector source — ask
for a new generation to change the art, then re-run this script; the landing repo
carries its own copy of both plus its own script in assets-src/):

- store/brand-emblema.png (1024x1024, TEXT-FREE): the 3D emblem — two interlocked
  house-rings (sage fabric + terracotta wood) bleeding over a white squircle
  plaque, children lighting a flame at the junction, embossed houses. Used for
  Icon-192/Icon-512 (full frame) and, re-composed, for the maskable icons.
- store/brand-emblema-flat.png (1380x752): the flat/"vector-style" rendition of
  the same emblem. Used ONLY for favicon.png (96): at small sizes the flat
  linework stays crisp where the 3D render turns to mush. The plaque sits at
  (388,38)-(1005,658); the favicon is the 640x640 crop (376,28)-(1016,668).

Maskable icons re-compose the emblem at 78% over the artwork's background tone
(with a feathered paste so no seam shows) so the plaque corners survive the
Android 80%-safe-zone circle without being clipped. The SAME two renditions feed
the Android launcher icon: `assets/brand/emblema{,-maskable}.png` are what
`flutter_launcher_icons` reads (see the pubspec block), which is why they are
written here rather than copied by hand.

Usage (needs Pillow):  python3 store/brand-icons.py

Outputs:  apps/entrelares_app/web/favicon.png
          apps/entrelares_app/web/icons/Icon-{192,512}.png
          apps/entrelares_app/web/icons/Icon-maskable-{192,512}.png
          apps/entrelares_app/assets/brand/emblema.png          (= Icon-512)
          apps/entrelares_app/assets/brand/emblema-maskable.png (= maskable 512)

NOT an output, on purpose: store/store_icon.png. Until 13/08/2026 this script
wrote it too (it was maskable(512) byte for byte), but the file in the repo is
now a DIFFERENT generation of the same emblem — a fuller framing, better for
Play's own crop — supplied by hand and versioned as it is (see store/README.md
§2). Re-adding the write would silently regress the store icon to the worse
framing.
"""
from PIL import Image, ImageDraw
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "apps" / "entrelares_app"
WEB = APP / "web"
BRAND = APP / "assets" / "brand"
FLAT_CROP = (376, 28, 1016, 668)  # 640x640 square centred on the flat plaque
MASKABLE_SCALE = 0.78             # plaque corners inside the 80% safe-zone circle
FEATHER = 18                      # px of alpha ramp on the pasted square's edges

emblem = Image.open(ROOT / "store" / "brand-emblema.png").convert("RGB")
flat = Image.open(ROOT / "store" / "brand-emblema-flat.png").convert("RGB")

corners = [emblem.getpixel(p) for p in
           ((6, 6), (emblem.width - 7, 6), (6, emblem.height - 7),
            (emblem.width - 7, emblem.height - 7))]
bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))

for size, name in ((192, "Icon-192.png"), (512, "Icon-512.png")):
    emblem.resize((size, size), Image.LANCZOS).save(WEB / "icons" / name, optimize=True)
    print("ok", name)

flat.crop(FLAT_CROP).resize((96, 96), Image.LANCZOS).save(
    WEB / "favicon.png", optimize=True)
print("ok favicon.png")

def maskable(size: int) -> Image.Image:
    canvas = Image.new("RGB", (size, size), bg)
    inner = int(size * MASKABLE_SCALE)
    small = emblem.resize((inner, inner), Image.LANCZOS)
    m = Image.new("L", (inner, inner), 0)
    d = ImageDraw.Draw(m)
    for i in range(FEATHER):
        d.rectangle([i, i, inner - 1 - i, inner - 1 - i],
                    outline=int(255 * (i + 1) / FEATHER))
    d.rectangle([FEATHER, FEATHER, inner - 1 - FEATHER, inner - 1 - FEATHER], fill=255)
    canvas.paste(small, ((size - inner) // 2, (size - inner) // 2), m)
    return canvas

for size in (192, 512):
    maskable(size).save(WEB / "icons" / f"Icon-maskable-{size}.png", optimize=True)
    print("ok", f"Icon-maskable-{size}.png")

# The launcher icon's two sources (flutter_launcher_icons reads these).
emblem.resize((512, 512), Image.LANCZOS).save(BRAND / "emblema.png", optimize=True)
print("ok", "emblema.png")
maskable(512).save(BRAND / "emblema-maskable.png", optimize=True)
print("ok", "emblema-maskable.png")
