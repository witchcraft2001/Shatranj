#!/usr/bin/env python3
"""Build the Sprinter WIN3 overlay page(s): RULES + BOARD + (S6) SAVELOAD +
RESTORE + FILEUI on page 1 (plan D7-bis, S6 plan step 2), NET on page 2
(S8 step 8b).

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

Layout (S6 plan step 2): a declarative table of (name, budget) replaces the
original uniform 4x4 KiB slot scheme -- SAVELOAD/RESTORE/FILEUI, all
compiled C overlays with real content, do not share BOARD's size, and a
uniform slot would either waste most of a 4 KiB slot on a 1240-byte
SAVELOAD or fail to hold a 5+ KiB FILEUI (the sccz80 codegen factor pushes
compiled sizes well above the ZX/SDCC figures). Budgets are generous
(25-100%+ headroom over the ZX/SDCC size each overlay's own C source
measures at) precisely because that factor is not known exactly ahead of a
real compile; an overlay that still does not fit is a hard build error, not
a silent truncation.

S8 step 8b adds a SECOND 16384-byte page carrying the NET overlay
(SPECTRUM_OVL_NET_CONNECT=3u) -- the existing page 1's own 3929 bytes of
slack are fragmented across five slots (measured, 2026-08-14 recon: RULES
420/BOARD 300/SAVELOAD 667/RESTORE 242/FILEUI 1788/RESERVE 512), and
carving NET's ~2816 bytes out of it would zero every remaining margin AND
S9's own headroom (SETUP/ABOUT/MENU_CONFIG are large UI overlays that would
hit the same wall immediately). A second WIN3 page costs nothing extra to
map -- asm/sprinter/buffers.asm's ovl_win3_page2 cell and
overlay_atlas_table_sprinter.asm's per-id page table (not a single global)
are what make this possible; see that table's own header.

S9 chat pass adds INPUT_EDIT (SPECTRUM_OVL_INPUT_EDIT=9u) into page 2's own
RESERVE2 slot -- the only unfragmented room left anywhere on either page
(page 1's own margin is spoken for by S9's other UI overlays; see this
file's own LAYOUT comment). RESERVE2 was 8192 bytes, entirely free; half of
it (4096) is generous for a compiled C overlay this size (the editor plus
the chat log's word-wrap, no per-cell cursor rendering -- see chat_
sprinter.c's own header), leaving a second RESERVE2 half still free for
whatever S9 UI work needs page 2 room next.

S9's NETWORK SETUP pass (editable DIRECT host/port, 2026-08-18) spends that
second half: NET grows from 8192 to 10240 bytes to hold the new editable
HOST/PORT rows and their validators, absorbing the whole RESERVE2 slot --
NET is the only overlay on this page still growing (6350 bytes in S8 ->
8096 in S9), while INPUT_EDIT (1421 bytes free) and ABOUT (1605 bytes free)
both still have their own headroom. There is no reserve left on page 2
after this; the next overlay that needs page 2 room must either fit inside
an existing slot's margin or grow the page layout again.

Both pages map into the SAME #C000-#FFFF hardware window (WIN3), just via a
different physical bank OUT -- so page 2's own slot orgs restart at #C000
exactly like page 1's, they are never both mapped at once.

Slot layout, page 1 (asm/sprinter/zcc/overlay_atlas_table_sprinter.asm's
OVL_WIN3_*_ORG constants and the Makefile's -r link addresses must match --
tests/tools/test_sprinter_overlay_page.py's test_atlas_table_agrees_with_
this_packing pins the two together):
    #C000  RULES     (SPECTRUM_OVL_RULES=0u)      2048 bytes
    #C800  BOARD     (SPECTRUM_OVL_BOARD=1u)       3072 bytes
    #D400  SAVELOAD  (SPECTRUM_OVL_SAVELOAD=10u)   2560 bytes
    #DE00  RESTORE   (SPECTRUM_OVL_RESTORE=11u)    3072 bytes
    #EA00  FILEUI    (SPECTRUM_OVL_FILEUI=13u)     5120 bytes
    #FE00  reserved                                 512 bytes

Slot layout, page 2:
    #C000  NET         (SPECTRUM_OVL_NET_CONNECT=3u)  10240 bytes
    #E800  INPUT_EDIT  (SPECTRUM_OVL_INPUT_EDIT=9u)   4096 bytes
    #F800  ABOUT       (SPECTRUM_OVL_ABOUT=12u)       2048 bytes

S9 About pass takes the first half of what was left of RESERVE2. ABOUT is
small for what it draws because it draws almost nothing itself: the picture
is blitted by the RESIDENT gfx_draw_tile, 16 rows per call, and the only
things that live in this slot are the loop that walks the four image pages,
the 48-byte palette the screen swaps in, and the caption text. It had to go
on a WIN3 page rather than into the resident or the cold page because both
of those were already full when it was written (WIN1 8 bytes free, WIN2 40,
cold page 0).

Page 1 is published to HDR as the fourth asset page
(HDR_ASSET_PAGE0_OFFSET+3); page 2 as the sixth
(HDR_ASSET_PAGE0_OFFSET+5), appended LAST so page 1's own index and the
piece-page indices ahead of it never shift. asm/sprinter/buffers.asm's
bench_init reads them into ovl_win3_page/ovl_win3_page2 with the same
"#FF when unavailable" convention piece_page1/piece_page2 use.

The output is a pure function of the inputs (no timestamps), same contract
as tools/make_sprinter_assets_page.py.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

PAGE_SIZE = 16384

WIN3_BASE = 0xC000

# (name, budget). Order fixes the layout (cumulative offsets within its own
# page); each page's budgets must sum to PAGE_SIZE exactly: no slack is
# silently absorbed, any change to one budget must adjust the reserve (or
# another budget) to match.
LAYOUT = [
    ("RULES", 2048),
    ("BOARD", 3072),
    ("SAVELOAD", 2560),
    ("RESTORE", 3072),
    ("FILEUI", 5120),
    ("RESERVE", 512),
]

LAYOUT2 = [
    ("NET", 10240),
    ("INPUT_EDIT", 4096),
    ("ABOUT", 2048),
]

# Page number -> that page's LAYOUT. Order of this dict is not significant;
# each page is packed independently.
PAGES = {1: LAYOUT, 2: LAYOUT2}

for _page_num, _layout in PAGES.items():
    _total = sum(budget for _, budget in _layout)
    if _total != PAGE_SIZE:
        raise SystemExit(
            f"Error: page {_page_num} LAYOUT budgets sum to {_total}, "
            f"must equal PAGE_SIZE {PAGE_SIZE}"
        )


def _compute_offsets(layout: list[tuple[str, int]]) -> dict[str, int]:
    offsets: dict[str, int] = {}
    offset = 0
    for name, budget in layout:
        offsets[name] = offset
        offset += budget
    return offsets


_OFFSETS = {page: _compute_offsets(layout) for page, layout in PAGES.items()}
_BUDGETS = {page: dict(layout) for page, layout in PAGES.items()}
# Every slot name (across all pages) -> the page it lives on. Names are
# unique across pages by construction (RESERVE vs RESERVE2 etc.), so one
# flat lookup is enough for slot_org()/slot_budget() to stay page-agnostic
# from the caller's point of view.
_PAGE_OF_NAME = {name: page for page, layout in PAGES.items() for name, _ in layout}

# Overlay names this tool actually places bytes for (RESERVE*never does),
# one list per page -- kept separate (not unioned) because build_overlay_page()
# packs exactly one 16384-byte page per call and the two pages' budgets
# would overflow a single page if combined.
OVERLAY_NAMES = [name for name, _ in LAYOUT if name != "RESERVE"]
OVERLAY_NAMES2 = [name for name, _ in LAYOUT2]


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def slot_org(name: str) -> int:
    """Link address (-r) the named overlay must be built at. Works across
    both pages -- each page's own slots restart at WIN3_BASE, since only
    one page is ever mapped into the WIN3 window at a time."""
    if name not in _PAGE_OF_NAME:
        fail(f"unknown overlay name {name!r} (known: {', '.join(_PAGE_OF_NAME)})")
    page = _PAGE_OF_NAME[name]
    return WIN3_BASE + _OFFSETS[page][name]


def slot_budget(name: str) -> int:
    if name not in _PAGE_OF_NAME:
        fail(f"unknown overlay name {name!r} (known: {', '.join(_PAGE_OF_NAME)})")
    page = _PAGE_OF_NAME[name]
    return _BUDGETS[page][name]


def build_overlay_page(page: int = 1, **overlays: bytes | None) -> bytes:
    """overlays: lowercase-name keyword args for the given page (page 1:
    rules=..., board=..., saveload=..., restore=..., fileui=...; page 2:
    net=...), any subset, None/omitted left zero. Defaults to page 1 so
    existing callers (and tests) that never pass page= keep building the
    first page, unchanged."""
    if page not in PAGES:
        fail(f"unknown page {page!r} (known: {', '.join(str(p) for p in PAGES)})")
    names_this_page = OVERLAY_NAMES if page == 1 else OVERLAY_NAMES2
    budgets = _BUDGETS[page]
    offsets = _OFFSETS[page]
    out = bytearray(PAGE_SIZE)
    for key, data in overlays.items():
        if data is None:
            continue
        name = key.upper()
        if name not in names_this_page:
            fail(f"unknown overlay keyword {key!r} for page {page} (known: "
                 f"{', '.join(n.lower() for n in names_this_page)})")
        budget = budgets[name]
        if len(data) > budget:
            fail(f"{name} is {len(data)} bytes, exceeds the {budget}-byte "
                 f"WIN3 overlay slot (base {slot_org(name):#06x})")
        offset = offsets[name]
        out[offset:offset + len(data)] = data
    data = bytes(out)
    assert len(data) == PAGE_SIZE
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in OVERLAY_NAMES + OVERLAY_NAMES2:
        parser.add_argument(f"--{name.lower()}-bin", type=Path,
                            help=f"{name} overlay .bin; omit to leave its "
                                 "slot zero")
    parser.add_argument("--page", type=int, choices=sorted(PAGES), default=1,
                        help="which WIN3 overlay page to build (default 1)")
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

    names_this_page = OVERLAY_NAMES if args.page == 1 else OVERLAY_NAMES2
    overlays: dict[str, bytes | None] = {}
    for name in names_this_page:
        bin_path = getattr(args, f"{name.lower()}_bin")
        if bin_path is None:
            overlays[name.lower()] = None
            continue
        if not bin_path.is_file():
            fail(f"missing {name.lower()}-bin: {bin_path}")
        overlays[name.lower()] = bin_path.read_bytes()

    page = build_overlay_page(page=args.page, **overlays)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(page)
    digest = hashlib.sha256(page).hexdigest()
    print(f"[OK] {args.output}: {len(page)} bytes, sha256 {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
