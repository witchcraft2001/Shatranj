#!/usr/bin/env python3
"""Pin the Sprinter WIN3 cold-code page's two-way call ABI.

The cold page is where the painters (render_core*.asm), gui.c and the
DIRECT join UI live: linked at #C000, shipped as the fifth asset page,
mapped into WIN3 for the duration of one call by the stubs
tools/gen_sprinter_cold_thunks.py generates. Several separate files have
to agree for that to work, and none of them can see the others at build
time -- so the agreement is pinned here instead:

  * the crt0's ORG, the packer's COLD_PAGE_ORG and the Makefile's
    SPRINTER_COLD_PAGE_ORG all name the same window base, and the crt0
    puts the generated entry table at that address before anything else;
  * the WIN1 stubs and the cold-page entry table are generated from ONE
    ordered allowlist and agree slot for slot (the stubs call by address,
    so a renumbering that reached only one side would dispatch into the
    wrong routine and still link);
  * the trampoline does not disturb the caller's argument frame, and its
    saved state is per-call rather than global. Both are mistakes that
    link cleanly and fail only at runtime, which is exactly what a unit
    test is for.

The build itself re-checks the table against the linked .map
(`--mode verify`, part of the cold-page recipe), so this file covers the
generator's logic and the source-side agreements, not the link result.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import gen_sprinter_cold_defs as colddefs  # noqa: E402
import gen_sprinter_cold_thunks as thunks  # noqa: E402
import make_sprinter_cold_page as coldpage  # noqa: E402

CRT0 = ROOT / "asm" / "sprinter" / "zcc" / "cold_page_crt0.asm"
MAKEFILE = ROOT / "Makefile"
RENDER_CORE = ROOT / "asm" / "sprinter" / "zcc" / "render_core.asm"
RENDER_CORE_COLD = ROOT / "asm" / "sprinter" / "zcc" / "render_core_cold.asm"
RENDER_SHIM = ROOT / "asm" / "sprinter" / "zcc" / "render_shim.asm"


class ColdPageOrgAgreementTest(unittest.TestCase):
    def test_crt0_org_matches_the_packer(self):
        text = CRT0.read_text(encoding="utf-8")
        match = re.search(r"defc CRT_ORG_CODE = \$([0-9A-Fa-f]+)", text)
        self.assertIsNotNone(match, "cold_page_crt0.asm has no CRT_ORG_CODE default")
        self.assertEqual(int(match.group(1), 16), coldpage.COLD_PAGE_ORG)

    def test_makefile_org_matches_the_packer(self):
        text = MAKEFILE.read_text(encoding="utf-8")
        match = re.search(r"SPRINTER_COLD_PAGE_ORG := (0x[0-9A-Fa-f]+)", text)
        self.assertIsNotNone(match, "Makefile has no SPRINTER_COLD_PAGE_ORG")
        self.assertEqual(int(match.group(1), 16), coldpage.COLD_PAGE_ORG)

    def test_org_is_the_win3_window_base(self):
        self.assertEqual(coldpage.COLD_PAGE_ORG, 0xC000)
        self.assertEqual(thunks.COLD_ENTRY_BASE, coldpage.COLD_PAGE_ORG)

    def test_crt0_emits_the_entry_table_first(self):
        # Anything emitted between `org` and the table shifts every slot,
        # and the WIN1 stubs would keep calling the old addresses.
        text = CRT0.read_text(encoding="utf-8")
        org = text.index("org     CRT_ORG_CODE")
        include = text.index('INCLUDE "cold_entry_table.inc"')
        self.assertLess(org, include)
        between = text[org:include].splitlines()[1:]
        for line in between:
            code = line.split(";")[0].strip()
            self.assertEqual(code, "", f"emitted before the entry table: {line!r}")


class ColdPagePackingTest(unittest.TestCase):
    def test_pads_to_one_page(self):
        page = coldpage.build_cold_page(b"\xAA" * 100)
        self.assertEqual(len(page), coldpage.PAGE_SIZE)
        self.assertEqual(page[:100], b"\xAA" * 100)
        self.assertEqual(page[100:], bytes(coldpage.PAGE_SIZE - 100))

    def test_rejects_an_oversize_image(self):
        with self.assertRaises(SystemExit) as ctx:
            coldpage.build_cold_page(bytes(coldpage.PAGE_SIZE + 1))
        self.assertIn("exceeds", str(ctx.exception))


class ColdThunkGenerationTest(unittest.TestCase):
    def setUp(self):
        self.thunks = thunks.render_thunks(thunks.COLD_THUNK_SYMBOLS)
        self.table = thunks.render_entry_table(thunks.COLD_THUNK_SYMBOLS)

    def test_every_allowlisted_symbol_gets_a_stub_and_a_slot(self):
        for name in thunks.COLD_THUNK_SYMBOLS:
            self.assertIn(f"PUBLIC _{name}\n_{name}:\n", self.thunks, name)
            self.assertIn(f"_cold_e_{name}:", self.table, name)
        self.assertEqual(self.thunks.count("    jp cold_call"),
                         len(thunks.COLD_THUNK_SYMBOLS))
        self.assertEqual(self.table.count("    jp _"),
                         len(thunks.COLD_THUNK_SYMBOLS))

    def test_the_two_halves_agree_slot_for_slot(self):
        # The one failure mode neither the linker nor the runtime can
        # catch: a stub that calls the address of a DIFFERENT entry.
        for index, name in enumerate(thunks.COLD_THUNK_SYMBOLS):
            addr = thunks.entry_addr(index)
            self.assertIn(f"ld hl,${addr:04X}   ; cold entry {index}", self.thunks)
            self.assertIn(f"_cold_e_{name}:            ; ${addr:04X}", self.table)

    def test_the_table_fits_the_window(self):
        self.assertLess(thunks.entry_addr(len(thunks.COLD_THUNK_SYMBOLS)), 0x10000)

    def test_the_trampoline_does_not_call_the_target(self):
        # THE regression this shape exists to prevent. A `call` pushes an
        # extra word, so any target reading arguments at SP+2 (z88dk
        # classic's ordinary convention -- every gui.c entry) would read
        # the caller's return address instead. The trampoline must swap the
        # return address for cold_ret and `jp` instead.
        trampoline = self.thunks.split("--- entry stubs")[0]
        self.assertNotIn("    call ", trampoline)
        self.assertIn("ld bc,cold_ret", trampoline)
        self.assertIn("cold_v_jp:\n    jp 0", trampoline)

    def test_the_trampoline_restores_the_window_it_read(self):
        # Rule R7's save-what-you-found half: the restore must come from
        # the byte that was read, never from a constant page number.
        trampoline = self.thunks.split("--- entry stubs")[0]
        self.assertIn("in a,(WIN3_PORT)", trampoline)
        self.assertIn("out (WIN3_PORT),a", trampoline)
        self.assertNotIn("ld a,COLD", trampoline)

    def test_the_trampoline_saves_per_call_not_globally(self):
        # Cold-page code calls back into the resident, which calls painters
        # again through these stubs. A single saved-page cell would have
        # the inner call overwrite the outer call's saved page.
        trampoline = self.thunks.split("--- entry stubs")[0]
        self.assertIn("cold_v_stack: defs COLD_SAVE_DEPTH*3", trampoline)
        self.assertIn("ld bc,(cold_v_sp)", trampoline)
        self.assertIn("cold_v_depth", trampoline)
        self.assertIn("jr nc,cold_too_deep", trampoline)

    def test_stub_and_trampoline_agree_on_the_stack(self):
        # The stub pushes AF then HL; the trampoline must pop them in the
        # mirror order, or every call returns with the two swapped.
        stub = self.thunks.split("--- entry stubs")[1]
        self.assertLess(stub.index("push af"), stub.index("push hl"))
        trampoline = self.thunks.split("--- entry stubs")[0]
        pops = re.findall(r"pop (bc|hl|af)", trampoline)
        self.assertEqual(pops[:3], ["bc", "hl", "af"])

    def test_the_sjasmplus_mirror_runs_the_same_instructions(self):
        # tests/sprinter/z80/t_cold_thunk.asm executes the mirror, so its
        # proof is only worth anything while the two carry the same code.
        # Only directives may differ (sjasmplus takes neither z80asm's
        # `defc` nor its MODULE/SECTION/PUBLIC/EXTERN).
        def instructions(text):
            out = []
            for line in text.splitlines():
                code = line.split(";")[0].strip()
                if not code or code.endswith(":") or code.startswith((
                        "MODULE", "SECTION", "PUBLIC", "EXTERN", "defc",
                        "COLD_SAVE_DEPTH")):
                    continue
                out.append(code)
            return out

        mirror = thunks.render_thunks_sjasmplus()
        real = instructions(self.thunks.split("--- entry stubs")[0])
        self.assertEqual(instructions(mirror.split("--- entry stubs")[0]), real)

    def test_output_is_deterministic(self):
        self.assertEqual(thunks.render_thunks(thunks.COLD_THUNK_SYMBOLS), self.thunks)
        self.assertEqual(thunks.render_entry_table(thunks.COLD_THUNK_SYMBOLS), self.table)


class ColdEntryTableVerifyTest(unittest.TestCase):
    """The post-link check the cold-page build recipe runs."""

    def _symbols(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cold.map"
            path.write_text(thunks._clean_fixture(), encoding="ascii")
            return thunks.parse_map(path)

    def test_accepts_a_correctly_placed_table(self):
        thunks.verify(self._symbols(), thunks.COLD_THUNK_SYMBOLS)

    def test_rejects_a_displaced_slot(self):
        symbols = self._symbols()
        symbols["cold_e_" + thunks.COLD_THUNK_SYMBOLS[1]] += 1
        with self.assertRaises(thunks.ColdThunksError) as ctx:
            thunks.verify(symbols, thunks.COLD_THUNK_SYMBOLS)
        self.assertIn("not at the address", str(ctx.exception))

    def test_rejects_a_body_outside_the_window(self):
        symbols = self._symbols()
        symbols[thunks.COLD_THUNK_SYMBOLS[0]] = 0x7000
        with self.assertRaises(thunks.ColdThunksError) as ctx:
            thunks.verify(symbols, thunks.COLD_THUNK_SYMBOLS)
        self.assertIn("outside the WIN3 window", str(ctx.exception))


class ColdDefsTest(unittest.TestCase):
    """The other direction: cold-page code calling back into WIN1."""

    def test_no_symbol_is_claimed_by_both_images(self):
        both = set(colddefs.COLD_RESIDENT_SYMBOLS) & set(thunks.COLD_THUNK_SYMBOLS)
        self.assertEqual(both, set(),
                         "symbol is both a cold-page entry and a resident defc")

    def test_rejects_a_resident_symbol_inside_the_win3_window(self):
        # The one mistake that would link and then call itself: a "resident"
        # address that actually landed in the paged window.
        with self.assertRaises(colddefs.ColdDefsError) as ctx:
            colddefs.render({"spectrum_frame_wait": 0xC123}, ["spectrum_frame_wait"])
        self.assertIn("outside the always-mapped", str(ctx.exception))


class ColdPageSourceAgreementTest(unittest.TestCase):
    def _asm_publics(self) -> set[str]:
        names: set[str] = set()
        for path in (RENDER_CORE, RENDER_CORE_COLD):
            for line in path.read_text(encoding="utf-8").splitlines():
                match = re.match(r"\s*PUBLIC\s+_(\S+)\s*$", line)
                if match:
                    names.add(match.group(1))
        return names

    # src/sprinter/session_sprinter.c (S8 relief pass): its entries share
    # no common prefix the way gui.c's/net_ui_sprinter.c's spectrum_gui_/
    # spectrum_net_ names do, so they are named explicitly here instead --
    # same "trust the compiler+linker, not a regex" reasoning as the
    # prefix check below (that file's own header has the full byte-budget
    # history of why each one is public rather than static).
    SESSION_SPRINTER_C_SIDE = frozenset({
        "board_select_or_move",
        "handle_menu_action",
        "net_control_key",
        "net_drop",
        "net_op_busy",
        "net_chat_blocked",
        "net_poll_once",
        "net_retry_tick",
        "net_set_turn_label_from_side",
        "pending_local_clear",
        "selection_clear",
        "takeback_snapshot_save",
    })

    def test_allowlist_names_no_absent_asm_entry(self):
        # Only the asm half can be checked from source (the C half's
        # publics are settled by the compiler); a name that is neither an
        # asm public nor a C entry fails the build's own verify step.
        asm = self._asm_publics()
        c_side = {
            # src/spectrum/ui/gui.c and src/sprinter/net_ui_sprinter.c
            name for name in thunks.COLD_THUNK_SYMBOLS
            if name.startswith(("spectrum_gui_", "spectrum_net_"))
        } | (set(thunks.COLD_THUNK_SYMBOLS) & self.SESSION_SPRINTER_C_SIDE)
        missing = sorted(set(thunks.COLD_THUNK_SYMBOLS) - asm - c_side)
        self.assertEqual(missing, [],
                         "COLD_THUNK_SYMBOLS names an entry no cold-page "
                         "source provides")

    def test_the_shim_keeps_the_per_frame_bridges_resident(self):
        # These three are called every frame and are 1-9 bytes long; a
        # thunk would cost more than the routine. They are also what the
        # cold page calls BACK into, which only works while they are
        # resident -- so they must be in the shim, out of the thunk
        # allowlist, and in the cold-defs allowlist.
        shim = RENDER_SHIM.read_text(encoding="utf-8")
        for name in ("spectrum_frame_wait", "spectrum_key_poll",
                     "spectrum_uart_background_pump"):
            self.assertIn(f"PUBLIC _{name}", shim)
            self.assertNotIn(name, thunks.COLD_THUNK_SYMBOLS)
            self.assertIn(name, colddefs.COLD_RESIDENT_SYMBOLS)


class ColdPageBuildOrderTest(unittest.TestCase):
    """The reversed order is load-bearing, so it is pinned here too."""

    def test_thunks_do_not_depend_on_the_cold_page_map(self):
        text = MAKEFILE.read_text(encoding="utf-8")
        rule = text.split("$(SPRINTER_COLD_THUNKS_ASM): ")[1].split("\n\n")[0]
        self.assertNotIn("COLD_IMAGE_MAP", rule,
                         "the WIN1 stubs must be generated from the allowlist "
                         "alone, or the build order cannot be reversed")

    def test_cold_page_depends_on_the_resident_map(self):
        text = MAKEFILE.read_text(encoding="utf-8")
        rule = text.split("$(SPRINTER_COLD_DEFS_ASM): ")[1].split("\n\n")[0]
        self.assertIn("SPRINTER_RESIDENT_C_MAP", rule)


if __name__ == "__main__":
    unittest.main(verbosity=2)
