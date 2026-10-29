#!/usr/bin/env python3
"""Pack committed PNGs into four opaque 4bpp piece pages.

Geometry comes from render_layout.json. Accelerator addresses remain 256-byte
slots; a 400-byte tile occupies two slots (112 zero pad bytes). Each piece's
light/dark/flash variants occupy six consecutive slots. Ten groups fit a
page; the HDR asset indices are 1, 2, 10, 11, preserving all earlier assets.
SVG conversion is an explicit manual operation, never a build dependency.
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

import gen_sprinter_render_layout as geometry
GEOMETRY_PATH = ROOT / "src/sprinter/render_layout.json"
GEOMETRY = geometry.compute_symbols(geometry.load_layout_file(GEOMETRY_PATH))
TILE_W, TILE_H = GEOMETRY["PIECE_W"], GEOMETRY["PIECE_H"]
TILE_SLOTS = GEOMETRY["PIECE_SLOTS"]
BLOCK_BYTES = GEOMETRY["PIECE_BLOCK_BYTES"]
GROUP_SLOTS = TILE_SLOTS * 3
GROUPS_PER_PAGE = (PAGE_SIZE // SLOT_SIZE) // GROUP_SLOTS
ASSET_PAGE_INDICES = (1, 2, 10, 11)
MANIFEST_FORMAT = "shatranj-sprinter-tiles-v2"
LAYOUT = "row-major-packed-4bpp-high-nibble-left"

SIDES = ["w", "b"]
KINDS = ["K", "Q", "R", "B", "N", "P"]
PIECE_ORDER = [f"{side}{kind}" for side in SIDES for kind in KINDS]  # 12 keys
BACKGROUND_ORDER = ["light", "dark"]  # -> palette indices 2, 3
BACKGROUND_INDICES = [2, 3]

# S9 move-flash: one extra tile per piece, precomposed on hud_select.
FLASH_BACKGROUND_INDEX = 8

# Two adjacent index-15 pixels pack into a 0xFF byte, which the hardware
# reads as the transparency key wherever the data is drawn through the
# keyed VRAM alias. Piece tiles are blitted opaque, so that byte would in
# fact be harmless here -- but build_pages refuses 0xFF outright rather
# than relying on the caller's choice of alias, so keeping 15 out of the
# source art turns "your PNG happened to produce a forbidden byte" into a
# rule an artist can follow by looking at the colour picker.
KEY_NIBBLE_INDEX = 15

# Entries 4-7 belong to the SET, not to the palette as a whole: each set
# in assets/sprinter/palette.json's "piece_sets" gives them its own four
# RGB values, and picking a set re-writes those four palette registers
# (port.md section 3.5). So a PNG in set X is validated against set X's
# colours -- the tile bytes are identical either way, since a tile stores
# the index and the palette supplies the colour.
PIECE_SET_INDICES = [4, 5, 6, 7]

# Which palette entries an opaque pixel of a piece PNG may use.
#
# NOT "the four piece colours": a piece tile is ordinary opaque 4bpp data
# in the screen's shared 16-entry palette, so every entry that is not
# structurally unusable is the artist's to spend, HUD colours included
# (port.md section 3.6). Exactly three kinds of entry are excluded:
#
#   2, 3  the light/dark board square. precompose_tile paints these UNDER
#         the piece, so a pixel in a square's own colour is invisible on
#         that square -- and both are re-tinted by the board theme, which
#         would drag the piece's colours along with it.
#   8     hud_select, the move-flash background: same argument, for the
#         duration of the flash tile.
#   15    see KEY_NIBBLE_INDEX.
#
# assets/sprinter/palette.json carries the same list under
# "piece_allowed_indices" (it ships to the artist with the PNGs);
# tests/tools/test_sprinter_piece_tiles.py fails if the two drift apart.
PIECE_EXCLUDED_INDICES = (
    set(BACKGROUND_INDICES) | {FLASH_BACKGROUND_INDEX, KEY_NIBBLE_INDEX}
)
PIECE_ALLOWED_INDICES = [
    i for i in range(gsp.REQUIRED_BASE_COUNT) if i not in PIECE_EXCLUDED_INDICES
]
# The allowed entries that are NOT the set's own: shared with the rest of
# the screen, same RGB in every set, and the artist borrows them as
# accents (port.md section 3.6).
PIECE_SHARED_INDICES = [
    i for i in PIECE_ALLOWED_INDICES if i not in set(PIECE_SET_INDICES)
]
SLOTS_PER_PAGE = PAGE_SIZE // SLOT_SIZE                   # 64
TILES_PER_SET = len(PIECE_ORDER) * len(BACKGROUND_ORDER)  # 24
FLASH_TILES_PER_SET = len(PIECE_ORDER)                    # 12


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def parse_cell(spec: str) -> tuple[int, int]:
    try:
        w_str, h_str = spec.lower().split("x")
        return int(w_str), int(h_str)
    except ValueError:
        fail(f"invalid --cell {spec!r}, want WxH (e.g. 40x20)")


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


def piece_colours(palette: dict, set_name: str) -> dict[tuple[int, int, int], int]:
    """The {rgb: index} map a given set's PNGs are validated and packed
    against: that set's own four colours plus the shared accents."""
    by_name = {entry["name"]: entry for entry in palette["piece_sets"]}
    if set_name not in by_name:
        fail(f"piece set {set_name!r} has no palette in the palette JSON "
             f'("piece_sets" lists {sorted(by_name)}) -- the set list and the '
             "palette are the same decision and must name the same sets")
    colours = _rgb_set(palette, PIECE_SHARED_INDICES)
    for index in PIECE_SET_INDICES:
        rgb = gsp._parse_rgb(by_name[set_name]["entries"][str(index)], "piece set")
        colours[rgb] = index
    return colours


def _describe_colours(rgb_to_index: dict) -> str:
    """The allowed colours as "index #RRGGBB" pairs, index order. The
    diagnostic below is read by whoever repainted the PNG, so it names the
    colours they can pick, not the raw tuples the tool compares."""
    return ", ".join(
        f"{index} #{rgb[0]:02X}{rgb[1]:02X}{rgb[2]:02X}"
        for rgb, index in sorted(rgb_to_index.items(), key=lambda kv: kv[1])
    )


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
                     "not one of the palette colours a piece may use "
                     f"({_describe_colours(ref_rgb_to_index)})")
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
    if (cell_w, cell_h) != (TILE_W, TILE_H):
        fail(f"piece geometry must match {GEOMETRY_PATH}: {TILE_W}x{TILE_H}")
    palette_names = [entry["name"] for entry in palette["piece_sets"]]
    if palette_names != list(sets):
        fail(f"set list {list(sets)} does not match palette piece_sets {palette_names} (same names, same order)")
    if len(sets) != 3:
        fail("expected exactly three piece sets")
    pages = [bytearray(PAGE_SIZE) for _ in ASSET_PAGE_INDICES]
    records, input_shas = [], {}
    backgrounds = BACKGROUND_INDICES + [FLASH_BACKGROUND_INDEX]
    bg_ref = _rgb_set(palette, backgrounds)
    rgb_by_index = {index: rgb for rgb, index in bg_ref.items()}
    for set_index, set_name in enumerate(sets):
        refs = piece_colours(palette, set_name)
        groups = []
        for piece_index, key in enumerate(PIECE_ORDER):
            ordinal = set_index * len(PIECE_ORDER) + piece_index
            page_no, group_index = divmod(ordinal, GROUPS_PER_PAGE)
            start_slot = group_index * GROUP_SLOTS
            groups.append({"piece": key, "asset_page_index": ASSET_PAGE_INDICES[page_no],
                           "slot_base": start_slot})
            path = pieces_root / set_name / f"{key}.png"
            piece = load_and_validate_piece(path, cell_w, cell_h, refs)
            try:
                key_path = str(path.resolve().relative_to(ROOT))
            except ValueError:
                key_path = str(path)
            input_shas[key_path] = hashlib.sha256(path.read_bytes()).hexdigest()
            for bg, index in enumerate(backgrounds):
                tile = precompose_tile(piece, cell_w, cell_h, bg_ref, rgb_by_index[index], refs)
                if len(tile) > BLOCK_BYTES or 0xFF in tile:
                    fail(f"invalid tile {set_name}/{key} background {index}")
                offset = (start_slot + bg * TILE_SLOTS) * SLOT_SIZE
                assert offset + BLOCK_BYTES <= PAGE_SIZE
                pages[page_no][offset:offset + len(tile)] = tile
        records.append({"name": set_name, "groups": groups})
    return [bytes(page) for page in pages], {"sets": records, "input_shas": input_shas}


def build_manifest(sets_info: dict, cell_w: int, cell_h: int, stride: int,
                    palette_path: Path) -> dict:
    resolve_stride(cell_w, stride)
    return {
        "format": MANIFEST_FORMAT,
        "layout": LAYOUT,
        "cell": {"w": cell_w, "h": cell_h},
        "stride": stride,
        "tile_bytes": stride * cell_h,
        "block_bytes": BLOCK_BYTES,
        "slot_bytes": SLOT_SIZE,
        "slots_per_tile": TILE_SLOTS,
        "slots_per_group": GROUP_SLOTS,
        "variant_order": ["light", "dark", "flash"],
        "variant_palette_indices": [2, 3, FLASH_BACKGROUND_INDEX],
        "groups_per_page": GROUPS_PER_PAGE,
        "asset_page_indices": list(ASSET_PAGE_INDICES),
        "tiles_per_set": TILES_PER_SET,
        "flash_tiles_per_set": FLASH_TILES_PER_SET,
        "flash_background_palette_index": FLASH_BACKGROUND_INDEX,
        "piece_order": PIECE_ORDER,
        "background_order": BACKGROUND_ORDER,
        "background_palette_indices": BACKGROUND_INDICES,
        "piece_allowed_indices": PIECE_ALLOWED_INDICES,
        "piece_set_indices": PIECE_SET_INDICES,
        "piece_shared_indices": PIECE_SHARED_INDICES,
        "sets": sets_info["sets"],
        "sha256": {
            "palette_json": hashlib.sha256(palette_path.read_bytes()).hexdigest(),
            "pieces": dict(sorted(sets_info["input_shas"].items())),
        },
    }


def render_set_locations_inc(sets_info: dict, palette: dict) -> str:
    """Render page indices and slot bases from the actual packer's results.

    Page indices are HDR asset indices, not physical page numbers. The
    runtime must resolve them after DSS has assigned the physical pages.
    """
    records = sets_info["sets"]
    names = [record["name"] for record in records]
    palette_names = [record["name"] for record in palette["piece_sets"]]
    if names != palette_names:
        raise ValueError(f"packed set order {names!r} differs from palette {palette_names!r}")
    lines = [
        "; Generated by tools/build_sprinter_piece_tiles.py. Do not edit.",
        f"PIECE_LOCATION_COUNT EQU {len(records)}",
        "piece_set_locations:",
    ]
    for record in records:
        groups = record["groups"]
        if [g["piece"] for g in groups] != PIECE_ORDER:
            raise ValueError(f"invalid piece order for {record['name']}")
        lines.append(f"    ; {record['name']}")
        for group in groups:
            page, slot = group["asset_page_index"], group["slot_base"]
            if (page not in ASSET_PAGE_INDICES or not isinstance(slot, int)
                    or slot % GROUP_SLOTS or not 0 <= slot <= SLOTS_PER_PAGE - GROUP_SLOTS):
                raise ValueError(f"invalid piece group {group}")
            lines.append(f"    DB {page},{slot} ; {group['piece']}")
    return "\n".join(lines) + "\n"


def aspect_corrected(image: Image.Image, scale: int = 6) -> Image.Image:
    w, h = image.size
    stage = image.resize((w * scale, h * scale), Image.Resampling.NEAREST)
    return stage.resize((w * scale, h * scale * 2), Image.Resampling.NEAREST)


def build_preview(pieces_root: Path, set_name: str, palette: dict,
                   cell_w: int, cell_h: int, out_path: Path) -> None:
    piece_ref = piece_colours(palette, set_name)
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
    parser.add_argument("--cell", default=f"{TILE_W}x{TILE_H}")
    parser.add_argument("--stride", type=int, default=None,
                        help="source bytes per tile row; must equal cell width/2 "
                             "(precompose_tile packs rows tightly -- the flag "
                             "exists to make the manifest's stride explicit, not "
                             "to select a padded layout)")
    parser.add_argument("--page1-out", type=Path, required=True)
    parser.add_argument("--page2-out", type=Path, required=True)
    parser.add_argument("--page3-out", type=Path, required=True)
    parser.add_argument("--page4-out", type=Path, required=True)
    parser.add_argument("--manifest-out", type=Path, required=True)
    parser.add_argument("--locations-inc-out", type=Path,
                        help="optional assembly table of packed set locations")
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
    if len(pages) != 4:
        fail(f"expected exactly 4 output pages for 3 sets, got {len(pages)}")

    manifest = build_manifest(sets_info, cell_w, cell_h, stride, args.palette)

    for out_path, page in zip((args.page1_out, args.page2_out, args.page3_out, args.page4_out), pages):
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(page)
        print(f"[OK] {out_path}: {len(page)} bytes, "
              f"sha256 {hashlib.sha256(page).hexdigest()}")

    args.manifest_out.parent.mkdir(parents=True, exist_ok=True)
    args.manifest_out.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="ascii"
    )
    print(f"[OK] {args.manifest_out}")

    if args.locations_inc_out is not None:
        args.locations_inc_out.parent.mkdir(parents=True, exist_ok=True)
        args.locations_inc_out.write_text(
            render_set_locations_inc(sets_info, palette), encoding="ascii"
        )
        print(f"[OK] {args.locations_inc_out}")

    if args.preview_dir is not None:
        for set_name in sets:
            out_path = args.preview_dir / f"piece_tiles_{set_name}.png"
            build_preview(args.pieces_root, set_name, palette, cell_w, cell_h, out_path)
            print(f"[OK] {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
