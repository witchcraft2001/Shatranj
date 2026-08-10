#!/usr/bin/env python3
"""Pack the S4 UI assets (Sprinter logo, point markers) into a hardware-key
tile blob for the assets page's free slot 44-63 range.

Reads only committed PNGs (tools/prepare_sprinter_logo.py's
assets/sprinter/logo_sprinter.png and tools/make_sprinter_markers.py's
assets/sprinter/markers/{dot,ring}.png) -- part of the build, deterministic,
no headless Chrome. All three assets are drawn through the hardware
transparency key (VRAM_ALIAS_KEY, port.md section 3.3): row-major 4bpp,
high nibble = left pixel, a whole #FF byte is the hardware's transparency
skip -- never a single nibble (the same rule
tools/make_sprinter_assets_page.py's _key_tile bench fixture follows).

Slot layout is a FIXED contract, matching every other asset page slot
assignment in this codebase (make_sprinter_assets_page.py's TILE_A_SLOT
etc., bench_s2.asm's matching EQUs "shared by hand, no generated bridge"):
asm/sprinter/scene_s4.asm hardcodes these same slot numbers as compile-time
EQUs, so they must not shift silently just because an artist resized the
logo PNG. A logo that grows past its reserved budget fails the build
loudly instead of overlapping the markers.

    44..49   Sprinter logo (tools/prepare_sprinter_logo.py), <=6 slots
    50       marker "dot" (16x8)
    51       marker "ring" (16x8)
    52..63   unused (zero)

Output is a single UI_ASSETS_SIZE-byte blob (slots 44-63, 5120 bytes) meant
for tools/make_sprinter_assets_page.py's --ui-bin.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import gen_sprinter_palette as gsp  # noqa: E402

SLOT_SIZE = 256
UI_ASSETS_BASE_SLOT = 44
UI_ASSETS_SLOT_COUNT = 20   # slots 44..63
UI_ASSETS_SIZE = UI_ASSETS_SLOT_COUNT * SLOT_SIZE

# Fixed slot contract -- asm/sprinter/scene_s4.asm hardcodes these same
# numbers (see the module docstring).
LOGO_SLOT = 44
LOGO_MAX_SLOTS = 6
# port.md section 3.4's banner band is y 0..15: the logo is blitted at y=0
# and a taller asset would run into the menu-tab row. The slot budget alone
# does not catch that -- a 160x18 logo fits in 6 slots and still overflows
# the band -- so height is pinned separately.
LOGO_MAX_H = 16
DOT_SLOT = 50
DOT_SLOTS = 1
RING_SLOT = 51
RING_SLOTS = 1

MARKER_W, MARKER_H = 16, 8
KEY_BYTE = 0xFF

DEFAULT_PALETTE = ROOT / "assets/sprinter/palette.json"
DEFAULT_LOGO = ROOT / "assets/sprinter/logo_sprinter.png"
DEFAULT_DOT = ROOT / "assets/sprinter/markers/dot.png"
DEFAULT_RING = ROOT / "assets/sprinter/markers/ring.png"

MANIFEST_FORMAT = "shatranj-sprinter-ui-assets-v1"

# Opaque pixels in keyed assets may only use indices 0-14: encoding index
# 15 there would mean "transparent" to the hardware regardless of what RGB
# happens to be loaded into palette register 15 (assets/sprinter/
# palette.json's format note; port.md section 3.5 amended at S4 close).
KEYED_OPAQUE_INDICES = list(range(15))


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def _ref_rgb_to_index(palette: dict) -> dict[tuple[int, int, int], int]:
    by_index = {e["index"]: e["rgb"] for e in palette["base"]}
    return {
        gsp._parse_rgb(by_index[i], "palette"): i
        for i in KEYED_OPAQUE_INDICES
    }


def pack_keyed_asset(path: Path, ref_rgb_to_index: dict,
                      expect_w: int | None = None,
                      expect_h: int | None = None,
                      max_h: int | None = None) -> tuple[bytes, int, int]:
    """Row-major 4bpp pack with the hardware key: validates alpha in
    {0,255}, PAIR-UNIFORM alpha per byte (both pixels of a 2px block
    transparent or both opaque -- a mixed pair cannot be represented, the
    hardware skips whole bytes), and every opaque pixel matching one of
    the allowed reference indices. Returns (packed_bytes, width, height)."""
    if not path.is_file():
        fail(f"missing asset PNG: {path}")
    image = Image.open(path).convert("RGBA")
    w, h = image.size
    if expect_w is not None and w != expect_w:
        fail(f"{path}: width {w}, expected {expect_w}")
    if expect_h is not None and h != expect_h:
        fail(f"{path}: height {h}, expected {expect_h}")
    if max_h is not None and h > max_h:
        fail(f"{path}: height {h} exceeds its band's {max_h} rows")
    if w % 2 != 0:
        fail(f"{path}: width {w} is odd (4bpp packs 2 pixels/byte)")

    px = image.load()
    stride = w // 2
    rows = bytearray()
    for y in range(h):
        row = bytearray(stride)
        for bx in range(stride):
            x0, x1 = 2 * bx, 2 * bx + 1
            r0, g0, b0, a0 = px[x0, y]
            r1, g1, b1, a1 = px[x1, y]
            if a0 not in (0, 255) or a1 not in (0, 255):
                fail(f"{path}: pixel pair ({x0},{y})/({x1},{y}) has "
                     "non-binary alpha (no anti-aliasing allowed)")
            if (a0 == 255) != (a1 == 255):
                fail(f"{path}: pixel pair ({x0},{y})/({x1},{y}) has "
                     "mismatched transparency -- the hardware key skips "
                     "whole bytes, not single pixels; transparency must "
                     "be aligned to even pixel pairs")
            if a0 == 0:
                row[bx] = KEY_BYTE
                continue
            if (r0, g0, b0) not in ref_rgb_to_index:
                fail(f"{path}: pixel ({x0},{y}) RGB #{r0:02X}{g0:02X}{b0:02X} "
                     "is not one of the allowed palette colours (indices "
                     f"0-14; {sorted(ref_rgb_to_index)})")
            if (r1, g1, b1) not in ref_rgb_to_index:
                fail(f"{path}: pixel ({x1},{y}) RGB #{r1:02X}{g1:02X}{b1:02X} "
                     "is not one of the allowed palette colours (indices "
                     f"0-14; {sorted(ref_rgb_to_index)})")
            idx0 = ref_rgb_to_index[(r0, g0, b0)]
            idx1 = ref_rgb_to_index[(r1, g1, b1)]
            row[bx] = (idx0 << 4) | idx1
        rows += row
    data = bytes(rows)
    assert len(data) == stride * h
    return data, w, h


def build_ui_assets(logo_path: Path, dot_path: Path, ring_path: Path,
                     palette: dict) -> tuple[bytes, dict]:
    ref = _ref_rgb_to_index(palette)
    blob = bytearray(UI_ASSETS_SIZE)  # unused tail stays zero, matching
                                       # every other "unused slot" region
                                       # in this codebase (font/theme/
                                       # overlay gaps) -- nothing ever
                                       # reads past the named entries.

    entries = []

    def place(name: str, path: Path, slot: int, max_slots: int,
              expect_w: int | None, expect_h: int | None,
              max_h: int | None = None) -> None:
        data, w, h = pack_keyed_asset(path, ref, expect_w, expect_h, max_h)
        slots = -(-len(data) // SLOT_SIZE)
        if slots > max_slots:
            fail(f"{name} needs {slots} slot(s), exceeds its fixed budget "
                 f"of {max_slots} slot(s) starting at slot {slot} -- shrink "
                 f"the asset or widen its reserved span in both "
                 "tools/build_sprinter_ui_assets.py and asm/sprinter/scene_s4.asm")
        offset = (slot - UI_ASSETS_BASE_SLOT) * SLOT_SIZE
        blob[offset:offset + len(data)] = data
        entries.append({
            "name": name, "slot": slot, "slots": slots, "width": w, "height": h,
        })

    place("logo_sprinter", logo_path, LOGO_SLOT, LOGO_MAX_SLOTS, None, None,
          max_h=LOGO_MAX_H)
    place("marker_dot", dot_path, DOT_SLOT, DOT_SLOTS, MARKER_W, MARKER_H)
    place("marker_ring", ring_path, RING_SLOT, RING_SLOTS, MARKER_W, MARKER_H)

    manifest = {
        "format": MANIFEST_FORMAT,
        "base_slot": UI_ASSETS_BASE_SLOT,
        "slot_count": UI_ASSETS_SLOT_COUNT,
        "entries": entries,
        "sha256": {
            "palette_json": None,  # filled by caller (needs the path)
            "logo": hashlib.sha256(logo_path.read_bytes()).hexdigest(),
            "marker_dot": hashlib.sha256(dot_path.read_bytes()).hexdigest(),
            "marker_ring": hashlib.sha256(ring_path.read_bytes()).hexdigest(),
        },
    }
    return bytes(blob), manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--logo", type=Path, default=DEFAULT_LOGO)
    parser.add_argument("--marker-dot", type=Path, default=DEFAULT_DOT)
    parser.add_argument("--marker-ring", type=Path, default=DEFAULT_RING)
    parser.add_argument("--palette", type=Path, default=DEFAULT_PALETTE)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest-out", type=Path, default=None)
    args = parser.parse_args()

    palette = gsp.load_palette_file(args.palette)
    errors = gsp.validate_palette(palette)
    if errors:
        fail(f"{args.palette} is invalid: " + "; ".join(errors))

    blob, manifest = build_ui_assets(args.logo, args.marker_dot, args.marker_ring, palette)
    manifest["sha256"]["palette_json"] = hashlib.sha256(args.palette.read_bytes()).hexdigest()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(blob)
    print(f"[OK] {args.output}: {len(blob)} bytes, "
          f"sha256 {hashlib.sha256(blob).hexdigest()}")

    if args.manifest_out is not None:
        args.manifest_out.parent.mkdir(parents=True, exist_ok=True)
        args.manifest_out.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="ascii"
        )
        print(f"[OK] {args.manifest_out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
