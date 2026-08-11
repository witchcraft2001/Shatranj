#!/usr/bin/env python3
"""Splice the Sprinter resident from three independently-assembled blobs.

Plan D1 (port.md section 3.10/S5): trampoline.asm (sjasmplus) and
platform_primitives.asm (sjasmplus) are each their own --raw job, and the
resident C image (asm/sprinter/zcc/resident_crt0.asm + src/sprinter C, z88dk)
is a third, independent build. None of the three can see the others'
addresses at assembly time -- they only agree on the fixed anchors in
src/sprinter/fixed_layout.json (TRAMPOLINE_ADDR, C_IMAGE_ENTRY_ADDR,
WIN2_BASE/WIN2_END). This tool is where that agreement is actually checked
and the three blobs become the one flat 32 KiB image
tools/make_sprinter_exe.py expects: zero-filled outside the three blobs
(HDR is the loader's to write, per the existing resident-image contract),
each blob placed at its anchor, and a hard failure -- not silent truncation
or overlap -- if any blob doesn't fit before the next anchor.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_sprinter_layout as gsl


class SpliceError(Exception):
    pass


def splice(layout: dict, trampoline: bytes, resident_c: bytes,
           platform_primitives: bytes) -> bytes:
    resident_base = layout["resident_base"]
    win2_base = layout["win2_base"]
    win2_end = layout["win2_end"]
    trampoline_addr = gsl._region(layout, "TRAMPOLINE")["addr"]
    c_entry_addr = gsl._region(layout, "C_IMAGE_ENTRY")["addr"]
    win1_end = layout["win1_end"]

    total = win2_end - resident_base
    image = bytearray(total)

    def place(name: str, data: bytes, addr: int, ceiling: int) -> None:
        end = addr + len(data)
        if end > ceiling:
            raise SpliceError(
                f"{name} ({len(data)} bytes at #{addr:04X}) overruns "
                f"#{ceiling:04X} by {end - ceiling} bytes"
            )
        offset = addr - resident_base
        existing = image[offset:offset + len(data)]
        if any(existing):
            raise SpliceError(
                f"{name} at #{addr:04X} overlaps bytes already placed by "
                "an earlier blob"
            )
        image[offset:offset + len(data)] = data

    place("trampoline.bin", trampoline, trampoline_addr, c_entry_addr)
    place("resident_c.bin (C image)", resident_c, c_entry_addr, win1_end)
    place("platform_primitives.bin", platform_primitives, win2_base, win2_end)

    if len(platform_primitives) != win2_end - win2_base:
        raise SpliceError(
            f"platform_primitives.bin is {len(platform_primitives)} bytes, "
            f"expected exactly {win2_end - win2_base} (WIN2_BASE..WIN2_END, "
            "no gaps -- platform_primitives.asm's own DS-fill+ASSERT chain "
            "should already guarantee this; a mismatch here means that "
            "chain and this tool's idea of the layout have drifted apart"
        )

    return bytes(image)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layout", type=Path,
                        default=Path("src/sprinter/fixed_layout.json"))
    parser.add_argument("--trampoline", type=Path, required=True)
    parser.add_argument("--resident-c", type=Path, required=True)
    parser.add_argument("--platform-primitives", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    layout = gsl.load_layout_file(args.layout)
    errors = gsl.validate_layout(layout)
    if errors:
        print(f"[ERR] {args.layout}: fixed-layout invariants violated", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1

    try:
        image = splice(
            layout,
            args.trampoline.read_bytes(),
            args.resident_c.read_bytes(),
            args.platform_primitives.read_bytes(),
        )
    except SpliceError as exc:
        print(f"[ERR] make_sprinter_resident: {exc}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    print(f"[OK] {args.output} ({len(image)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
