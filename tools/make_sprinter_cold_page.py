#!/usr/bin/env python3
"""Pack the Sprinter WIN3 cold-code image into a 16 KiB asset page.

S7 step 4 (byte-budget ladder). asm/sprinter/zcc/render_core.asm and
render_core_cold.asm -- every board/HUD/FILEUI painter this port has -- no
longer fit the 16000-byte WIN1 resident C image alongside the S7 session
layer, and the WIN2 gap before OVL_SLOT is both small (~3.4 KiB) and
already spoken for by net_frame.c. They are linked instead at #C000 with
their own crt0 (asm/sprinter/zcc/cold_page_crt0.asm) and shipped as a whole
asset page, mapped into WIN3 with a single OUT by the thunks
tools/gen_sprinter_cold_thunks.py generates -- the same no-copy mechanism
plan D7-bis already uses for the RULES/BOARD/SAVELOAD/RESTORE/FILEUI
overlays (asm/sprinter/zcc/overlay_loader_sprinter.asm's mode 1).

Unlike tools/make_sprinter_overlay_page.py this page has no slot table:
one linked image owns the whole page, so packing is just "check it fits,
zero-pad to the page size". It is published to HDR as the FIFTH asset page
(HDR_ASSET_PAGE0_OFFSET+4) and read into asm/sprinter/buffers.asm's
cold_win3_page with the same "#FF when unavailable" convention
ovl_win3_page/piece_page1/piece_page2 use.

The output is a pure function of the input (no timestamps), same contract
as tools/make_sprinter_assets_page.py and make_sprinter_overlay_page.py.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

PAGE_SIZE = 16384

# Must match asm/sprinter/zcc/cold_page_crt0.asm's CRT_ORG_CODE default and
# the Makefile's -pragma-define. Reported in the size line below so a build
# log shows where the image actually lives, not just how big it is.
COLD_PAGE_ORG = 0xC000


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def build_cold_page(image: bytes) -> bytes:
    """Zero-pad the linked cold image to exactly one page."""
    if len(image) > PAGE_SIZE:
        fail(
            f"cold-code image is {len(image)} bytes, exceeds the "
            f"{PAGE_SIZE}-byte WIN3 page (linked at {COLD_PAGE_ORG:#06x}); "
            "move a routine back to the resident or split a second page "
            "(buffers.asm would need to publish it, see cold_win3_page)"
        )
    page = bytearray(PAGE_SIZE)
    page[0:len(image)] = image
    data = bytes(page)
    assert len(data) == PAGE_SIZE
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path,
                        help="linked cold-code .bin (ORG "
                             f"{COLD_PAGE_ORG:#06x})")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if args.image is None or args.output is None:
        fail("--image and --output are required unless --self-test is given")
    if not args.image.is_file():
        fail(f"missing --image: {args.image}")

    image = args.image.read_bytes()
    page = build_cold_page(image)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(page)
    digest = hashlib.sha256(page).hexdigest()
    free = PAGE_SIZE - len(image)
    print(f"[OK] {args.output}: {len(image)} bytes at {COLD_PAGE_ORG:#06x} "
          f"({free} free of {PAGE_SIZE}), sha256 {digest}")
    return 0


def self_test() -> None:
    page = build_cold_page(b"\x01\x02\x03")
    if len(page) != PAGE_SIZE:
        raise SystemExit("[ERR] cold-page self-test: wrong page size")
    if page[:3] != b"\x01\x02\x03" or any(page[3:]):
        raise SystemExit("[ERR] cold-page self-test: image not zero-padded")
    if build_cold_page(b"\x01\x02\x03") != page:
        raise SystemExit("[ERR] cold-page self-test: packing is not deterministic")

    full = build_cold_page(bytes(PAGE_SIZE))
    if len(full) != PAGE_SIZE:
        raise SystemExit("[ERR] cold-page self-test: exact-fit image rejected")

    try:
        build_cold_page(bytes(PAGE_SIZE + 1))
    except SystemExit as exc:
        if "exceeds" not in str(exc):
            raise SystemExit("[ERR] cold-page self-test: wrong overflow diagnostic")
    else:
        raise SystemExit("[ERR] cold-page self-test: oversize image was not rejected")

    print("[OK] Sprinter cold-page self-test")


if __name__ == "__main__":
    raise SystemExit(main())
