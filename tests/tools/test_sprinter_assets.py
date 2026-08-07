import tempfile
import unittest
from pathlib import Path

from tools import build_sprinter_assets as assets


ROOT = Path(__file__).resolve().parents[2]


class SprinterAssetTests(unittest.TestCase):
    def build(self):
        return assets.build(
            ROOT / "assets/sprinter/raster_manifest.json",
            ROOT / "assets/sprinter/about-384x192.rgb",
            ROOT / "extern/sprinter-libs/afnt640/font.bin",
        )

    def test_pipeline_is_deterministic_and_pages_are_exact(self):
        pages1, manifest1, widths1 = self.build()
        pages2, manifest2, widths2 = self.build()
        self.assertEqual((pages1, manifest1, widths1), (pages2, manifest2, widths2))
        self.assertEqual(len(pages1), 5)
        self.assertTrue(all(len(page) == assets.PAGE_SIZE for page in pages1))
        self.assertEqual(manifest1["gfx_page_count"], 4)

    def test_piece_geometry_storage_and_refs(self):
        pages, manifest, _widths = self.build()
        pieces = manifest["pieces"]
        self.assertEqual((pieces["visible_width"], pieces["visible_height"]), (32, 16))
        self.assertEqual((pieces["storage_tile_width"], pieces["storage_tile_height"]),
                         (16, 32))
        self.assertEqual(pieces["storage_visible_rows"], [4, 19])
        refs = pieces["tile_refs"]
        sets = pieces["sets"]
        self.assertEqual(refs[sets[0]]["wK"], [0x0000, 0x0001])
        self.assertEqual(refs[sets[2]]["bP"], [0x0106, 0x0107])
        first = pages[0][:assets.TILE_BYTES]
        self.assertEqual(first[:4 * 8], bytes((0xFF,)) * 32)
        self.assertEqual(first[20 * 8:], bytes((0xFF,)) * (12 * 8))
        for index in range(assets.PIECE_COUNT):
            # The packed form is what GFX640 draws.  It must retain the
            # tight 32x16 raster's antialiased outer contour instead of
            # accidentally turning it into an inset sprite.
            starts = [(index * 2 + tile) * assets.TILE_BYTES for tile in range(2)]
            pair = bytearray()
            for row in range(assets.PIECE_HEIGHT):
                for start in starts:
                    page = pages[start // assets.PAGE_SIZE]
                    local = start % assets.PAGE_SIZE
                    offset = local + (assets.PIECE_STORAGE_ROW + row) * 8
                    pair.extend(page[offset:offset + 8])
            opaque = []
            for row in range(assets.PIECE_HEIGHT):
                for byte_column, value in enumerate(pair[row * 16:(row + 1) * 16]):
                    for nibble, pixel in enumerate((value >> 4, value & 15)):
                        if pixel != assets.TRANSPARENT:
                            opaque.append((byte_column * 2 + nibble, row))
            min_x = min(x for x, _y in opaque)
            max_x = max(x for x, _y in opaque)
            min_y = min(y for _x, y in opaque)
            max_y = max(y for _x, y in opaque)
            self.assertGreaterEqual(max_x - min_x + 1, 30)
            self.assertGreaterEqual(max_y - min_y + 1, 15)

    def test_nibble_order_and_byte_transparency(self):
        self.assertEqual(assets.pack_pair(1, 2), 0x12)
        pages, _manifest, _widths = self.build()
        piece_data = b"".join(pages)[:assets.PIECE_TILES * assets.TILE_BYTES]
        for value in piece_data:
            left, right = value >> 4, value & 15
            self.assertTrue((left == 15) == (right == 15))
            self.assertLessEqual(left, 15)
            self.assertLessEqual(right, 15)

    def test_palette_profiles_themes_and_about_grid(self):
        pages, manifest, widths = self.build()
        palette = manifest["palette"]
        self.assertEqual(palette["gameplay_profile"], {"offset": 0, "length": 768})
        self.assertEqual(palette["gameplay_profiles"], {"count": 3, "stride": 768})
        self.assertEqual(palette["about_profile"], {"offset": 2304, "length": 768})
        self.assertEqual(palette["theme_table"]["pairs"], 5)
        self.assertEqual(palette["theme_slots"], [10, 11])
        self.assertEqual(pages[4][assets.THEME_TABLE_OFFSET:
                                  assets.THEME_TABLE_OFFSET + 6],
                         bytes(component for rgb in assets.THEME_RGB[0] for component in rgb))
        about = manifest["about"]
        self.assertEqual((about["width"], about["height"]), (384, 192))
        self.assertEqual((about["tile_columns"], about["tile_rows"]), (24, 6))
        self.assertEqual(about["tile_refs"][0], 0x0108)
        self.assertEqual(about["tile_refs"][-1], 0x0317)
        self.assertEqual(len(widths), 256)
        self.assertNotEqual(widths[ord("i")], widths[ord("W")])

    def test_malformed_piece_png_is_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            bad = Path(name) / "pieces.png"
            bad.write_bytes(b"\0" * 10)
            with self.assertRaisesRegex(ValueError, "PNG signature"):
                assets.read_png_rgba(bad, 192, 32)


if __name__ == "__main__":
    unittest.main()
