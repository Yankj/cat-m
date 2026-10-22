#!/usr/bin/env python3
"""Brand renderer for launch static frame.

Generates `catBrand/LaunchFirstFrame` = soft orange orb + white cat-head
(from `BrandMarkOnOrange`), matching LaunchMarkView's final keyframe.

Does NOT regenerate AppIcon or BrandMark* — those come from docs/refs/brand
masters (see docs/brand-theme.md). Does NOT emit jelly/4-pad paw assets.

Usage:
  python3 render_brand.py <path-to-Assets.xcassets>
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

PRIMARY = (255, 112, 42, 255)  # #FF702A


def make_orb(px: int, mark: Image.Image) -> Image.Image:
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    layer = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    pad = int(px * 0.04)
    d.ellipse([pad, pad, px - 1 - pad, px - 1 - pad], fill=PRIMARY)
    hi = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    ImageDraw.Draw(hi).ellipse(
        [pad + px * 0.12, pad + px * 0.06, px - pad - px * 0.12, pad + px * 0.55],
        fill=(255, 255, 255, 55),
    )
    layer = Image.alpha_composite(layer, hi.filter(ImageFilter.GaussianBlur(radius=px * 0.04)))
    img = Image.alpha_composite(img, layer)
    msize = int(px * 0.42)
    m = mark.resize((msize, msize), Image.LANCZOS)
    ox = (px - msize) // 2
    oy = (px - msize) // 2
    img.alpha_composite(m, (ox, oy))
    return img


def write_imageset(root: Path, name: str, files: list[tuple[int, Image.Image]]) -> None:
    d = root / f"{name}.imageset"
    d.mkdir(parents=True, exist_ok=True)
    for f in list(d.iterdir()):
        if f.is_file():
            f.unlink()
    imgs: list[dict] = [{"idiom": "universal", "scale": "1x"}]
    for scale, im in files:
        fn = f"{name}@{scale}x.png"
        im.save(d / fn, optimize=True)
        imgs.append({"filename": fn, "idiom": "universal", "scale": f"{scale}x"})
    (d / "Contents.json").write_text(json.dumps({"images": imgs, "info": {"author": "xcode", "version": 1}}, indent=1) + "\n")


def main(assets: Path) -> None:
    brand = assets / "catBrand"
    mark2 = Image.open(brand / "BrandMarkOnOrange.imageset" / "BrandMarkOnOrange@2x.png").convert("RGBA")
    mark3 = Image.open(brand / "BrandMarkOnOrange.imageset" / "BrandMarkOnOrange@3x.png").convert("RGBA")
    write_imageset(brand, "LaunchFirstFrame", [(2, make_orb(210, mark2)), (3, make_orb(315, mark3))])
    # Ensure obsolete jelly-paw splash sets stay gone.
    for obsolete in ("LaunchPaw", "LaunchPawMark", "LaunchGlow"):
        d = brand / f"{obsolete}.imageset"
        if d.exists():
            import shutil
            shutil.rmtree(d)
            print("removed obsolete", d)
    print("wrote LaunchFirstFrame (orange orb + white BrandMarkOnOrange)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    main(Path(sys.argv[1]))
