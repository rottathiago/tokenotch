#!/usr/bin/env python3
"""Check logo transformations and the generated assets against the source."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

spec = importlib.util.spec_from_file_location(
    "brand", Path(__file__).with_name("make-brand-assets.py"))
brand = importlib.util.module_from_spec(spec)
spec.loader.exec_module(brand)
# The generator imports Pillow only when run as a script, so --check works without it.
brand.Image, brand.ImageChops, brand.ImageDraw, brand.ImageFilter = Image, ImageChops, ImageDraw, ImageFilter


class BrandAssetTests(unittest.TestCase):
    def assert_image_equal(self, actual, expected):
        self.assertEqual(actual.size, expected.size)
        self.assertIsNone(ImageChops.difference(actual, expected).getbbox(alpha_only=False))

    def test_generator_digest_is_independent_of_platform_line_endings(self):
        with tempfile.TemporaryDirectory() as temp:
            lf = Path(temp) / "lf.py"
            crlf = Path(temp) / "crlf.py"
            lf.write_bytes(b"first\nsecond\n")
            crlf.write_bytes(b"first\r\nsecond\r\n")
            self.assertEqual(brand.text_digest(lf), brand.text_digest(crlf))

    def test_manifest_paths_use_portable_separators(self):
        generated = brand.manifest()
        self.assertEqual(generated["source"], "docs/design/tokenotch-notch-logo.png")
        self.assertEqual(
            generated["appIconSource"],
            "docs/design/tokenotch-logo-app-icon.png",
        )
        self.assertTrue(all("\\" not in path for path in generated["assets"]))

    def test_content_box_ignores_transparent_noise(self):
        image = Image.new("RGBA", (10, 10))
        image.putpixel((0, 0), (255, 255, 255, 1))
        image.putpixel((3, 4), (30, 40, 50, 255))
        self.assertEqual(brand.content_box(image), (3, 4, 4, 5))

    def test_empty_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "no visible artwork"):
            brand.content_box(Image.new("RGBA", (10, 10)))

    def test_square_preserves_proportions(self):
        mark = Image.new("RGBA", (40, 20), (30, 40, 50, 255))
        result = brand.square(mark, 40)
        self.assertEqual(result.size, (40, 40))
        self.assertEqual(result.getchannel("A").getbbox(), (0, 10, 40, 30))

    def test_ink_keeps_dark_linework_and_drops_white_fill(self):
        mark = Image.new("RGBA", (5, 1))
        colors = [(0, 0, 0, 255), (128, 128, 128, 255), (255, 255, 255, 255),
                  (0, 0, 0, 0), (0, 0, 0, 16)]
        mark.putdata(colors)
        self.assertEqual(list(brand.ink(mark).getdata()), [255, 127, 0, 0, 0])
        self.assertEqual(list(mark.getdata()), colors)

    def test_dark_variant_draws_linework_in_light_ink(self):
        mark = Image.new("RGBA", (3, 1))
        mark.putdata([(0, 0, 0, 255), (255, 255, 255, 255), (0, 0, 0, 0)])
        result = brand.dark_variant(mark)
        self.assertEqual(result.getpixel((0, 0)), brand.DARK_INK + (255,))
        self.assertEqual(result.getpixel((1, 0))[3], 0)
        self.assertEqual(result.getpixel((2, 0))[3], 0)

    def test_template_uses_linework_and_cuts_out_fill(self):
        black = Image.new("RGBA", (36, 36), (0, 0, 0, 253))
        self.assertEqual(brand.menu_bar_template(black).getpixel((18, 18)), (0, 0, 0, 253))
        for empty in [Image.new("RGBA", (36, 36), (255, 255, 255, 255)), Image.new("RGBA", (36, 36))]:
            self.assertIsNone(brand.menu_bar_template(empty).getchannel("A").getbbox())

    def test_icon_tile_removes_only_the_black_backdrop(self):
        artwork = Image.new("RGB", (40, 40))
        ImageDraw.Draw(artwork).rounded_rectangle((5, 5, 34, 34), 8, fill=(3, 3, 3), outline=(200, 200, 200))
        tile = brand.icon_tile(artwork)
        self.assertEqual(tile.size, (30, 30))
        self.assertEqual(tile.getpixel((15, 15))[3], 255)
        self.assertLess(tile.getpixel((0, 0))[3], 64)

    def test_icon_without_backdrop_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "no tile"):
            brand.icon_tile(Image.new("RGB", (10, 10), (255, 255, 255)))

    def test_icon_tile_preserves_white_artwork_and_transparency(self):
        artwork = Image.new("RGBA", (40, 40), (255, 255, 255, 0))
        ImageDraw.Draw(artwork).rounded_rectangle(
            (5, 5, 34, 34), 8, fill=(255, 255, 255, 255))
        artwork.putpixel((5, 13), (255, 255, 255, 128))
        self.assert_image_equal(brand.icon_tile(artwork), artwork.crop((5, 5, 35, 35)))

    def test_icon_tile_rejects_fully_transparent_artwork(self):
        with self.assertRaisesRegex(ValueError, "no visible artwork"):
            brand.icon_tile(Image.new("RGBA", (40, 40), (255, 255, 255, 0)))

    def test_app_icon_preserves_white_tile_and_transparent_margins(self):
        artwork = Image.new("RGBA", (40, 40), (255, 255, 255, 0))
        ImageDraw.Draw(artwork).rounded_rectangle(
            (5, 5, 34, 34), 8, fill=(255, 255, 255, 255))
        icon = brand.app_icon(artwork, 128)
        self.assertEqual(icon.getpixel((64, 64)), (255, 255, 255, 255))
        self.assertEqual(icon.getpixel((0, 0))[3], 0)

    def test_generated_assets_match_source(self):
        with Image.open(brand.SOURCE) as source:
            logo = source.convert("RGBA")
        mark = logo.crop(brand.content_box(logo))
        expected = {
            "TokenotchMark.png": brand.square(mark, 512),
            "TokenotchMarkDark.png": brand.square(brand.dark_variant(mark), 512),
            "TokenotchMenuBar.png": brand.menu_bar_template(mark),
        }
        for name, image in expected.items():
            with self.subTest(asset=name), Image.open(brand.OUT / name) as actual:
                self.assert_image_equal(actual.convert("RGBA"), image)

        with Image.open(brand.APP_ICON_SOURCE) as artwork:
            icon = brand.app_icon(artwork)
        with Image.open(brand.ROOT / "integrations/VSCode/icon.png") as actual:
            self.assert_image_equal(actual.convert("RGBA"),
                                    icon.resize((128, 128), Image.LANCZOS))
        # iconutil also decodes the legacy 16px/32px frames that Pillow omits.
        with tempfile.TemporaryDirectory() as temp:
            iconset = Path(temp) / "Tokenotch.iconset"
            subprocess.run(["iconutil", "-c", "iconset", str(brand.OUT / "Tokenotch.icns"),
                            "-o", str(iconset)], check=True)
            expected_names = set()
            for points in (16, 32, 128, 256, 512):
                for scale in (1, 2):
                    suffix = "@2x" if scale == 2 else ""
                    name = f"icon_{points}x{points}{suffix}.png"
                    expected_names.add(name)
                    with self.subTest(icon_frame=name), Image.open(iconset / name) as actual:
                        size = (points * scale, points * scale)
                        actual = actual.convert("RGBA")
                        expected = icon.resize(size, Image.LANCZOS)
                        if points in (16, 32) and scale == 1:
                            # Legacy ICNS conversion changes translucent RGB, not alpha or opaque ink.
                            self.assert_image_equal(actual.getchannel("A"), expected.getchannel("A"))
                            opaque = expected.getchannel("A").point(lambda a: 255 if a == 255 else 0)
                            self.assertIsNotNone(opaque.getbbox())
                            blank = Image.new("RGBA", size)
                            self.assert_image_equal(Image.composite(actual, blank, opaque),
                                                    Image.composite(expected, blank, opaque))
                        else:
                            self.assert_image_equal(actual, expected)
            self.assertEqual({path.name for path in iconset.iterdir()}, expected_names)


if __name__ == "__main__":
    unittest.main()
