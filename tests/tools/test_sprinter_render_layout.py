#!/usr/bin/env python3
"""Unit tests for tools/gen_sprinter_render_layout.py (screen layout)."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import gen_sprinter_render_layout as grl

ROOT = Path(__file__).resolve().parent.parent.parent
LAYOUT_JSON = ROOT / "src/sprinter/render_layout.json"


class SprinterRenderLayoutTests(unittest.TestCase):
    def test_real_layout_is_valid(self) -> None:
        layout = grl.load_layout_file(LAYOUT_JSON)
        self.assertEqual(grl.validate_layout(layout), [])

    def test_generation_is_idempotent(self) -> None:
        layout = grl.load_layout_file(LAYOUT_JSON)
        symbols = grl.compute_symbols(layout)
        with tempfile.TemporaryDirectory() as tmp:
            inc_a = Path(tmp) / "a.inc"
            inc_b = Path(tmp) / "b.inc"
            inc_a.write_text(grl.render_inc(symbols), encoding="ascii")
            inc_b.write_text(
                grl.render_inc(grl.compute_symbols(grl.load_layout_file(LAYOUT_JSON))),
                encoding="ascii",
            )
            self.assertEqual(inc_a.read_bytes(), inc_b.read_bytes())
            h_a = grl.render_h(symbols)
            h_b = grl.render_h(grl.compute_symbols(grl.load_layout_file(LAYOUT_JSON)))
            self.assertEqual(h_a, h_b)

    def test_derived_geometry_matches_port_md(self) -> None:
        layout = grl.load_layout_file(LAYOUT_JSON)
        symbols = grl.compute_symbols(layout)
        # port.md section 3.4: board x=16..399, y=40..231.
        self.assertEqual(symbols["BOARD_X"], 16)
        self.assertEqual(symbols["BOARD_X"] + symbols["BOARD_W"], 400)
        self.assertEqual(symbols["BOARD_Y"], 40)
        self.assertEqual(symbols["BOARD_Y"] + symbols["BOARD_H"], 232)
        # info panel x=408..639.
        self.assertEqual(symbols["PANEL_X"], 408)
        self.assertEqual(symbols["PANEL_X"] + symbols["PANEL_W"], 640)

    def test_broken_fixtures_are_rejected(self) -> None:
        base = grl._clean_fixture()
        self.assertEqual(grl.validate_layout(base), [])

        def errors_for(mutate):
            fixture = grl._clean_fixture()
            mutate(fixture)
            return "\n".join(grl.validate_layout(fixture))

        self.assertIn(
            "not even",
            errors_for(lambda f: f["board"].__setitem__("x", 17)),
        )
        self.assertIn(
            "missing required band: MOVE",
            errors_for(lambda f: f["bands"].remove(grl._band(f, "MOVE"))),
        )
        self.assertIn(
            "gap or overlap",
            errors_for(lambda f: grl._panel_section(f, "CHAT").__setitem__("y", 150)),
        )

    def test_self_test_entry_point(self) -> None:
        grl.self_test()  # raises SystemExit on failure


if __name__ == "__main__":
    unittest.main()
