import tempfile
import unittest
import struct
import zlib
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
        self.assertEqual(len(pages1), 4)
        self.assertTrue(all(len(page) == assets.PAGE_SIZE for page in pages1))
        self.assertEqual(manifest1["gfx_page_count"], 3)

    def test_piece_geometry_storage_and_refs(self):
        pages, manifest, _widths = self.build()
        pieces = manifest["pieces"]
        self.assertEqual((pieces["visible_width"], pieces["visible_height"]), (32, 16))
        self.assertEqual((pieces["storage_tile_width"], pieces["storage_tile_height"]),
                         (32, 16))
        self.assertEqual(pieces["storage_visible_rows"], [0, 15])
        self.assertEqual(pieces["tiles_per_piece"], 1)
        refs = pieces["tile_refs"]
        sets = pieces["sets"]
        self.assertEqual(refs[sets[0]]["wK"], [0x0000])
        self.assertEqual(refs[sets[2]]["bP"], [0x0023])
        first = pages[0][:assets.TILE_BYTES]
        self.assertNotEqual(first, bytes((0xFF,)) * assets.TILE_BYTES)
        for index in range(assets.PIECE_COUNT):
            packed = bytearray()
            for row in range(assets.PIECE_HEIGHT):
                start = index * assets.TILE_BYTES + row * 16
                page = pages[start // assets.PAGE_SIZE]
                local = start % assets.PAGE_SIZE
                packed.extend(page[local:local + 16])
            opaque = []
            for row in range(assets.PIECE_HEIGHT):
                for byte_column, value in enumerate(packed[row * 16:(row + 1) * 16]):
                    for nibble, pixel in enumerate((value >> 4, value & 15)):
                        if pixel != assets.TRANSPARENT:
                            opaque.append((byte_column * 2 + nibble, row))
            min_x = min(x for x, _y in opaque)
            max_x = max(x for x, _y in opaque)
            min_y = min(y for _x, y in opaque)
            max_y = max(y for _x, y in opaque)
            self.assertGreaterEqual(max_x - min_x + 1, 30)
            self.assertGreaterEqual(max_y - min_y + 1, 15)

    def test_nibble_order_and_per_pixel_transparency(self):
        self.assertEqual(assets.pack_pair(1, 2), 0x12)
        pages, _manifest, _widths = self.build()
        piece_data = b"".join(pages)[:assets.PIECE_TILES * assets.TILE_BYTES]
        for value in piece_data:
            left, right = value >> 4, value & 15
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
        self.assertEqual(pages[3][assets.THEME_TABLE_OFFSET:
                                  assets.THEME_TABLE_OFFSET + 6],
                         bytes(component for rgb in assets.THEME_RGB[0] for component in rgb))
        about = manifest["about"]
        self.assertEqual((about["width"], about["height"]), (384, 192))
        self.assertEqual((about["tile_columns"], about["tile_rows"]), (12, 12))
        self.assertEqual(about["tile_refs"][0], 0x0024)
        self.assertEqual(about["tile_refs"][-1], 0x0233)
        self.assertEqual(len(widths), 256)
        self.assertNotEqual(widths[ord("i")], widths[ord("W")])

    def test_malformed_piece_png_is_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            bad = Path(name) / "pieces.png"
            bad.write_bytes(b"\0" * 10)
            with self.assertRaisesRegex(ValueError, "PNG signature"):
                assets.read_png_rgba(bad, 192, 32)

    def test_rgba_png_filters_are_decoded(self):
        width, height = 2, 2
        rgba = bytes((10, 20, 30, 255, 40, 50, 60, 0,
                      70, 80, 90, 128, 100, 110, 120, 255))

        def chunk(name, body):
            return (struct.pack(">I", len(body)) + name + body +
                    struct.pack(">I", zlib.crc32(name + body) & 0xFFFFFFFF))

        for filter_type in range(5):
            rows = bytearray()
            previous = bytes(width * 4)
            for row in range(height):
                restored = rgba[row * width * 4:(row + 1) * width * 4]
                filtered = bytearray()
                for index, value in enumerate(restored):
                    left = restored[index - 4] if index >= 4 else 0
                    above = previous[index]
                    upper_left = previous[index - 4] if index >= 4 else 0
                    if filter_type == 0:
                        filtered.append(value)
                    elif filter_type == 1:
                        filtered.append((value - left) & 0xFF)
                    elif filter_type == 2:
                        filtered.append((value - above) & 0xFF)
                    elif filter_type == 3:
                        filtered.append((value - ((left + above) >> 1)) & 0xFF)
                    else:
                        filtered.append((value - assets._paeth(left, above, upper_left)) & 0xFF)
                rows.extend((filter_type,))
                rows.extend(filtered)
                previous = restored
            png = (b"\x89PNG\r\n\x1a\n" +
                   chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) +
                   chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b""))
            with tempfile.TemporaryDirectory() as name:
                path = Path(name) / "filtered.png"
                path.write_bytes(png)
                self.assertEqual(assets.read_png_rgba(path, width, height), rgba)

    def test_grayscale_alpha_png_is_expanded_to_rgba(self):
        width, height = 2, 1
        data = bytes((0, 12, 0, 200, 255))

        def chunk(name, body):
            return (struct.pack(">I", len(body)) + name + body +
                    struct.pack(">I", zlib.crc32(name + body) & 0xFFFFFFFF))

        png = (b"\x89PNG\r\n\x1a\n" +
               chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 4, 0, 0, 0)) +
               chunk(b"IDAT", zlib.compress(data)) + chunk(b"IEND", b""))
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "gray-alpha.png"
            path.write_bytes(png)
            self.assertEqual(assets.read_png_rgba(path, width, height),
                             bytes((12, 12, 12, 0, 200, 200, 200, 255)))

    def test_adam7_rgba_png_is_decoded(self):
        width, height = 3, 2
        rgba = bytes((10, 20, 30, 255, 40, 50, 60, 0, 70, 80, 90, 128,
                      100, 110, 120, 255, 130, 140, 150, 0, 160, 170, 180, 255))
        passes = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8),
                  (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2),
                  (0, 1, 1, 2))
        data = bytearray()
        for x0, y0, x_step, y_step in passes:
            for y in range(y0, height, y_step):
                row = bytearray((0,))
                for x in range(x0, width, x_step):
                    offset = (y * width + x) * 4
                    row.extend(rgba[offset:offset + 4])
                if len(row) != 1:
                    data.extend(row)

        def chunk(name, body):
            return (struct.pack(">I", len(body)) + name + body +
                    struct.pack(">I", zlib.crc32(name + body) & 0xFFFFFFFF))

        png = (b"\x89PNG\r\n\x1a\n" +
               chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 1)) +
               chunk(b"IDAT", zlib.compress(data)) + chunk(b"IEND", b""))
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "adam7.png"
            path.write_bytes(png)
            self.assertEqual(assets.read_png_rgba(path, width, height), rgba)

    def test_transparent_alpha_is_packed_as_the_key(self):
        raw = bytes((1, 2, 3, 0, 4, 5, 6, 0)) * (assets.PIECE_WIDTH * assets.PIECE_HEIGHT // 2)
        packed = assets.quantize_piece(raw, [(0, 0, 0), (128, 128, 128), (255, 255, 255)])
        self.assertEqual(packed, bytes((assets.PACKED_TRANSPARENT,)) * len(packed))

    def test_one_transparent_pixel_keeps_its_own_key_nibble(self):
        raw = bytes((1, 2, 3, 0, 4, 5, 6, 255))
        raw *= assets.PIECE_WIDTH * assets.PIECE_HEIGHT // 2
        packed = assets.quantize_piece(raw, [(4, 5, 6), (0, 0, 0), (255, 255, 255)])
        self.assertEqual(packed, bytes((0xFC,)) * len(packed))


if __name__ == "__main__":
    unittest.main()
