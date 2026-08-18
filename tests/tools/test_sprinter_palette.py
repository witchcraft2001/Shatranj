#!/usr/bin/env python3
"""Unit tests for tools/gen_sprinter_palette.py (S4 semantic palette).

The bulk of the schema validation is exercised by the tool's own
--self-test (broken-fixture cases, mirroring gen_sprinter_render_layout.py).
This suite instead guards the real committed assets/sprinter/palette.json
and the anti-drift property that matters for S4: the generated .inc and the
packed theme blob must decode back to exactly what the JSON says, so the
resident's boot palette, the theme table, and (in later steps) the piece
packer's reference RGBs can never silently disagree.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import gen_sprinter_palette as gsp

ROOT = Path(__file__).resolve().parent.parent.parent
PALETTE_JSON = ROOT / "assets/sprinter/palette.json"
VIDEO_ASM = ROOT / "asm/sprinter/video.asm"

_INC_ROW_RE = re.compile(
    r"DB 0x([0-9A-Fa-f]{2}),0x([0-9A-Fa-f]{2}),0x([0-9A-Fa-f]{2})\s*; (\d+) (\S+)"
)


class SprinterPaletteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(PALETTE_JSON.is_file(), f"missing {PALETTE_JSON}")
        self.palette = gsp.load_palette_file(PALETTE_JSON)

    def test_real_palette_is_valid(self) -> None:
        errors = gsp.validate_palette(self.palette)
        self.assertEqual(errors, [])

    def test_inc_rows_match_json_in_index_order(self) -> None:
        inc = gsp.render_inc(self.palette)
        rows = _INC_ROW_RE.findall(inc)
        self.assertEqual(len(rows), 16, "expected exactly 16 palette_rgb rows")
        by_index = {entry["index"]: entry for entry in self.palette["base"]}
        for i, (r, g, b, idx_str, name) in enumerate(rows):
            self.assertEqual(int(idx_str), i, "rows must be in index order 0..15")
            entry = by_index[i]
            self.assertEqual(name, entry["name"])
            want = entry["rgb"].lstrip("#").upper()
            got = f"{r}{g}{b}".upper()
            self.assertEqual(got, want, f"index {i} RGB mismatch")

    def test_theme_blob_round_trips_to_json(self) -> None:
        blob = gsp.build_theme_blob(self.palette)
        decoded = gsp.decode_theme_blob(blob)
        self.assertEqual(len(decoded["themes"]), len(self.palette["themes"]))
        for want, got in zip(self.palette["themes"], decoded["themes"]):
            self.assertEqual(got["name"], want["name"])
            self.assertEqual(
                {k: v.upper() for k, v in got["entries"].items()},
                {k: v.upper() for k, v in want["entries"].items()},
            )

    def test_theme_blob_is_at_most_256_bytes(self) -> None:
        # tools/make_sprinter_assets_page.py's THEME_MAX_SIZE: the blob
        # lands in a single 256-byte slot (slot 27).
        blob = gsp.build_theme_blob(self.palette)
        self.assertLessEqual(len(blob), 256)

    def test_accent_matches_the_real_sprinter_logo_blue(self) -> None:
        # D1: index 14's RGB is meant to be sampled from the real logo
        # (assets/sprinter/source/sprinter_logo_source.png), not invented --
        # pin the value so a future palette edit can't silently drift from
        # the brand colour without touching this test.
        accent = next(e for e in self.palette["base"] if e["index"] == 14)
        self.assertEqual(accent["rgb"].upper(), "#00BEFE")

    def test_base_rgbs_are_pairwise_distinct(self) -> None:
        # The packers invert the palette into a {rgb: index} map, where a
        # shared colour silently makes one index unreachable. Guard the
        # committed file directly, not just the generator's fixtures.
        rgbs = [e["rgb"].upper() for e in self.palette["base"]]
        self.assertEqual(len(set(rgbs)), len(rgbs), f"duplicate RGB in {rgbs}")

    def test_theme_names_leave_room_for_the_nul_terminator(self) -> None:
        # scene_draw_status prints the blob's 8-byte name field in place as
        # an ASCIIZ string, so a name may use at most 7 of those bytes.
        for theme in self.palette["themes"]:
            self.assertLessEqual(
                len(theme["name"].encode("ascii")), gsp.MAX_THEME_NAME_LEN,
                f"theme {theme['name']!r} fills the whole name field",
            )
        blob = gsp.build_theme_blob(self.palette)
        stride = gsp.THEME_NAME_FIELD_LEN + blob[2] * 4
        for i in range(blob[1]):
            field_end = 4 + i * stride + gsp.THEME_NAME_FIELD_LEN - 1
            self.assertEqual(blob[field_end], 0, f"theme {i} name field not NUL-ended")

    def test_theme_zero_equals_boot_palette(self) -> None:
        by_index = {e["index"]: e["rgb"].upper() for e in self.palette["base"]}
        theme0 = self.palette["themes"][0]
        for key, rgb in theme0["entries"].items():
            self.assertEqual(rgb.upper(), by_index[int(key)])

    def test_deterministic(self) -> None:
        self.assertEqual(
            gsp.render_inc(self.palette), gsp.render_inc(gsp.load_palette_file(PALETTE_JSON))
        )
        self.assertEqual(
            gsp.build_theme_blob(self.palette),
            gsp.build_theme_blob(gsp.load_palette_file(PALETTE_JSON)),
        )


class ShippedThemeTableTests(unittest.TestCase):
    """palette.json's themes vs the table the resident actually uses.

    The theme BLOB this tool packs into the assets page is read by nobody:
    it was S4's scene demo's source, and the shipped board themes are
    asm/sprinter/video.asm's hand-written theme_squares_rgb. So the JSON
    is documentation for two audiences that both act on it -- the artist
    brief quotes these square colours to judge piece contrast, and the
    piece-set validator rejects a piece colour that repeats one -- and
    documentation that drifts from the .asm is worse than none. Until the
    .asm table is generated from here (port.md stage S14), this test is
    the join."""

    def _asm_themes(self) -> list[tuple[str, str, str]]:
        text = VIDEO_ASM.read_text(encoding="utf-8", errors="replace")
        table = text.split("theme_squares_rgb:", 1)
        self.assertEqual(len(table), 2, "theme_squares_rgb: not found in video.asm")
        themes: list[tuple[str, str, str]] = []
        name: str | None = None
        rgbs: list[str] = []
        for line in table[1].splitlines():
            stripped = line.strip()
            # "; <n> <NAME>" opens a record. Guarded on n == the record we
            # are waiting for, and on not already having a name: the first
            # record's comment wraps onto a second "; 0 ..." line, which an
            # unguarded match would read as a theme called "here".
            comment = re.match(r"^;\s*(\d+)\s+([A-Za-z]+)", stripped)
            if comment and name is None and int(comment.group(1)) == len(themes):
                name = comment.group(2)
                rgbs = []
                continue
            db = re.match(
                r"^DB\s+#([0-9A-Fa-f]{2}),#([0-9A-Fa-f]{2}),#([0-9A-Fa-f]{2})",
                stripped,
            )
            if db:
                rgbs.append("#" + "".join(g.upper() for g in db.groups()))
                if len(rgbs) == 2 and name is not None:
                    themes.append((name, rgbs[0], rgbs[1]))
                    name, rgbs = None, []
                continue
            if stripped and not stripped.startswith(";") and themes:
                break          # first non-table line after the records
        return themes

    def test_json_themes_mirror_video_asm(self) -> None:
        asm_themes = self._asm_themes()
        palette = gsp.load_palette_file(PALETTE_JSON)
        json_themes = [
            (t["name"], t["entries"]["2"].upper(), t["entries"]["3"].upper())
            for t in palette["themes"]
        ]
        self.assertEqual(json_themes, asm_themes)

    def test_theme_count_equ_matches(self) -> None:
        text = VIDEO_ASM.read_text(encoding="utf-8", errors="replace")
        match = re.search(r"THEME_COUNT\s+EQU\s+(\d+)", text)
        self.assertIsNotNone(match, "THEME_COUNT EQU not found in video.asm")
        palette = gsp.load_palette_file(PALETTE_JSON)
        self.assertEqual(int(match.group(1)), len(palette["themes"]))


class PieceSetPaletteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.palette = gsp.load_palette_file(PALETTE_JSON)

    def test_set_zero_equals_the_boot_palette(self) -> None:
        by_index = {e["index"]: e["rgb"].upper() for e in self.palette["base"]}
        for key, rgb in self.palette["piece_sets"][0]["entries"].items():
            self.assertEqual(rgb.upper(), by_index[int(key)])

    def test_every_set_owns_exactly_the_piece_entries(self) -> None:
        for piece_set in self.palette["piece_sets"]:
            self.assertEqual(
                {int(k) for k in piece_set["entries"]},
                set(gsp.PIECE_SET_INDICES),
                piece_set["name"],
            )

    def test_inc_has_one_record_per_set(self) -> None:
        inc = gsp.render_piece_sets_inc(self.palette)
        self.assertIn(f"PIECE_SET_COUNT EQU {len(self.palette['piece_sets'])}", inc)
        rows = re.findall(r"DB 0x[0-9A-F]{2},0x[0-9A-F]{2},0x[0-9A-F]{2}", inc)
        self.assertEqual(len(rows), len(self.palette["piece_sets"]) * 4)

    def test_inc_deterministic(self) -> None:
        self.assertEqual(
            gsp.render_piece_sets_inc(self.palette),
            gsp.render_piece_sets_inc(gsp.load_palette_file(PALETTE_JSON)),
        )


if __name__ == "__main__":
    unittest.main()
