#!/usr/bin/env python3
"""Derive Tokenotch brand assets from the artwork in docs/design.

From docs/design/tokenotch-notch-logo.png, outputs to sources/Resources/Brand:
  TokenotchMark.png / TokenotchMarkDark.png   the mark / light linework for dark backgrounds
  TokenotchMenuBar.png                    template of the dark linework for the menu bar (@2x)
From docs/design/tokenotch-logo-app-icon.png:
  Tokenotch.icns                          app icon
  integrations/VSCode/icon.png        icon for the local companion
Requires Pillow and macOS iconutil.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs/design/tokenotch-notch-logo.png"
APP_ICON_SOURCE = ROOT / "docs/design/tokenotch-logo-app-icon.png"
OUT = ROOT / "sources/Resources/Brand"
MANIFEST = OUT / "TokenotchBrandManifest.json"
ASSETS = [
    OUT / "TokenotchMark.png", OUT / "TokenotchMarkDark.png", OUT / "TokenotchMenuBar.png",
    OUT / "Tokenotch.icns", ROOT / "integrations/VSCode/icon.png",
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def text_digest(path):
    text = path.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def manifest():
    return {
        "source": str(SOURCE.relative_to(ROOT)),
        "sourceSHA256": digest(SOURCE),
        "appIconSource": str(APP_ICON_SOURCE.relative_to(ROOT)),
        "appIconSourceSHA256": digest(APP_ICON_SOURCE),
        "generatorSHA256": text_digest(Path(__file__)),
        "assets": {str(path.relative_to(ROOT)): digest(path) for path in ASSETS},
    }


def check():
    try:
        recorded = json.loads(MANIFEST.read_text())
        if recorded != manifest():
            raise ValueError("The source artwork or generated assets changed.")
    except (OSError, ValueError) as error:
        raise SystemExit(f"Brand assets are stale: {error} Run python3 scripts/make-brand-assets.py.")
    print(f"All brand assets match {SOURCE.relative_to(ROOT)} and {APP_ICON_SOURCE.relative_to(ROOT)}.")


def content_box(image):
    box = image.getchannel("A").point(lambda a: 255 if a > 16 else 0).getbbox()
    if box is None:
        raise ValueError("The source logo has no visible artwork.")
    return box


def square(image, size, padding=0.0):
    side = max(image.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(image, ((side - image.width) // 2, (side - image.height) // 2))
    inner = round(size * (1 - 2 * padding))
    scaled = canvas.resize((inner, inner), Image.LANCZOS)
    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    result.paste(scaled, ((size - inner) // 2, (size - inner) // 2))
    return result


DARK_INK = (232, 235, 240)


def ink(mark):
    """Coverage of the dark linework: black stays opaque, the white fill drops out."""
    luma = mark.convert("RGB").convert("L")
    shape = ImageChops.multiply(mark.getchannel("A"), ImageChops.invert(luma))
    return shape.point(lambda a: a if a > 16 else 0)


def dark_variant(mark):
    """Redraw the linework in light ink so the white fill doesn't glare on dark backgrounds."""
    result = Image.new("RGBA", mark.size, DARK_INK + (0,))
    result.putalpha(ink(mark))
    return result


def menu_bar_template(mark, size=36):
    """Template silhouette of the linework; the fill and eyes read as cut-outs."""
    silhouette = Image.new("RGBA", mark.size, (0, 0, 0, 0))
    silhouette.putalpha(ink(mark))
    return square(silhouette, size, padding=0.02)


BACKDROP_LUMA = 8


def icon_tile(artwork):
    """Cut the rounded tile out of the opaque black backdrop around it.

    The tile's light rim separates its dark face from the backdrop, so a flood fill
    from the corners removes only the backdrop.
    """
    rgb = artwork.convert("RGB")
    backdrop = rgb.convert("L").point(lambda v: 255 if v <= BACKDROP_LUMA else 0)
    for corner in ((0, 0), (rgb.width - 1, 0), (0, rgb.height - 1), (rgb.width - 1, rgb.height - 1)):
        if backdrop.getpixel(corner) == 255:
            ImageDraw.floodfill(backdrop, corner, 128, thresh=0)
    alpha = backdrop.point(lambda v: 0 if v == 128 else 255)
    box = alpha.getbbox()
    if box is None or box == (0, 0, rgb.width, rgb.height):
        raise ValueError("The app icon source has no tile on a black backdrop.")
    tile = rgb.convert("RGBA")
    tile.putalpha(alpha.filter(ImageFilter.GaussianBlur(0.75)))
    return tile.crop(box)


def app_icon(artwork, size=1024):
    """Place the tile on the macOS icon grid (824pt tile on a 1024pt canvas) with a drop shadow."""
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile = icon_tile(artwork)
    side = round(size * 0.805)
    origin = (size - side) // 2
    tile = tile.resize((side, side), Image.LANCZOS)
    offset = round(size * 0.012)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (origin, origin + offset), tile.getchannel("A"))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(size * 0.012)))
    icon.alpha_composite(tile, (origin, origin))
    return icon


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for stale in ("TokenotchLogo.png", "TokenotchLogoDark.png"):
        (OUT / stale).unlink(missing_ok=True)
    logo = Image.open(SOURCE).convert("RGBA")
    mark = logo.crop(content_box(logo))
    square(mark, 512).save(OUT / "TokenotchMark.png")
    square(dark_variant(mark), 512).save(OUT / "TokenotchMarkDark.png")
    menu_bar_template(mark).save(OUT / "TokenotchMenuBar.png")

    with Image.open(APP_ICON_SOURCE) as artwork:
        icon = app_icon(artwork)
    icon.resize((128, 128), Image.LANCZOS).save(ROOT / "integrations/VSCode/icon.png")
    with tempfile.TemporaryDirectory() as temp:
        iconset = Path(temp) / "Tokenotch.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            icon.resize((points, points), Image.LANCZOS).save(iconset / f"icon_{points}x{points}.png")
            icon.resize((points * 2, points * 2), Image.LANCZOS).save(iconset / f"icon_{points}x{points}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "Tokenotch.icns")], check=True)
    MANIFEST.write_text(json.dumps(manifest(), indent=2) + "\n")
    print(f"Wrote brand assets to {OUT.relative_to(ROOT)} and integrations/VSCode/icon.png")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Verify source and generated asset hashes without Pillow.")
    args = parser.parse_args()
    if args.check:
        check()
    else:
        from PIL import Image, ImageChops, ImageDraw, ImageFilter
        if not shutil.which("iconutil"):
            raise SystemExit("iconutil is required (macOS).")
        main()
