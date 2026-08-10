#!/usr/bin/env python3
"""Unit tests for tools/gen_sprinter_version.py (S4 banner version include).

CLAUDE.md rule 5 makes VERSION the only source of the version string. Two
callers render this include -- the Makefile's $(SPRINTER_VERSION_INC) rule
and tools/run_sprinter_z80_tests.sh -- so the properties that matter are
that the rendered text actually carries VERSION's contents, that it keeps
the guard/label shape asm/sprinter/scene_s4.asm INCLUDEs, and that it is a
pure function of the input.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import gen_sprinter_version as gsv

VERSION_FILE = ROOT / "VERSION"


class GenSprinterVersionTests(unittest.TestCase):
    def test_reads_the_repo_version_file(self) -> None:
        version = gsv.read_version(VERSION_FILE)
        self.assertTrue(version)
        self.assertEqual(version, VERSION_FILE.read_text(encoding="utf-8").strip())

    def test_rendered_inc_has_the_guard_and_label_scene_s4_expects(self) -> None:
        inc = gsv.render_inc("9.9")
        self.assertIn("IFNDEF SPRINTER_VERSION_INC", inc)
        self.assertIn("DEFINE SPRINTER_VERSION_INC", inc)
        self.assertIn("ENDIF", inc)
        self.assertIn('sprinter_banner_msg: DB "SHATRANJ v9.9",0', inc)

    def test_scene_s4_includes_this_file(self) -> None:
        # If scene_s4.asm ever stops INCLUDEing sprinter_version.inc, the
        # banner has grown a literal again (rule 5) -- fail here rather
        # than let the generator become dead weight nobody notices.
        scene = (ROOT / "asm/sprinter/scene_s4.asm").read_text(encoding="utf-8")
        self.assertIn('INCLUDE "sprinter_version.inc"', scene)
        self.assertIn("sprinter_banner_msg", scene)

    def test_deterministic(self) -> None:
        self.assertEqual(gsv.render_inc("1.1"), gsv.render_inc("1.1"))

    def test_ascii_encodable(self) -> None:
        gsv.render_inc(gsv.read_version(VERSION_FILE)).encode("ascii")

    def test_rejects_a_version_that_would_break_out_of_the_db_literal(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "VERSION"
            bad.write_text('1.1"; DB 0\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                gsv.read_version(bad)

    def test_rejects_an_empty_version_file(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / "VERSION"
            empty.write_text("\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                gsv.read_version(empty)


if __name__ == "__main__":
    unittest.main()
