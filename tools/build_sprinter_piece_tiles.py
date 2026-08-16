#!/usr/bin/env python3
"""Pack the committed Sprinter piece PNGs into precomposed 4bpp tile pages.

port.md section 4 step B and section 3.6: reads ONLY the PNGs
tools/rasterize_sprinter_pieces.py committed to assets/sprinter/pieces/ (no
SVG, no headless Chrome -- this tool is part of the build and must be
reproducible on any machine). Each of the 3 selected sets' 12 piece PNGs
gets precomposed onto both board-square colours (palette indices 2 and 3),
yielding 24 opaque 4bpp tiles per set -- the blit is then always opaque, no
hardware-key pair problem (port.md section 3.6). This is a purpose-built
fork of extern/sprinter-libs/gfx640/tools/tilepack.py's conventions (row-
major packed 4bpp, high nibble = left pixel), not that script itself: the
donor takes one already-indexed PNG per output page, this tool takes 12
already-separate RGBA piece PNGs per set and must precompose+pack them
itself, plus validate every opaque pixel against the shared
assets/sprinter/palette.json reference colours rather than an arbitrary
input palette.

Slot layout (asm/sprinter's tile-ref convention, slot*256 = byte offset
within a 16384-byte, 64-slot page -- see tools/make_sprinter_assets_page.py
for the sibling font/UI page):

    page 1 (HDR asset page index 1): slots 0-23  = sets[0] (e.g. california)
                                      slots 24-47 = sets[1] (e.g. mpchess)
    page 2 (HDR asset page index 2): slots 0-23  = sets[2] (e.g. totoy)
                                      slots 24-35 = sets[0] flash background
                                      slots 36-47 = sets[1] flash background
                                      slots 48-59 = sets[2] flash background

Within a set's 24-slot span: slot = set_base + piece_index*2 + background,
piece_index 0..11 in PIECE_ORDER (wK,wQ,wR,wB,wN,wP,bK,bQ,bR,bB,bN,bP),
background 0 = light square (palette index 2), 1 = dark square (index 3).

The flash block (S9 move animation) is a THIRD background for the same 12
pieces -- palette index 8, hud_select -- but only one tile per piece, not a
light/dark pair: the flash colour replaces the square colour outright, so
which square the piece stands on stops mattering while it is up. It is
packed as its own block after the last set's normal block rather than
widening every set's span to 36, because 36-slot sets would need one page
per set and the resident publishes exactly two piece pages (buffers.asm's
bench_init). asm/sprinter/zcc/render_core.asm hand-copies set 0's page and
slot base into PIECE_FLASH_SLOT_BASE; tests/tools/test_sprinter_piece_
tiles.py parses that EQU back out of the .asm and fails if it drifts from
the manifest this tool writes.

Why a precomposed third variant at all, rather than one keyed (transparent)
piece tile drawn over a filled square: VRAM_ALIAS_KEY skips whole #FF
BYTES, i.e. transparency is 2-pixel granular, so any byte straddling a
piece edge would have to be opaque -- the same "hardware-key pair problem"
that made the light/dark pair the original design (port.md section 3.6).

The output is a pure function of the inputs (committed PNGs + palette.json;
no timestamps), so reruns are byte-identical.
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

PAGE_SIZE = 16384
SLOT_SIZE = 256

DEFAULT_PIECES_ROOT = ROOT / "assets/sprinter/pieces"
DEFAULT_SETS_JSON = ROOT / "assets/lichess/selected_next_sets.json"
DEFAULT_PALETTE = ROOT / "assets/sprinter/palette.json"

MANIFEST_FORMAT = "shatranj-sprinter-tiles-v1"
LAYOUT = "row-major-packed-4bpp-high-nibble-left"

SIDES = ["w", "b"]
KINDS = ["K", "Q", "R", "B", "N", "P"]
PIECE_ORDER = [f"{side}{kind}" for side in SIDES for kind in KINDS]  # 12 keys
BACKGROUND_ORDER = ["light", "dark"]  # -> palette indices 2, 3
BACKGROUND_INDICES = [2, 3]
PIECE_REF_INDICES = [4, 5, 6, 7]

# S9 move-flash: one extra tile per piece, precomposed on hud_select.
FLASH_BACKGROUND_INDEX = 8
SLOTS_PER_PAGE = PAGE_SIZE // SLOT_SIZE                   # 64
TILES_PER_SET = len(PIECE_ORDER) * len(BACKGROUND_ORDER)  # 24
FLASH_TILES_PER_SET = len(PIECE_ORDER)                    # 12
SETS_PER_PAGE = SLOTS_PER_PAGE // TILES_PER_SET           # 64 // 24 = 2


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def parse_cell(spec: str) -> tuple[int, int]:
    try:
        w_str, h_str = spec.lower().split("x")
        return int(w_str), int(h_str)
    except ValueError:
        fail(f"invalid --cell {spec!r}, want WxH (e.g. 32x16)")


def resolve_stride(cell_w: int, stride: int | None) -> int:
    """The packed row length, and the only value --stride may name.

    precompose_tile always writes cell_w//2 bytes per row (tightly packed
    4bpp, 2 pixels/byte). Accepting a different --stride would publish a
    geometry in the manifest that the packed bytes do not honour -- and the
    resident sizes its blits from that geometry -- so a mismatch is an
    error rather than a silently ignored flag."""
    if cell_w % 2 != 0:
        fail(f"--cell width {cell_w} is odd (4bpp packs 2 pixels/byte)")
    packed = cell_w // 2
    if stride is not None and stride != packed:
        fail(f"--stride {stride} does not match the packed row length {packed} "
             f"(cell width {cell_w} / 2)")
    return packed


def load_selected_sets(path: Path, override: list[str] | None) -> list[str]:
    if override:
        return override
    data = json.loads(path.read_text(encoding="utf-8"))
    return list(data.get("selected", []))


def _rgb_set(palette: dict, indices: list[int]) -> dict[tuple[int, int, int], int]:
    by_index = {e["index"]: e["rgb"] for e in palette["base"]}
    return {gsp._parse_rgb(by_index[i], "palette"): i for i in indices}


def load_and_validate_piece(path: Path, cell_w: int, cell_h: int,
                             ref_rgb_to_index: dict) -> Image.Image:
    if not path.is_file():
        fail(f"missing piece PNG: {path}")
    image = Image.open(path).convert("RGBA")
    if image.size != (cell_w, cell_h):
        fail(f"{path}: size {image.size}, expected {(cell_w, cell_h)}")
    px = image.load()
    for y in range(cell_h):
        for x in range(cell_w):
            r, g, b, a = px[x, y]
            if a not in (0, 255):
                fail(f"{path}: pixel ({x},{y}) alpha {a} is neither fully "
                     "opaque nor fully transparent (no anti-aliasing allowed)")
            if a == 255 and (r, g, b) not in ref_rgb_to_index:
                fail(f"{path}: pixel ({x},{y}) RGB #{r:02X}{g:02X}{b:02X} is "
                     "not one of the reference piece colours "
                     f"{sorted(ref_rgb_to_index)}")
    return image


def precompose_tile(piece: Image.Image, cell_w: int, cell_h: int,
                     bg_rgb_to_index: dict, bg_rgb: tuple[int, int, int],
                     ref_rgb_to_index: dict) -> bytes:
    """Row-major 4bpp raster: background index everywhere the piece PNG is
    transparent, the matching reference index everywhere it's opaque."""
    bg_index = bg_rgb_to_index[bg_rgb]
    px = piece.load()
    stride = cell_w // 2
    rows = bytearray()
    for y in range(cell_h):
        row = bytearray(stride)
        for bx in range(stride):
            nibbles = []
            for sub in (0, 1):
                x = bx * 2 + sub
                r, g, b, a = px[x, y]
                nibbles.append(ref_rgb_to_index[(r, g, b)] if a == 255 else bg_index)
            row[bx] = (nibbles[0] << 4) | nibbles[1]
        rows += row
    data = bytes(rows)
    assert len(data) == stride * cell_h
    return data


def build_pages(pieces_root: Path, sets: list[str], palette: dict,
                 cell_w: int, cell_h: int) -> tuple[list[bytes], dict]:
    if TILES_PER_SET * SLOT_SIZE > PAGE_SIZE:
        fail(f"{TILES_PER_SET} tiles/set do not fit in one {PAGE_SIZE}-byte page")

    piece_ref = _rgb_set(palette, PIECE_REF_INDICES)
    bg_ref = _rgb_set(palette, BACKGROUND_INDICES)
    bg_rgb_by_order = [
        next(rgb for rgb, idx in bg_ref.items() if idx == pi)
        for pi in BACKGROUND_INDICES
    ]
    flash_ref = _rgb_set(palette, [FLASH_BACKGROUND_INDEX])
    flash_rgb = next(iter(flash_ref))

    page_count = -(-len(sets) // SETS_PER_PAGE)
    pages = [bytearray(PAGE_SIZE) for _ in range(page_count)]
    manifest_sets = []
    input_shas: dict[str, str] = {}
    piece_images_by_set: dict[str, dict[str, Image.Image]] = {}

    for set_index, set_name in enumerate(sets):
        page_no = set_index // SETS_PER_PAGE          # 0-based page index
        slot_base = (set_index % SETS_PER_PAGE) * TILES_PER_SET
        page = pages[page_no]
        piece_images: dict[str, Image.Image] = {}
        for key in PIECE_ORDER:
            png_path = pieces_root / set_name / f"{key}.png"
            piece_images[key] = load_and_validate_piece(png_path, cell_w, cell_h, piece_ref)
            try:
                key_path = str(png_path.resolve().relative_to(ROOT))
            except ValueError:
                key_path = str(png_path)
            input_shas[key_path] = hashlib.sha256(png_path.read_bytes()).hexdigest()

        for p_index, key in enumerate(PIECE_ORDER):
            for bg_index, bg_rgb in enumerate(bg_rgb_by_order):
                slot = slot_base + p_index * 2 + bg_index
                tile = precompose_tile(
                    piece_images[key], cell_w, cell_h, bg_ref, bg_rgb, piece_ref
                )
                offset = slot * SLOT_SIZE
                if len(tile) > SLOT_SIZE:
                    fail(f"tile for {set_name}/{key} bg={bg_index} is "
                         f"{len(tile)} bytes, exceeds one slot ({SLOT_SIZE})")
                page[offset:offset + len(tile)] = tile
                if 0xFF in tile:
                    fail(f"tile for {set_name}/{key} bg={bg_index} contains "
                         "a 0xFF byte in opaque tile data (would be "
                         "misread as the hardware transparency key)")

        piece_images_by_set[set_name] = piece_images
        manifest_sets.append({
            "name": set_name,
            "asset_page_index": page_no + 1,  # 1-based: matches HDR order
            "slot_base": slot_base,
        })

    # Flash blocks, packed after the last set's normal block and continuing
    # across the same pages (see the module docstring's layout table). Kept
    # out of the per-set loop above on purpose: every normal block's slot
    # arithmetic stays exactly what it was before the flash tiles existed,
    # so page 1's bytes are unchanged by this addition.
    last_index = len(sets) - 1
    cursor_page = last_index // SETS_PER_PAGE
    cursor_slot = ((last_index % SETS_PER_PAGE) + 1) * TILES_PER_SET
    for set_index, set_name in enumerate(sets):
        if cursor_slot + FLASH_TILES_PER_SET > SLOTS_PER_PAGE:
            cursor_page += 1
            cursor_slot = 0
        if cursor_page >= page_count:
            fail(f"flash tiles for {set_name} do not fit: {len(sets)} sets need "
                 f"{page_count} page(s) for their normal blocks and there is no "
                 f"room left for a {FLASH_TILES_PER_SET}-slot flash block "
                 "(asm/sprinter/buffers.asm's bench_init publishes exactly two "
                 "piece pages -- adding a third is a resident change, not a "
                 "tool change)")
        page = pages[cursor_page]
        for p_index, key in enumerate(PIECE_ORDER):
            slot = cursor_slot + p_index
            tile = precompose_tile(
                piece_images_by_set[set_name][key], cell_w, cell_h,
                flash_ref, flash_rgb, piece_ref
            )
            offset = slot * SLOT_SIZE
            page[offset:offset + len(tile)] = tile
            if 0xFF in tile:
                fail(f"flash tile for {set_name}/{key} contains a 0xFF byte in "
                     "opaque tile data (would be misread as the hardware "
                     "transparency key)")
        manifest_sets[set_index]["flash_asset_page_index"] = cursor_page + 1
        manifest_sets[set_index]["flash_slot_base"] = cursor_slot
        cursor_slot += FLASH_TILES_PER_SET

    return [bytes(p) for p in pages], {
        "sets": manifest_sets,
        "input_shas": input_shas,
    }


def build_manifest(sets_info: dict, cell_w: int, cell_h: int, stride: int,
                    palette_path: Path) -> dict:
    return {
        "format": MANIFEST_FORMAT,
        "layout": LAYOUT,
        "cell": {"w": cell_w, "h": cell_h},
        "stride": stride,
        "tile_bytes": stride * cell_h,
        "tiles_per_set": TILES_PER_SET,
        "flash_tiles_per_set": FLASH_TILES_PER_SET,
        "flash_background_palette_index": FLASH_BACKGROUND_INDEX,
        "piece_order": PIECE_ORDER,
        "background_order": BACKGROUND_ORDER,
        "background_palette_indices": BACKGROUND_INDICES,
        "piece_reference_indices": PIECE_REF_INDICES,
        "sets": sets_info["sets"],
        "sha256": {
            "palette_json": hashlib.sha256(palette_path.read_bytes()).hexdigest(),
            "pieces": dict(sorted(sets_info["input_shas"].items())),
        },
    }


def aspect_corrected(image: Image.Image, scale: int = 6) -> Image.Image:
    w, h = image.size
    stage = image.resize((w * scale, h * scale), Image.Resampling.NEAREST)
    return stage.resize((w * scale, h * scale * 2), Image.Resampling.NEAREST)


def build_preview(pieces_root: Path, set_name: str, palette: dict,
                   cell_w: int, cell_h: int, out_path: Path) -> None:
    piece_ref = _rgb_set(palette, PIECE_REF_INDICES)
    # The flash background gets its own preview row, so the artist sees every
    # variant the build actually ships, not just the light/dark pair.
    bg_ref = _rgb_set(palette, BACKGROUND_INDICES + [FLASH_BACKGROUND_INDEX])
    bg_rgb_by_order = [
        next(rgb for rgb, idx in bg_ref.items() if idx == pi)
        for pi in BACKGROUND_INDICES + [FLASH_BACKGROUND_INDEX]
    ]
    cell_scaled = (cell_w * 6, cell_h * 6 * 2)
    pad = 4
    grid = Image.new(
        "RGB",
        (len(PIECE_ORDER) * (cell_scaled[0] + pad) + pad,
         len(bg_rgb_by_order) * (cell_scaled[1] + pad) + pad),
        (20, 20, 20),
    )
    for row, bg_rgb in enumerate(bg_rgb_by_order):
        for col, key in enumerate(PIECE_ORDER):
            piece = load_and_validate_piece(
                pieces_root / set_name / f"{key}.png", cell_w, cell_h, piece_ref
            )
            composed = Image.new("RGB", (cell_w, cell_h), bg_rgb)
            composed.paste(piece, (0, 0), piece)
            cell_img = aspect_corrected(composed)
            x = pad + col * (cell_scaled[0] + pad)
            y = pad + row * (cell_scaled[1] + pad)
            grid.paste(cell_img, (x, y))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    grid.save(out_path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pieces-root", type=Path, default=DEFAULT_PIECES_ROOT)
    parser.add_argument("--sets-json", type=Path, default=DEFAULT_SETS_JSON)
    parser.add_argument("--sets", nargs="+", default=None)
    parser.add_argument("--palette", type=Path, default=DEFAULT_PALETTE)
    parser.add_argument("--cell", default="32x16")
    parser.add_argument("--stride", type=int, default=None,
                        help="source bytes per tile row; must equal cell width/2 "
                             "(precompose_tile packs rows tightly -- the flag "
                             "exists to make the manifest's stride explicit, not "
                             "to select a padded layout)")
    parser.add_argument("--page1-out", type=Path, required=True)
    parser.add_argument("--page2-out", type=Path, required=True)
    parser.add_argument("--manifest-out", type=Path, required=True)
    parser.add_argument("--preview-dir", type=Path, default=None)
    args = parser.parse_args()

    cell_w, cell_h = parse_cell(args.cell)
    stride = resolve_stride(cell_w, args.stride)

    palette = gsp.load_palette_file(args.palette)
    errors = gsp.validate_palette(palette)
    if errors:
        fail(f"{args.palette} is invalid: " + "; ".join(errors))

    sets = load_selected_sets(args.sets_json, args.sets)
    if len(sets) != 3:
        fail(f"expected exactly 3 sets, got {len(sets)}: {sets}")

    pages, sets_info = build_pages(args.pieces_root, sets, palette, cell_w, cell_h)
    if len(pages) != 2:
        fail(f"expected exactly 2 output pages for 3 sets, got {len(pages)}")

    manifest = build_manifest(sets_info, cell_w, cell_h, stride, args.palette)

    for out_path, page in zip((args.page1_out, args.page2_out), pages):
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(page)
        print(f"[OK] {out_path}: {len(page)} bytes, "
              f"sha256 {hashlib.sha256(page).hexdigest()}")

    args.manifest_out.parent.mkdir(parents=True, exist_ok=True)
    args.manifest_out.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="ascii"
    )
    print(f"[OK] {args.manifest_out}")

    if args.preview_dir is not None:
        for set_name in sets:
            out_path = args.preview_dir / f"piece_tiles_{set_name}.png"
            build_preview(args.pieces_root, set_name, palette, cell_w, cell_h, out_path)
            print(f"[OK] {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
