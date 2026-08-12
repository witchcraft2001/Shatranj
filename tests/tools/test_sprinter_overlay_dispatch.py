#!/usr/bin/env python3
"""Byte-level ABI checks on the linked overlay_loader_sprinter.asm.

Successor to the deleted tests/sprinter/z80/t_ovl_dispatch.asm (S3's
sjasmplus-based ovl_s3.asm test, whose fixture dummy_overlay.asm no longer
exists -- plan D4). overlay_loader_sprinter.asm is a z88dk-z80asm module
linked into build/sprinter/resident_c.bin, not a standalone sjasmplus
--raw job, so the existing tools/run_sprinter_z80_tests.sh harness (which
assembles each test file with sjasmplus) cannot exercise it directly.

Mirrors tools/check_overlay_entry_abi.py's check_dispatchers() -- which
checks the ZX/Next dispatchers by instruction-matching their (SDCC/IY-
specific) source text -- but works from the compiled machine code instead,
since overlay_loader_sprinter.asm's source is z88dk-z80asm, not the
SDCC-oriented shape that check expects (no IY/IX frame-pointer unwinding:
Sprinter's flat-window model never needed it). Confirms the DISPATCH ABI
port.md documents matches asm/esxdos/overlay_loader.asm: context in both
DE and HL, DI before the dispatch RET, EI on return via ovl_return. The
CALLER-side argument layout is intentionally NOT byte-for-byte the same as
ZX/Next -- see overlay_loader_sprinter.asm's file banner: z88dk's
-clib=default (Small-C-derived) convention promotes every scalar argument
to a full 16-bit stack slot, landing entry_id's value at SP+2 and ovl_id's
at SP+4, not SP+2/SP+3 the way SDCC packs them on ZX/Next.

Since S5 substep 3b the loader has TWO dispatch modes (plan D2 vs D7-bis):
mode 0 copies a 2 KiB blob into OVL_SLOT (CONTROL), mode 1 maps a whole
page into WIN3 and dispatches in place (RULES/BOARD, whose compiled size
does not fit the copy slot at all). The shared parts above are checked once;
the mode-specific ones -- which return trampoline each arms, and that the
WIN3 window is captured under DI and always restored to the value that was
read rather than to a constant (rule R7) -- have their own tests below.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
RESIDENT_C_BIN = ROOT / "build/sprinter/resident_c.bin"
RESIDENT_C_MAP = ROOT / "build/sprinter/resident_c.map"


def _map_symbol(text: str, name: str) -> int:
    match = re.search(rf"^{re.escape(name)}\s+= \$([0-9A-Fa-f]+)", text, re.MULTILINE)
    if not match:
        raise AssertionError(f"symbol {name!r} not found in {RESIDENT_C_MAP}")
    return int(match.group(1), 16)


class SprinterOverlayDispatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not RESIDENT_C_BIN.is_file() or not RESIDENT_C_MAP.is_file():
            raise unittest.SkipTest(
                f"{RESIDENT_C_BIN} missing; run 'make build/sprinter/resident_c.bin' first"
            )
        cls.data = RESIDENT_C_BIN.read_bytes()
        cls.map_text = RESIDENT_C_MAP.read_text(encoding="ascii", errors="replace")
        cls.base = _map_symbol(cls.map_text, "C_IMAGE_ENTRY_ADDR") \
            if "C_IMAGE_ENTRY_ADDR" in cls.map_text else _map_symbol(cls.map_text, "start")

    def _bytes_at(self, symbol: str, length: int) -> bytes:
        addr = _map_symbol(self.map_text, symbol)
        offset = addr - self.base
        self.assertGreaterEqual(offset, 0, f"{symbol} lands before the image base")
        return self.data[offset:offset + length]

    def test_exec_cached_decodes_word_padded_stack_args(self) -> None:
        # ld hl,2 / add hl,sp / ld a,(hl) -- entry_id's low byte at SP+2
        # (z88dk's -clib=default pads every scalar arg to a 16-bit stack
        # slot; see overlay_loader_sprinter.asm's file banner), stored via
        # ld (nn),a (address varies, not checked). Then inc hl / inc hl
        # skips SP+3's zero padding byte and lands on ovl_id's low byte
        # at SP+4.
        window = self._bytes_at("ovl_exec_cached", 11)
        self.assertEqual(window[0], 0x21)              # ld hl,nn
        self.assertEqual(int.from_bytes(window[1:3], "little"), 2)
        self.assertEqual(window[3], 0x39)               # add hl,sp
        self.assertEqual(window[4], 0x7E)               # ld a,(hl) -> entry_id
        self.assertEqual(window[5], 0x32)               # ld (nn),a -> store
        self.assertEqual(window[8], 0x23)               # inc hl
        self.assertEqual(window[9], 0x23)               # inc hl
        self.assertEqual(window[10], 0x7E)              # ld a,(hl) -> ovl_id

    def test_exec_invalidates_cache_unconditionally(self) -> None:
        # ovl_exec: ld a,0xFF / ld (ovl_v_loaded_id),a -- falls through into
        # ovl_exec_cached, which must be the very next linked address.
        window = self._bytes_at("ovl_exec", 5)
        self.assertEqual(window[0:2], bytes([0x3E, 0xFF]))   # ld a,#FF
        self.assertEqual(window[2], 0x32)                     # ld (nn),a
        exec_addr = _map_symbol(self.map_text, "ovl_exec")
        cached_addr = _map_symbol(self.map_text, "ovl_exec_cached")
        self.assertEqual(cached_addr, exec_addr + 5)

    def test_overlay_context_is_the_shared_lowram_region(self) -> None:
        """The loader's `ovl_ctx` and the portable C `spectrum_overlay_context`
        must be the SAME bytes.

        Regression test for the P12 first-MAME-run bug (2026-08-11): the
        loader had its own private BSS buffer while board.c wrote the
        arguments to LOWRAM_OVERLAY_CONTEXT, so RULES read whatever main.c
        had last left in the private buffer as its board pointer and
        answered "illegal" for every move -- a wrong answer, not a crash,
        which is why nothing before this caught it. Two names for one buffer
        can only be kept in sync by a check like this one.
        """
        layout = json.loads((ROOT / "src/sprinter/fixed_layout.json").read_text())
        region = next(r for r in layout["regions"]
                      if r["name"] == "LOWRAM_OVERLAY_CONTEXT")
        expected = int(region["addr"], 16)
        self.assertEqual(_map_symbol(self.map_text, "ovl_ctx"), expected)
        self.assertEqual(_map_symbol(self.map_text, "_ovl_ctx"), expected)

        # ...and the region must still be big enough for the widest context
        # any ported entry reads. board_apply_ovl.c's apply entry uses
        # ctx[0..7]; overlay_context.h calls the 8-byte size ABI-contractual.
        self.assertGreaterEqual(int(region["size"], 16), 8)

    def test_dispatch_sets_context_in_both_de_and_hl(self) -> None:
        # ld de,ovl_ctx / ld hl,ovl_ctx -- the same absolute address loaded
        # into both registers (native ASM entries read DE; a future C
        # fastcall entry would read HL), then di; ret (jumps into the
        # entry via the address pushed just before).
        ctx_addr = _map_symbol(self.map_text, "ovl_ctx")
        de_hl_di_ret = (
            bytes([0x11]) + ctx_addr.to_bytes(2, "little")   # ld de,ovl_ctx
            + bytes([0x21]) + ctx_addr.to_bytes(2, "little")  # ld hl,ovl_ctx
            + bytes([0xF3, 0xC9])                             # di; ret
        )
        self.assertIn(de_hl_di_ret, self.data)

    def test_ovl_return_is_ei_ret(self) -> None:
        window = self._bytes_at("ovl_return", 2)
        self.assertEqual(window, bytes([0xFB, 0xC9]))   # ei; ret

    def test_dispatch_pushes_the_return_trampoline_before_the_entry_target(self) -> None:
        # ld hl,(ovl_v_return_addr) / push hl / push de -- de holds the
        # entry's own address (read from the entry table just before), so RET
        # inside the entry returns to the trampoline, not to the caller
        # directly -- that's what turns the entry's own "ret" into "EI;
        # ret to the real caller" without the entry knowing about EI at all.
        # The trampoline is a variable rather than a literal since S5 substep
        # 3b: mode 0 uses ovl_return, mode 1 ovl_return_win3 (next test).
        slot = _map_symbol(self.map_text, "ovl_v_return_addr")
        sequence = (
            bytes([0x2A]) + slot.to_bytes(2, "little")   # ld hl,(ovl_v_return_addr)
            + bytes([0xE5])                                # push hl
            + bytes([0xD5])                                # push de
        )
        self.assertIn(sequence, self.data)

    def test_each_mode_selects_its_own_return_trampoline(self) -> None:
        # Both dispatch modes must arm a trampoline, and they must not arm
        # the same one: mode 0 (copy, CONTROL) returns through ovl_return
        # (plain ei/ret), mode 1 (WIN3-mapped, RULES/BOARD) must return
        # through ovl_return_win3 so the window is put back. A mode-1
        # dispatch that armed ovl_return would leave WIN3 pointing at the
        # overlay page with interrupts back on -- silent corruption of every
        # later render, which is exactly what this pins.
        slot = _map_symbol(self.map_text, "ovl_v_return_addr")
        for name in ("ovl_return", "ovl_return_win3"):
            addr = _map_symbol(self.map_text, name)
            arm = (
                bytes([0x21]) + addr.to_bytes(2, "little")   # ld hl,<trampoline>
                + bytes([0x22]) + slot.to_bytes(2, "little")  # ld (ovl_v_return_addr),hl
            )
            self.assertIn(arm, self.data, f"no dispatch path arms {name}")

    def test_win3_mapping_saves_and_restores_the_window_it_read(self) -> None:
        # Plan D7-bis / rule R7: a WIN3-mapped overlay may only replace the
        # window under DI, and must restore the value it READ, never a
        # constant -- the same discipline gfx_core.asm/text640.asm follow,
        # and the reason a resident render primitive called from inside such
        # an overlay hands the overlay's own page back on return.
        win3_port = 0xE2
        saved = _map_symbol(self.map_text, "ovl_v_saved_win3")

        # di / in a,(#E2) / ld (ovl_v_saved_win3),a  -- read under DI
        capture = (
            bytes([0xF3])                                  # di
            + bytes([0xDB, win3_port])                     # in a,(#E2)
            + bytes([0x32]) + saved.to_bytes(2, "little")  # ld (saved),a
        )
        self.assertIn(capture, self.data,
                      "WIN3 must be captured under DI before being replaced")

        # ld a,(ovl_v_saved_win3) / out (#E2),a -- restore the captured
        # value. Must appear on BOTH exit paths: the normal return
        # trampoline and the bad-entry-id failure path.
        restore = (
            bytes([0x3A]) + saved.to_bytes(2, "little")   # ld a,(saved)
            + bytes([0xD3, win3_port])                    # out (#E2),a
        )
        self.assertGreaterEqual(
            self.data.count(restore), 2,
            "WIN3 must be restored on both the return and the failure path")

        # No constant ever gets written to WIN3 by this module: an
        # "ld a,<imm> / out (#E2),a" would be exactly the R7 violation the
        # rule forbids (restoring to a constant instead of the saved value).
        for imm in range(256):
            self.assertNotIn(bytes([0x3E, imm, 0xD3, win3_port]), self.data,
                             f"WIN3 restored to the constant {imm:#04x}")

    def test_atlas_bad_id_reports_bad_entry(self) -> None:
        # ovl_fail_ret: ld a,#FF (OVL_ERR_BAD_ENTRY) / scf / ret.
        addr = _map_symbol(self.map_text, "ovl_fail_ret")
        offset = addr - self.base
        window = self.data[offset:offset + 4]
        self.assertEqual(window, bytes([0x3E, 0xFF, 0x37, 0xC9]))

    def test_failure_path_unmaps_win3_before_returning(self) -> None:
        # ovl_dispatch_fail is reachable with WIN3 already mapped (a bad
        # entry id on a mode-1 overlay), so it must consult the mapped flag
        # and undo the window before falling through to ovl_fail_ret --
        # otherwise a rejected dispatch leaks the overlay page into WIN3.
        fail_addr = _map_symbol(self.map_text, "ovl_dispatch_fail")
        ret_addr = _map_symbol(self.map_text, "ovl_fail_ret")
        self.assertGreater(ret_addr, fail_addr,
                           "ovl_dispatch_fail must run before ovl_fail_ret")
        mapped = _map_symbol(self.map_text, "ovl_v_win3_mapped")
        window = self.data[fail_addr - self.base:ret_addr - self.base]
        self.assertEqual(window[0], 0x3A)                                  # ld a,(nn)
        self.assertEqual(int.from_bytes(window[1:3], "little"), mapped)    # ...the flag
        self.assertIn(bytes([0xD3, 0xE2]), window, "failure path never touches WIN3")
        self.assertEqual(window[-1], 0xFB, "failure path must EI after unmapping")

    def test_main_calls_ovl_exec_for_control(self) -> None:
        # src/sprinter/main.c's real (not merely linked) dispatch call:
        # ovl_exec(14u, 0u) -- CONTROL, entry SPECTRUM_OVL_CONTROL_CLASSIFY.
        # z88dk's -clib=default convention pushes args left-to-right, each
        # padded to a 16-bit stack slot, so after "call _ovl_exec" the
        # callee sees entry_id at SP+2 and ovl_id at SP+4 -- exactly what
        # ovl_exec_cached's own decode (tested above) expects. This is the
        # one place S5 substep 2's
        # whole toolchain (D3's lowram_map.h branch, control_ovl.c linked
        # unmodified, gen_sprinter_overlay_defs.py's resident externs, the
        # dense atlas table) gets exercised as a single call, not just
        # separately linked -- MAME/hardware execution is still pending a
        # human tester (CLAUDE.md rule 6), but the call site itself is a
        # static, CI-enforced fact.
        ovl_exec_addr = _map_symbol(self.map_text, "_ovl_exec")
        call_sequence = bytes([0xCD]) + ovl_exec_addr.to_bytes(2, "little")
        self.assertIn(call_sequence, self.data)


if __name__ == "__main__":
    unittest.main()
