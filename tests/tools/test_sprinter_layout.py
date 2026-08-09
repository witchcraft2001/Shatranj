#!/usr/bin/env python3
"""Unit tests for tools/gen_sprinter_layout.py (fixed resident layout)."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import gen_sprinter_layout as gsl

ROOT = Path(__file__).resolve().parent.parent.parent
LAYOUT_JSON = ROOT / "src/sprinter/fixed_layout.json"


class SprinterLayoutTests(unittest.TestCase):
    def test_real_layout_is_valid(self) -> None:
        layout = gsl.load_layout_file(LAYOUT_JSON)
        self.assertEqual(gsl.validate_layout(layout), [])

    def test_generation_is_idempotent(self) -> None:
        layout = gsl.load_layout_file(LAYOUT_JSON)
        symbols = gsl.compute_symbols(layout)
        with tempfile.TemporaryDirectory() as tmp:
            inc_a = Path(tmp) / "a.inc"
            inc_b = Path(tmp) / "b.inc"
            inc_a.write_text(gsl.render_inc(symbols), encoding="ascii")
            inc_b.write_text(gsl.render_inc(gsl.compute_symbols(gsl.load_layout_file(LAYOUT_JSON))),
                              encoding="ascii")
            self.assertEqual(inc_a.read_bytes(), inc_b.read_bytes())
            h_a = gsl.render_h(symbols)
            h_b = gsl.render_h(gsl.compute_symbols(gsl.load_layout_file(LAYOUT_JSON)))
            self.assertEqual(h_a, h_b)

    def test_stack_top_and_im2_derivation(self) -> None:
        layout = gsl.load_layout_file(LAYOUT_JSON)
        symbols = gsl.compute_symbols(layout)
        self.assertEqual(symbols["STACK_TOP"], 0xBD80)
        self.assertGreaterEqual(symbols["STACK_SIZE"], gsl.MIN_STACK_SIZE)
        self.assertEqual(symbols["IM2_TABLE_ADDR"] % 256, 0)
        self.assertEqual(symbols["IM2_TABLE_ADDR"] >> 8, symbols["IM2_I_REG"])
        self.assertEqual(symbols["IM2_TABLE_SIZE"], 0x101)
        self.assertEqual(
            symbols["IM2_STUB_ADDR"],
            (symbols["IM2_FILL_BYTE"] * 0x101) & 0xFFFF,
        )

    def test_broken_fixtures_are_rejected(self) -> None:
        # Exercises the same invariant families as gen_sprinter_layout.self_test,
        # via the public validate_layout() API rather than the CLI. Each case
        # asserts its own diagnostic, not just "some error": broken fixtures
        # usually violate several invariants at once, and an any-error check
        # would keep passing with the specific check deleted.
        base = gsl._clean_fixture()
        self.assertEqual(gsl.validate_layout(base), [])

        def errors_for(mutate):
            fixture = gsl._clean_fixture()
            mutate(fixture)
            return "\n".join(gsl.validate_layout(fixture))

        self.assertIn(
            "below the",
            errors_for(lambda f: gsl._region(f, "STACK").__setitem__("size", 512)),
        )
        self.assertIn(
            "fill_byte",
            errors_for(lambda f: gsl._region(f, "IM2_STUB").__setitem__("addr", 0xBDBC)),
        )
        self.assertIn(
            "missing required region: IM2_TABLE",
            errors_for(lambda f: f["regions"].remove(gsl._region(f, "IM2_TABLE"))),
        )
        # A region whose size runs past the resident end must be caught even
        # when its start address is in range.
        self.assertIn(
            "exceeds resident end",
            errors_for(lambda f: f["regions"].append(
                {"name": "X", "addr": 0xBF10, "size": 0x2000,
                 "owner": "", "desc": ""}
            )),
        )

    def test_self_test_entry_point(self) -> None:
        gsl.self_test()  # raises SystemExit on failure


if __name__ == "__main__":
    unittest.main()
