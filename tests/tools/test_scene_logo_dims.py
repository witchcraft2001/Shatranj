#!/usr/bin/env python3
"""Anti-drift check: asm/sprinter/scene_s4.asm's LOGO_WIDTH_PX/LOGO_HEIGHT_PX
compile-time EQUs must match assets/sprinter/logo_sprinter.png's actual
size. The banner blit (scene_draw_banner) reads these EQUs to size the
tile_width/tile_stride/tile_rows parameters and to compute the right-
aligned LOGO_X_BYTE; a PNG resize without a matching EQU update would
silently misalign or garble the banner instead of failing the build (the
grep-based cross-check pattern is test_next_board_theme_rgb333.py's
precedent for pinning an ASM constant against external data).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent.parent
SCENE_ASM = ROOT / "asm/sprinter/scene_s4.asm"
LOGO_PNG = ROOT / "assets/sprinter/logo_sprinter.png"

EQU_RE = re.compile(r"^(LOGO_WIDTH_PX|LOGO_HEIGHT_PX)\s+EQU\s+(\d+)\s*$", re.MULTILINE)


class SceneLogoDimsTests(unittest.TestCase):
    def test_asm_equs_match_the_committed_png_size(self) -> None:
        self.assertTrue(SCENE_ASM.is_file(), f"missing {SCENE_ASM}")
        self.assertTrue(LOGO_PNG.is_file(), f"missing {LOGO_PNG}")

        text = SCENE_ASM.read_text(encoding="utf-8")
        values = dict(EQU_RE.findall(text))
        self.assertIn("LOGO_WIDTH_PX", values,
                       "LOGO_WIDTH_PX EQU not found in scene_s4.asm")
        self.assertIn("LOGO_HEIGHT_PX", values,
                       "LOGO_HEIGHT_PX EQU not found in scene_s4.asm")

        asm_w, asm_h = int(values["LOGO_WIDTH_PX"]), int(values["LOGO_HEIGHT_PX"])
        png_w, png_h = Image.open(LOGO_PNG).size

        self.assertEqual(
            (asm_w, asm_h), (png_w, png_h),
            f"scene_s4.asm's LOGO_WIDTH_PX/LOGO_HEIGHT_PX ({asm_w}x{asm_h}) "
            f"do not match {LOGO_PNG}'s actual size ({png_w}x{png_h}) -- "
            "update the EQUs (and LOGO_STRIDE follows automatically)"
        )

    def test_logo_width_is_even(self) -> None:
        # 4bpp packs 2 pixels/byte; LOGO_STRIDE = LOGO_WIDTH_PX/2 must be exact.
        png_w, _ = Image.open(LOGO_PNG).size
        self.assertEqual(png_w % 2, 0)


if __name__ == "__main__":
    unittest.main()
