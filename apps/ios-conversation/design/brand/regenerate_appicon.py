#!/usr/bin/env python3
"""Regenerate AppIcon.appiconset from docs/refs/brand hero.

- light/dark: soft 3D white cat-head on #FF702A (01-icon-hero-3d.png) @ 1024
- tinted: white BrandMarkOnOrange silhouette on black @ 1024

Does NOT emit jelly / 4-toe paw art.

Usage (from repo root):
  python3 apps/ios-conversation/design/brand/regenerate_appicon.py
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[4]
HERO = ROOT / "docs/refs/brand/01-icon-hero-3d.png"
ICONSET = ROOT / "apps/ios-conversation/Resources/Assets.xcassets/AppIcon.appiconset"
MARK = (
    ROOT
    / "apps/ios-conversation/Resources/Assets.xcassets/CatpawBrand/BrandMarkOnOrange.imageset/BrandMarkOnOrange@3x.png"
)


def sips_resize(src: Path, dst: Path, size: int = 1024) -> None:
    subprocess.check_call(
        ["sips", "-s", "format", "png", "-z", str(size), str(size), str(src), "--out", str(dst)],
        stdout=subprocess.DEVNULL,
    )


def make_tinted(dst: Path, size: int = 1024) -> None:
    mark = Image.open(MARK).convert("RGBA")
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    _, _, _, a = mark.split()
    white = Image.merge(
        "RGBA",
        (
            Image.new("L", mark.size, 255),
            Image.new("L", mark.size, 255),
            Image.new("L", mark.size, 255),
            a,
        ),
    )
    side = int(size * 0.68)
    white = white.resize((side, side), Image.LANCZOS)
    ox = (size - side) // 2
    oy = (size - side) // 2
    canvas.alpha_composite(white, (ox, oy))
    canvas.save(dst, optimize=True)


def main() -> None:
    if not HERO.is_file():
        sys.stderr.write(f"missing hero: {HERO}\n")
        sys.exit(1)
    ICONSET.mkdir(parents=True, exist_ok=True)
    light = ICONSET / "AppIcon-light.png"
    dark = ICONSET / "AppIcon-dark.png"
    tinted = ICONSET / "AppIcon-tinted.png"
    sips_resize(HERO, light)
    dark.write_bytes(light.read_bytes())
    make_tinted(tinted)
    print(f"wrote {light.name}, {dark.name}, {tinted.name} from {HERO.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
