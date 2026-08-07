#!/usr/bin/env python3
"""Build deterministic packed-4bpp Sprinter GFX640 asset pages."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zlib
from collections import Counter
from pathlib import Path


PAGE_SIZE = 0x4000
TILE_WIDTH = 16
TILE_HEIGHT = 32
TILE_BYTES = 256
TILES_PER_PAGE = PAGE_SIZE // TILE_BYTES
PIECE_WIDTH = 32
PIECE_HEIGHT = 16
PIECE_STORAGE_ROW = 4
PIECE_SETS = 3
PIECES_PER_SET = 12
PIECE_COUNT = PIECE_SETS * PIECES_PER_SET
PIECE_TILES = PIECE_COUNT * 2
ABOUT_WIDTH = 384
ABOUT_HEIGHT = 192
ABOUT_COLS = ABOUT_WIDTH // TILE_WIDTH
ABOUT_ROWS = ABOUT_HEIGHT // TILE_HEIGHT
ABOUT_TILES = ABOUT_COLS * ABOUT_ROWS
GFX_TILES = PIECE_TILES + ABOUT_TILES
GFX_PAGES = (GFX_TILES + TILES_PER_PAGE - 1) // TILES_PER_PAGE
TRANSPARENT = 15
PACKED_TRANSPARENT = 0xFF
# A 32x16 final raster has only a few pixels for an antialiased contour.  The
# old halfway-alpha cutoff discarded most of that contour, shrinking a tightly
# cropped piece by several pixels in both directions.  GFX640 has binary key
# transparency, so retain every visible edge sample rather than treating it as
# a second, unintended inset.
OPAQUE_ALPHA = 64
PALETTE_ENTRIES = 256
PALETTE_BYTES = PALETTE_ENTRIES * 3
GAMEPLAY_PROFILE_OFFSET = 0
GAMEPLAY_PROFILE_COUNT = PIECE_SETS
ABOUT_PROFILE_OFFSET = PALETTE_BYTES * GAMEPLAY_PROFILE_COUNT
THEME_TABLE_OFFSET = ABOUT_PROFILE_OFFSET + PALETTE_BYTES
PIPELINE_VERSION = 3

PIECE_ORDER = ("wK", "wQ", "wR", "wB", "wN", "wP",
               "bK", "bQ", "bR", "bB", "bN", "bP")
UI_COLORS = (
    (0, 0, 0), (255, 255, 255), (128, 128, 128), (224, 48, 48),
    (48, 208, 80), (64, 112, 224), (248, 224, 72), (48, 216, 224),
    (224, 72, 208), (216, 216, 216),
)
THEME_RGB = (
    ((238, 238, 210), (118, 150, 86)),
    ((214, 226, 238), (76, 118, 154)),
    ((232, 235, 200), (102, 148, 91)),
    ((240, 217, 181), (181, 136, 99)),
    ((222, 184, 135), (139, 90, 43)),
)

def read_png_rgba(path: Path, width: int, height: int) -> bytes:
    """Read the deliberately narrow PNG format used for Sprinter piece atlases."""
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"{path}: expected PNG signature")
    offset = 8
    chunks: list[bytes] = []
    image_size = None
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        name = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        offset += length + 12
        if name == b"IHDR":
            image_size = struct.unpack(">IIBBBBB", body)
        elif name == b"IDAT":
            chunks.append(body)
        elif name == b"IEND":
            break
    if image_size != (width, height, 8, 6, 0, 0, 0):
        raise ValueError(f"{path}: require {width}x{height} non-interlaced RGBA8888 PNG")
    rows = zlib.decompress(b"".join(chunks))
    stride = width * 4
    if len(rows) != height * (stride + 1) or any(rows[row * (stride + 1)] for row in range(height)):
        raise ValueError(f"{path}: PNG must use filter type 0")
    return b"".join(rows[row * (stride + 1) + 1:(row + 1) * (stride + 1)]
                    for row in range(height))


def nearest_index(rgb: tuple[int, int, int],
                  palette: tuple[tuple[int, int, int], ...] | list[tuple[int, int, int]]) -> int:
    r, g, b = rgb
    return min(range(len(palette)), key=lambda index: (
        (r - palette[index][0]) ** 2 +
        (g - palette[index][1]) ** 2 +
        (b - palette[index][2]) ** 2,
        index,
    ))


def tile_ref(global_tile: int) -> int:
    return ((global_tile // TILES_PER_PAGE) << 8) | (global_tile % TILES_PER_PAGE)


def pack_pair(left: int, right: int) -> int:
    if not (0 <= left <= 15 and 0 <= right <= 15):
        raise ValueError("4bpp index outside 0..15")
    return (left << 4) | right


def quantize_piece(raw: bytes, colors: list[tuple[int, int, int]]) -> bytes:
    if len(raw) != PIECE_WIDTH * PIECE_HEIGHT * 4:
        raise ValueError("piece raster must be exactly 32x16 RGBA")
    out = bytearray()
    for offset in range(0, len(raw), 8):
        p0 = tuple(raw[offset:offset + 3])
        a0 = raw[offset + 3]
        p1 = tuple(raw[offset + 4:offset + 7])
        a1 = raw[offset + 7]
        if a0 < OPAQUE_ALPHA and a1 < OPAQUE_ALPHA:
            out.append(PACKED_TRANSPARENT)
            continue
        # GFX_KEY_FF is byte-transparent.  Extend the opaque neighbour into a
        # half-transparent pair so no packed byte contains only one key nibble.
        if a0 < OPAQUE_ALPHA:
            p0 = p1
        if a1 < OPAQUE_ALPHA:
            p1 = p0
        left = 12 + nearest_index(p0, colors)
        right = 12 + nearest_index(p1, colors)
        out.append(pack_pair(left, right))
    if len(out) != PIECE_WIDTH * PIECE_HEIGHT // 2:
        raise AssertionError("piece packing length changed")
    return bytes(out)


def store_piece(packed: bytes) -> tuple[bytes, bytes]:
    left = bytearray((PACKED_TRANSPARENT,)) * TILE_BYTES
    right = bytearray((PACKED_TRANSPARENT,)) * TILE_BYTES
    for row in range(PIECE_HEIGHT):
        source = row * 16
        target = (PIECE_STORAGE_ROW + row) * 8
        left[target:target + 8] = packed[source:source + 8]
        right[target:target + 8] = packed[source + 8:source + 16]
    return bytes(left), bytes(right)


def select_about_colors(raw: bytes) -> list[tuple[int, int, int]]:
    if len(raw) != ABOUT_WIDTH * ABOUT_HEIGHT * 3:
        raise ValueError("About raster must be exactly 384x192 RGB")
    # Bucket to RGB444 before ranking.  This avoids wasting all five artwork
    # slots on near-identical antialiasing shades while remaining deterministic.
    counts: Counter[tuple[int, int, int]] = Counter()
    for offset in range(0, len(raw), 3):
        rgb = tuple((value >> 4) * 17 for value in raw[offset:offset + 3])
        counts[rgb] += 1
    colors: list[tuple[int, int, int]] = []
    for rgb, _count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
        if rgb in UI_COLORS or rgb in colors:
            continue
        colors.append(rgb)
        if len(colors) == 5:
            break
    while len(colors) < 5:
        colors.append((0, 0, 0))
    return colors


def pack_about(raw: bytes, colors: list[tuple[int, int, int]]) -> bytes:
    palette = list(UI_COLORS) + colors
    indexes = bytearray()
    for offset in range(0, len(raw), 3):
        indexes.append(nearest_index(tuple(raw[offset:offset + 3]), palette))
    out = bytearray()
    for tile_y in range(0, ABOUT_HEIGHT, TILE_HEIGHT):
        for tile_x in range(0, ABOUT_WIDTH, TILE_WIDTH):
            for row in range(TILE_HEIGHT):
                start = (tile_y + row) * ABOUT_WIDTH + tile_x
                for col in range(0, TILE_WIDTH, 2):
                    out.append(pack_pair(indexes[start + col], indexes[start + col + 1]))
    if len(out) != ABOUT_TILES * TILE_BYTES:
        raise AssertionError("About tile packing length changed")
    return bytes(out)


def profile(first: list[tuple[int, int, int]]) -> bytes:
    values = list(first)
    values.extend([(0, 0, 0)] * (PALETTE_ENTRIES - len(values)))
    return bytes(component for rgb in values for component in rgb)


def build(raster_manifest: Path, about_rgb: Path,
          font: Path) -> tuple[list[bytes], dict[str, object], bytes]:
    pinned = json.loads(raster_manifest.read_text(encoding="utf-8"))
    about = about_rgb.read_bytes()
    if pinned.get("files", {}).get(about_rgb.name, {}).get("sha256") != hashlib.sha256(about).hexdigest():
        raise ValueError("pinned About raster hash is stale")
    sets = list(pinned.get("piece_sets", []))
    if len(sets) != PIECE_SETS:
        raise ValueError("raster manifest must describe three piece sets")
    atlases = pinned.get("piece_atlases", {})
    if not isinstance(atlases, dict):
        raise ValueError("raster manifest must describe PNG piece atlases")

    tiles: list[bytes] = []
    refs: dict[str, dict[str, list[int]]] = {}
    stride = PIECE_WIDTH * PIECE_HEIGHT * 4
    for set_index, set_name in enumerate(sets):
        descriptor = atlases.get(set_name)
        if not isinstance(descriptor, dict):
            raise ValueError(f"missing atlas descriptor for {set_name}")
        atlas_name = descriptor.get("file")
        palette_value = descriptor.get("palette")
        if not isinstance(atlas_name, str) or not isinstance(palette_value, list) or len(palette_value) != 3:
            raise ValueError(f"invalid atlas descriptor for {set_name}")
        atlas_path = raster_manifest.parent / atlas_name
        atlas = read_png_rgba(atlas_path, PIECE_WIDTH * 6, PIECE_HEIGHT * 2)
        if pinned.get("files", {}).get(atlas_name, {}).get("sha256") != hashlib.sha256(atlas_path.read_bytes()).hexdigest():
            raise ValueError(f"pinned atlas hash is stale: {atlas_name}")
        colors = [tuple(color) for color in palette_value]
        if any(len(color) != 3 or any(not isinstance(value, int) or not 0 <= value <= 255 for value in color)
               for color in colors):
            raise ValueError(f"invalid three-colour palette for {set_name}")
        set_refs: dict[str, list[int]] = {}
        for piece_index, piece in enumerate(PIECE_ORDER):
            x = (piece_index % 6) * PIECE_WIDTH
            y = (piece_index // 6) * PIECE_HEIGHT
            raw = b"".join(atlas[((y + row) * PIECE_WIDTH * 6 + x) * 4:
                                  ((y + row) * PIECE_WIDTH * 6 + x + PIECE_WIDTH) * 4]
                           for row in range(PIECE_HEIGHT))
            left, right = store_piece(quantize_piece(raw, colors))
            first = len(tiles)
            tiles.extend((left, right))
            set_refs[piece] = [tile_ref(first), tile_ref(first + 1)]
        refs[set_name] = set_refs

    about_colors = select_about_colors(about)
    about_packed = pack_about(about, about_colors)
    about_first = len(tiles)
    tiles.extend(about_packed[offset:offset + TILE_BYTES]
                 for offset in range(0, len(about_packed), TILE_BYTES))
    if len(tiles) != GFX_TILES:
        raise AssertionError("unexpected packed tile count")
    blob = b"".join(tiles).ljust(GFX_PAGES * PAGE_SIZE, bytes((PACKED_TRANSPARENT,)))
    pages = [blob[offset:offset + PAGE_SIZE]
             for offset in range(0, len(blob), PAGE_SIZE)]

    gameplay_profiles = []
    for set_name in sets:
        palette_value = atlases[set_name]["palette"]
        gameplay_profiles.append(list(UI_COLORS) + [THEME_RGB[0][0], THEME_RGB[0][1]] +
                                 [tuple(color) for color in palette_value] + [(255, 0, 255)])
    about_profile = list(UI_COLORS) + about_colors + [(255, 0, 255)]
    theme_table = bytes(component for pair in THEME_RGB for rgb in pair for component in rgb)
    palette_page = bytearray(PAGE_SIZE)
    for index, gameplay in enumerate(gameplay_profiles):
        start = GAMEPLAY_PROFILE_OFFSET + index * PALETTE_BYTES
        palette_page[start:start + PALETTE_BYTES] = profile(gameplay)
    palette_page[ABOUT_PROFILE_OFFSET:ABOUT_PROFILE_OFFSET + PALETTE_BYTES] = profile(about_profile)
    palette_page[THEME_TABLE_OFFSET:THEME_TABLE_OFFSET + len(theme_table)] = theme_table
    pages.append(bytes(palette_page))

    widths = font.read_bytes()
    if len(widths) < 256:
        raise ValueError("AFNT640 font is truncated")
    width_table = widths[:256]
    if any(value == 0 or value > 8 for value in width_table):
        raise ValueError("AFNT640 width table contains an invalid column width")

    manifest: dict[str, object] = {
        "format": "Shatranj Sprinter GFX640 assets",
        "version": PIPELINE_VERSION,
        "page_size": PAGE_SIZE,
        "page_count": len(pages),
        "gfx_page_count": GFX_PAGES,
        "transparent_index": TRANSPARENT,
        "packed_transparent": PACKED_TRANSPARENT,
        "palette": {
            "page_index": GFX_PAGES,
            "encoding": "RGB888",
            "gameplay_profile": {"offset": GAMEPLAY_PROFILE_OFFSET, "length": PALETTE_BYTES},
            "gameplay_profiles": {"count": GAMEPLAY_PROFILE_COUNT, "stride": PALETTE_BYTES},
            "about_profile": {"offset": ABOUT_PROFILE_OFFSET, "length": PALETTE_BYTES},
            "theme_table": {"offset": THEME_TABLE_OFFSET, "pairs": len(THEME_RGB)},
            "theme_slots": [10, 11],
            "ui_indices": {"black": 0, "white": 1, "gray": 2, "error": 3,
                           "success": 4, "blue": 5, "notice": 6, "cyan": 7,
                           "magenta": 8, "outline": 9},
        },
        "pieces": {
            "visible_width": PIECE_WIDTH, "visible_height": PIECE_HEIGHT,
            "storage_tile_width": TILE_WIDTH, "storage_tile_height": TILE_HEIGHT,
            "storage_visible_rows": [PIECE_STORAGE_ROW, PIECE_STORAGE_ROW + PIECE_HEIGHT - 1],
            "tiles_per_piece": 2, "sets": sets, "order": list(PIECE_ORDER),
            "tile_refs": refs,
            "palettes": {name: atlases[name]["palette"] for name in sets},
        },
        "about": {
            "x": 16, "y": 24, "width": ABOUT_WIDTH, "height": ABOUT_HEIGHT,
            "tile_columns": ABOUT_COLS, "tile_rows": ABOUT_ROWS,
            "tile_refs": [tile_ref(about_first + index) for index in range(ABOUT_TILES)],
        },
        "font": {"source": font.as_posix(), "width_count": len(width_table),
                 "width_sha256": hashlib.sha256(width_table).hexdigest()},
        "pages": [
            {"index": index, "kind": "gfx" if index < GFX_PAGES else "palette",
             "size": len(page), "sha256": hashlib.sha256(page).hexdigest()}
            for index, page in enumerate(pages)
        ],
    }
    return pages, manifest, width_table


def write_defs(path: Path, manifest: dict[str, object], c: bool) -> None:
    palette = manifest["palette"]
    assert isinstance(palette, dict)
    prefix = "#define" if c else "DEFC"
    suffix = "u" if c else ""
    assign = " " if c else " = "
    values = {
        "SPRINTER_ASSET_BLOB_PAGE_COUNT": manifest["page_count"],
        "SPRINTER_GFX_SOURCE_PAGE_COUNT": manifest["gfx_page_count"],
        "SPRINTER_PALETTE_BLOB_INDEX": palette["page_index"],
        "SPRINTER_PALETTE_BLOB_BYTES": PALETTE_BYTES,
        "SPRINTER_GAMEPLAY_PALETTE_OFFSET": GAMEPLAY_PROFILE_OFFSET,
        "SPRINTER_GAMEPLAY_PALETTE_COUNT": GAMEPLAY_PROFILE_COUNT,
        "SPRINTER_GAMEPLAY_PALETTE_STRIDE": PALETTE_BYTES,
        "SPRINTER_ABOUT_PALETTE_OFFSET": ABOUT_PROFILE_OFFSET,
        "SPRINTER_THEME_TABLE_OFFSET": THEME_TABLE_OFFSET,
        "SPRINTER_THEME_LIGHT_SLOT": 10,
        "SPRINTER_THEME_DARK_SLOT": 11,
    }
    lines = [("/*" if c else ";") + " Generated by tools/build_sprinter_assets.py; do not edit. " + ("*/" if c else "")]
    if c:
        lines.extend(("#ifndef SHATRANJ_SPRINTER_ASSETS_H", "#define SHATRANJ_SPRINTER_ASSETS_H"))
    for name, value in values.items():
        lines.append(f"{prefix} {name}{assign}{value}{suffix}")
    if c:
        lines.extend(("#endif", ""))
    path.write_text("\n".join(lines) + ("" if c else "\n"), encoding="ascii")


def write_widths(path: Path, widths: bytes) -> None:
    lines = ["/* Generated from the pinned AFNT640 font.bin; do not edit. */",
             "#ifndef SHATRANJ_SPRINTER_AFNT640_WIDTHS_H",
             "#define SHATRANJ_SPRINTER_AFNT640_WIDTHS_H",
             "static const unsigned char sprinter_afnt640_widths[256] = {"]
    for offset in range(0, len(widths), 16):
        lines.append("    " + ", ".join(f"{value}u" for value in widths[offset:offset + 16]) + ",")
    lines.extend(("};", "#endif", ""))
    path.write_text("\n".join(lines), encoding="ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raster-manifest", type=Path, required=True)
    parser.add_argument("--about", type=Path, required=True)
    parser.add_argument("--font", type=Path, required=True)
    parser.add_argument("--page-prefix", type=Path, required=True)
    parser.add_argument("--manifest-out", type=Path, required=True)
    parser.add_argument("--asm-out", type=Path, required=True)
    parser.add_argument("--c-out", type=Path, required=True)
    parser.add_argument("--font-widths-out", type=Path, required=True)
    args = parser.parse_args()
    try:
        pages, manifest, widths = build(args.raster_manifest, args.about, args.font)
        args.manifest_out.parent.mkdir(parents=True, exist_ok=True)
        page_paths = []
        for index, page in enumerate(pages):
            path = Path(f"{args.page_prefix}{index}.bin")
            path.write_bytes(page)
            page_paths.append(path.as_posix())
        manifest["page_files"] = page_paths
        args.manifest_out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        write_defs(args.asm_out, manifest, False)
        write_defs(args.c_out, manifest, True)
        write_widths(args.font_widths_out, widths)
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f"build_sprinter_assets: {exc}") from exc
    print(f"[OK] Sprinter GFX640 assets: {len(pages)} exact 16-KiB page(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
