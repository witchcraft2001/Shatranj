#!/usr/bin/env python3
"""Byte-level checks on asm/sprinter/zcc/resident_crt0.asm's probe build.

resident_crt0.asm replaces z88dk's stock pps_crt0.asm for the Sprinter
resident C image (port.md section 3.10/S5, plan D1): the stock crt0 bakes a
512-byte DSS EXE header plus PSP/argv handling into the very first bytes of
the image, which is the wrong shape for a page streamed in by
preload_loader.asm and JP'd into directly by platform_core's trampoline.
This test builds the permanent crt0_probe_main.c/crt0_probe_defs.asm
fixture (built by 'make build/sprinter/crt0_probe.bin', mirroring
dummy_overlay.asm's role for the overlay mechanism) and checks the result
byte-for-byte: no EXE magic, entry is a bare CALL into crt0_init, and
_main plus the externally-resolved fixed-address symbol both link.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
PROBE_BIN = ROOT / "build/sprinter/crt0_probe.bin"
PROBE_MAP = ROOT / "build/sprinter/crt0_probe.map"
PROBE_ORG = 0x4200
PROBE_PRIMITIVE_ADDR = 0x9000

# z88dk's stock pps_crt0.asm (lib/target/pps/classic/pps_crt0.asm) writes
# this 3-byte magic ("EXE") as the first bytes of the DSS EXE header it
# bakes into the image. resident_crt0.asm must never produce it.
DSS_EXE_MAGIC = bytes([0x45, 0x58, 0x45])


def _map_symbol(text: str, name: str) -> int:
    match = re.search(rf"^{re.escape(name)}\s+= \$([0-9A-Fa-f]+)", text, re.MULTILINE)
    if not match:
        raise AssertionError(f"symbol {name!r} not found in {PROBE_MAP}")
    return int(match.group(1), 16)


class SprinterCrt0Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not PROBE_BIN.is_file() or not PROBE_MAP.is_file():
            raise unittest.SkipTest(
                f"{PROBE_BIN} missing; run 'make build/sprinter/crt0_probe.bin' first"
            )
        cls.data = PROBE_BIN.read_bytes()
        cls.map_text = PROBE_MAP.read_text(encoding="ascii", errors="replace")

    def test_no_dss_exe_header(self) -> None:
        # The whole point of resident_crt0.asm: no EXE magic anywhere near
        # the front of the image (the stock crt0 puts it in the first 3
        # bytes; this asserts the first 16 to catch a shifted-but-present
        # header too).
        self.assertNotIn(DSS_EXE_MAGIC, self.data[:16])

    def test_first_instruction_is_call_crt0_init(self) -> None:
        # start: call crt0_init -- 0xCD (CALL nn) followed by crt0_init's
        # address, little-endian.
        self.assertEqual(self.data[0], 0xCD, "expected CALL as the first opcode")
        crt0_init_addr = _map_symbol(self.map_text, "crt0_init")
        called = int.from_bytes(self.data[1:3], "little")
        self.assertEqual(called, crt0_init_addr)

    def test_start_at_configured_org(self) -> None:
        self.assertEqual(_map_symbol(self.map_text, "start"), PROBE_ORG)

    def test_main_linked(self) -> None:
        # _main must resolve to somewhere inside the image, after start.
        main_addr = _map_symbol(self.map_text, "_main")
        self.assertGreater(main_addr, PROBE_ORG)
        self.assertLess(main_addr, PROBE_ORG + len(self.data))

    def test_external_primitive_resolved_and_called(self) -> None:
        # crt0_probe_defs.asm pins _crt0_probe_primitive to a fixed address
        # the same way tools/gen_sprinter_platform_defs.py will for real
        # platform_core primitives; crt0_probe_main.c's one CALL to it must
        # appear literally in the linked image.
        self.assertEqual(
            _map_symbol(self.map_text, "_crt0_probe_primitive"),
            PROBE_PRIMITIVE_ADDR,
        )
        call_bytes = bytes([0xCD]) + PROBE_PRIMITIVE_ADDR.to_bytes(2, "little")
        self.assertIn(call_bytes, self.data)

    def test_image_is_flat_raw_binary(self) -> None:
        # No leading offset/length table: byte 0 of the file is the byte at
        # PROBE_ORG (matches every other --raw/-b artifact this port
        # produces, e.g. resident_s1.bin).
        self.assertGreater(len(self.data), 0)
        self.assertLess(len(self.data), 0x400)  # this fixture is tiny


if __name__ == "__main__":
    unittest.main()
