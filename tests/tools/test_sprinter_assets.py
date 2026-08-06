import json
import tempfile
import unittest
from pathlib import Path

from tools import build_sprinter_assets as assets


ROOT = Path(__file__).resolve().parents[2]


class SprinterAssetTests(unittest.TestCase):
    def build(self):
        return assets.build(
            ROOT / "assets/next/lichess_piece_sprites.bin",
            ROOT / "assets/next/lichess_sprite_palette.bin",
            ROOT / "assets/next/lichess_piece_sprites.json",
            ROOT / "assets/next/about_screen.nxi",
        )

    def test_pipeline_is_deterministic_and_pages_are_exact(self):
        pages1, manifest1 = self.build()
        pages2, manifest2 = self.build()
        self.assertEqual(pages1, pages2)
        self.assertEqual(manifest1, manifest2)
        self.assertEqual(len(pages1), 5)
        self.assertTrue(all(len(page) == assets.PAGE_SIZE for page in pages1))
        self.assertEqual(manifest1["gfx_page_count"], 4)

    def test_piece_transparency_and_tile_refs(self):
        pages, manifest = self.build()
        self.assertIn(0xFF, pages[0][:assets.PIECE_TILES * assets.TILE_BYTES])
        refs = manifest["pieces"]["tile_refs"]
        sets = manifest["pieces"]["sets"]
        self.assertEqual(refs[sets[0]]["wK"], 0x0000)
        self.assertEqual(refs[sets[2]]["bP"], 0x0023)
        about = manifest["about"]["tile_refs"]
        self.assertEqual(about[0], 0x0100)
        self.assertEqual(about[63], 0x013F)
        self.assertEqual(about[64], 0x0200)
        self.assertEqual(about[-1], 0x033F)

    def test_palette_is_rgb888_and_ff_is_not_used_by_about(self):
        pages, manifest = self.build()
        palette = manifest["palette"]
        self.assertEqual(palette["length"], 768)
        self.assertEqual(palette["page_index"], 4)
        self.assertEqual(palette["encoding"], "RGB888")
        # UI colour 6 is yellow (R=248,G=224,B=72), matching the established
        # Stage 2 asset and GFX320 input contract.
        self.assertEqual(pages[4][:3], bytes((0, 0, 0)))
        self.assertEqual(pages[4][18:21], bytes((248, 224, 72)))
        about = b"".join(pages[1:4])
        self.assertNotIn(0xFF, about)

    def test_truncated_piece_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            bad = temp / "pieces.bin"
            bad.write_bytes(b"\0" * 10)
            with self.assertRaisesRegex(ValueError, "truncated"):
                assets.build(
                    bad,
                    ROOT / "assets/next/lichess_sprite_palette.bin",
                    ROOT / "assets/next/lichess_piece_sprites.json",
                    ROOT / "assets/next/about_screen.nxi",
                )

    def test_corrupt_metadata_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            bad = temp / "meta.json"
            meta = json.loads(
                (ROOT / "assets/next/lichess_piece_sprites.json").read_text()
            )
            meta["sets"] = ["only-one"]
            bad.write_text(json.dumps(meta))
            with self.assertRaisesRegex(ValueError, "three piece sets"):
                assets.build(
                    ROOT / "assets/next/lichess_piece_sprites.bin",
                    ROOT / "assets/next/lichess_sprite_palette.bin",
                    bad,
                    ROOT / "assets/next/about_screen.nxi",
                )


if __name__ == "__main__":
    unittest.main()
