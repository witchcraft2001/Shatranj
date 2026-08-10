#!/usr/bin/env python3
"""Unit tests for tools/make_sprinter_markers.py."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import make_sprinter_markers as msm

RED = (255, 0, 0)


class MarkerShapeTests(unittest.TestCase):
    def _assert_pair_uniform_alpha(self, img) -> None:
        w, h = img.size
        for y in range(h):
            for bx in range(w // 2):
                a0 = img.getpixel((2 * bx, y))[3]
                a1 = img.getpixel((2 * bx + 1, y))[3]
                self.assertEqual(
                    a0, a1, f"pixel pair ({2*bx},{2*bx+1}) row {y} has mismatched alpha"
                )
                self.assertIn(a0, (0, 255))

    def test_dot_is_16x8_with_pair_uniform_alpha(self) -> None:
        img = msm.build_dot(RED)
        self.assertEqual(img.size, (16, 8))
        self._assert_pair_uniform_alpha(img)

    def test_ring_is_16x8_with_pair_uniform_alpha(self) -> None:
        img = msm.build_ring(RED)
        self.assertEqual(img.size, (16, 8))
        self._assert_pair_uniform_alpha(img)

    def test_dot_has_some_opaque_pixels_in_the_reference_colour(self) -> None:
        img = msm.build_dot(RED)
        opaque = [img.getpixel((x, y)) for x in range(16) for y in range(8)
                  if img.getpixel((x, y))[3] == 255]
        self.assertTrue(opaque)
        self.assertTrue(all(p == RED + (255,) for p in opaque))

    def test_ring_is_hollow_in_the_middle(self) -> None:
        img = msm.build_ring(RED)
        # Centre pixels must stay transparent -- it's a ring, not a disc.
        self.assertEqual(img.getpixel((7, 3))[3], 0)
        self.assertEqual(img.getpixel((8, 4))[3], 0)

    def test_dot_and_ring_are_not_fully_transparent_or_fully_opaque(self) -> None:
        for builder in (msm.build_dot, msm.build_ring):
            img = builder(RED)
            alphas = {img.getpixel((x, y))[3] for x in range(16) for y in range(8)}
            self.assertEqual(alphas, {0, 255})


if __name__ == "__main__":
    unittest.main()
