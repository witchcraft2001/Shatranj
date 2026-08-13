#!/usr/bin/env python3
"""Build the Sprinter WIN3 overlay page: RULES + BOARD + (S6) SAVELOAD +
RESTORE + FILEUI (plan D7-bis, S6 plan step 2).

S5 substep 2's overlay mechanism (plan D2) copies a 2 KiB blob from the
assets page into a fixed slot. That ceiling does not survive contact with a
compiled C overlay of real size: BOARD (src/spectrum/overlay/board_apply_ovl.c
plus its entry table and helpers) links to 2772 bytes, and the assets page
has exactly one 2 KiB overlay slot free anyway, already spoken for by
CONTROL (tools/make_sprinter_assets_page.py's own header).

So these overlays are not copied at all. Each is linked at its own ORG
inside the WIN3 window and mapped there with a single OUT
(asm/sprinter/zcc/overlay_loader_sprinter.asm's mode-1 dispatch). This tool
packs that page image: one 16384-byte WIN0-manifest asset page whose bytes,
once mapped into WIN3, appear at #C000-#FFFF.

Layout (S6 plan step 2): a declarative table of (name, id, budget) replaces
the original uniform 4x4 KiB slot scheme -- SAVELOAD/RESTORE/FILEUI, all
compiled C overlays with real content, do not share BOARD's size, and a
uniform slot would either waste most of a 4 KiB slot on a 1240-byte
SAVELOAD or fail to hold a 5+ KiB FILEUI (the sccz80 codegen factor pushes
compiled sizes well above the ZX/SDCC figures -- see this file's own
LAYOUT comment). Budgets are generous (25-100%+ headroom over the ZX/SDCC
size each overlay's own C source measures at) precisely because that
factor is not known exactly ahead of a real compile; an overlay that still
does not fit is a hard build error, not a silent truncation.

Slot layout (asm/sprinter/zcc/overlay_atlas_table_sprinter.asm's
OVL_WIN3_*_ORG constants and the Makefile's -r link addresses must match --
tests/tools/test_sprinter_overlay_page.py's test_atlas_table_agrees_with_
this_packing pins the two together):
    #C000  RULES     (SPECTRUM_OVL_RULES=0u)      2048 bytes
    #C800  BOARD     (SPECTRUM_OVL_BOARD=1u)       3072 bytes
    #D400  SAVELOAD  (SPECTRUM_OVL_SAVELOAD=10u)   2560 bytes
    #DE00  RESTORE   (SPECTRUM_OVL_RESTORE=11u)    3072 bytes
    #EA00  FILEUI    (SPECTRUM_OVL_FILEUI=13u)     5120 bytes
    #FE00  reserved                                 512 bytes

Published to HDR as the fourth asset page (HDR_ASSET_PAGE0_OFFSET+3);
asm/sprinter/buffers.asm's bench_init reads it into ovl_win3_page with the
same "#FF when unavailable" convention piece_page1/piece_page2 use.

The output is a pure function of the inputs (no timestamps), same contract
as tools/make_sprinter_assets_page.py.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

PAGE_SIZE = 16384

WIN3_BASE = 0xC000

# (name, budget). Order fixes the layout (cumulative offsets); id is not
# tracked here (the atlas table owns overlay ids) -- this tool only knows
# names and byte budgets. Sum of budgets must equal PAGE_SIZE exactly: no
# slack is silently absorbed, any change to one budget must adjust the
# reserve (or another budget) to match.
LAYOUT = [
    ("RULES", 2048),
    ("BOARD", 3072),
    ("SAVELOAD", 2560),
    ("RESTORE", 3072),
    ("FILEUI", 5120),
    ("RESERVE", 512),
]

_TOTAL = sum(budget for _, budget in LAYOUT)
if _TOTAL != PAGE_SIZE:
    raise SystemExit(
        f"Error: LAYOUT budgets sum to {_TOTAL}, must equal PAGE_SIZE {PAGE_SIZE}"
    )


def _compute_offsets() -> dict[str, int]:
    offsets: dict[str, int] = {}
    offset = 0
    for name, budget in LAYOUT:
        offsets[name] = offset
        offset += budget
    return offsets


_OFFSETS = _compute_offsets()
_BUDGETS = dict(LAYOUT)

# Overlay names this tool actually places bytes for (RESERVE never does).
OVERLAY_NAMES = [name for name, _ in LAYOUT if name != "RESERVE"]


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def slot_org(name: str) -> int:
    """Link address (-r) the named overlay must be built at."""
    if name not in _OFFSETS:
        fail(f"unknown overlay name {name!r} (known: {', '.join(_OFFSETS)})")
    return WIN3_BASE + _OFFSETS[name]


def slot_budget(name: str) -> int:
    if name not in _BUDGETS:
        fail(f"unknown overlay name {name!r} (known: {', '.join(_BUDGETS)})")
    return _BUDGETS[name]


def build_overlay_page(**overlays: bytes | None) -> bytes:
    """overlays: lowercase-name keyword args (rules=..., board=...,
    saveload=..., restore=..., fileui=...), any subset, None/omitted left
    zero."""
    page = bytearray(PAGE_SIZE)
    for key, data in overlays.items():
        if data is None:
            continue
        name = key.upper()
        if name not in OVERLAY_NAMES:
            fail(f"unknown overlay keyword {key!r} (known: "
                 f"{', '.join(n.lower() for n in OVERLAY_NAMES)})")
        budget = _BUDGETS[name]
        if len(data) > budget:
            fail(f"{name} is {len(data)} bytes, exceeds the {budget}-byte "
                 f"WIN3 overlay slot (base {slot_org(name):#06x})")
        offset = _OFFSETS[name]
        page[offset:offset + len(data)] = data
    data = bytes(page)
    assert len(data) == PAGE_SIZE
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in OVERLAY_NAMES:
        parser.add_argument(f"--{name.lower()}-bin", type=Path,
                            help=f"{name} overlay .bin; omit to leave its "
                                 "slot zero")
    parser.add_argument("--print-org", metavar="NAME",
                        help="print the -r link address for NAME and exit "
                             "(the Makefile's link rules read it from here "
                             "instead of hardcoding a WIN3 address)")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    if args.print_org is not None:
        print(f"0x{slot_org(args.print_org.upper()):04X}")
        return 0

    if args.output is None:
        fail("--output is required unless --print-org is given")

    overlays: dict[str, bytes | None] = {}
    for name in OVERLAY_NAMES:
        bin_path = getattr(args, f"{name.lower()}_bin")
        if bin_path is None:
            overlays[name.lower()] = None
            continue
        if not bin_path.is_file():
            fail(f"missing {name.lower()}-bin: {bin_path}")
        overlays[name.lower()] = bin_path.read_bytes()

    page = build_overlay_page(**overlays)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(page)
    digest = hashlib.sha256(page).hexdigest()
    print(f"[OK] {args.output}: {len(page)} bytes, sha256 {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
