#!/usr/bin/env python3
"""Build deterministic Sprinter GFX320 pages from the pinned Next assets.

The output is deliberately page-native: one page contains the 36 chess-piece
tiles, three pages contain the 256x192 About image as 16x16 row-major tiles,
and one page contains the RGB888 palette.  Every page is exactly 16 KiB so it
can be appended to the DSS PRELOAD monoblock without a second file format.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path


PAGE_SIZE = 0x4000
TILE_SIZE = 16
TILE_BYTES = TILE_SIZE * TILE_SIZE
TILES_PER_PAGE = PAGE_SIZE // TILE_BYTES
PIECE_SETS = 3
PIECES_PER_SET = 12
PIECE_TILES = PIECE_SETS * PIECES_PER_SET
ABOUT_WIDTH = 256
ABOUT_HEIGHT = 192
ABOUT_COLS = ABOUT_WIDTH // TILE_SIZE
ABOUT_ROWS = ABOUT_HEIGHT // TILE_SIZE
ABOUT_TILES = ABOUT_COLS * ABOUT_ROWS
ABOUT_PAGES = ABOUT_TILES // TILES_PER_PAGE
TRANSPARENT = 0xFF
PALETTE_BYTES = 256 * 3
PIPELINE_VERSION = 1

PIECE_ORDER = ("wK", "wQ", "wR", "wB", "wN", "wP",
               "bK", "bQ", "bR", "bB", "bN", "bP")

# Stable UI colours are placed first.  Render code refers to these indices;
# source artwork is then mapped to the nearest entry in the completed palette.
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


def decode_next_palette(raw: bytes) -> list[tuple[int, int, int]]:
    if len(raw) < 512:
        raw = raw.ljust(512, b"\0")
    colors = []
    for index in range(256):
        b0, b1 = raw[index * 2:index * 2 + 2]
        r = (b0 >> 5) & 7
        g = (b0 >> 2) & 7
        b = ((b0 & 3) << 1) | (b1 & 1)
        colors.append((r * 255 // 7, g * 255 // 7, b * 255 // 7))
    return colors


def append_unique(values: list[tuple[int, int, int]], rgb: tuple[int, int, int]) -> None:
    if rgb not in values:
        values.append(rgb)


def nearest_index(rgb: tuple[int, int, int], palette: list[tuple[int, int, int]]) -> int:
    r, g, b = rgb
    return min(
        range(len(palette)),
        key=lambda i: (
            (r - palette[i][0]) ** 2
            + (g - palette[i][1]) ** 2
            + (b - palette[i][2]) ** 2,
            i,
        ),
    )


def build_palette(piece_colors: list[tuple[int, int, int]],
                  about_colors: list[tuple[int, int, int]]) -> list[tuple[int, int, int]]:
    palette: list[tuple[int, int, int]] = []
    for rgb in UI_COLORS:
        append_unique(palette, rgb)
    for light, dark in THEME_RGB:
        append_unique(palette, light)
        append_unique(palette, dark)
    for rgb in sorted(set(piece_colors)):
        append_unique(palette, rgb)
    if len(palette) > TRANSPARENT:
        raise ValueError(f"piece/UI palette needs {len(palette)} opaque entries (max 255)")

    # Frequency first preserves the most visible About colours.  RGB is the
    # tie-breaker, making the result independent of hash/dict iteration order.
    for rgb, _count in sorted(Counter(about_colors).items(),
                              key=lambda item: (-item[1], item[0])):
        if len(palette) == TRANSPARENT:
            break
        append_unique(palette, rgb)
    while len(palette) < TRANSPARENT:
        palette.append((0, 0, 0))
    palette.append((255, 0, 255))
    return palette


def retile(image: bytes, width: int, height: int) -> bytes:
    if len(image) != width * height or width % TILE_SIZE or height % TILE_SIZE:
        raise ValueError("image cannot be represented by exact 16x16 tiles")
    out = bytearray()
    for tile_y in range(0, height, TILE_SIZE):
        for tile_x in range(0, width, TILE_SIZE):
            for row in range(TILE_SIZE):
                start = (tile_y + row) * width + tile_x
                out.extend(image[start:start + TILE_SIZE])
    return bytes(out)


def tile_ref(global_tile: int) -> int:
    return ((global_tile // TILES_PER_PAGE) << 8) | (global_tile % TILES_PER_PAGE)


def build(next_pieces: Path, next_piece_palette: Path, next_meta: Path,
          about_nxi: Path) -> tuple[list[bytes], dict[str, object]]:
    meta = json.loads(next_meta.read_text(encoding="utf-8"))
    pieces = next_pieces.read_bytes()
    required_piece_bytes = PIECE_TILES * TILE_BYTES
    if len(pieces) < required_piece_bytes:
        raise ValueError(f"piece source is truncated: {len(pieces)} bytes")
    next_transparent = int(meta["transparent_index"])
    if not 0 <= next_transparent <= 255:
        raise ValueError("Next transparent index is outside 0..255")
    next_pal = decode_next_palette(next_piece_palette.read_bytes())

    about = about_nxi.read_bytes()
    expected_about = 512 + ABOUT_WIDTH * ABOUT_HEIGHT
    if len(about) != expected_about:
        raise ValueError(f"About NXI must be exactly {expected_about} bytes")
    about_pal = decode_next_palette(about[:512])
    about_indexes = about[512:]

    piece_src = pieces[:required_piece_bytes]
    piece_colors = [next_pal[value] for value in piece_src if value != next_transparent]
    about_colors = [about_pal[value] for value in about_indexes]
    palette = build_palette(piece_colors, about_colors)

    piece_out = bytes(
        TRANSPARENT if value == next_transparent
        else nearest_index(next_pal[value], palette[:TRANSPARENT])
        for value in piece_src
    )
    if TRANSPARENT not in piece_out:
        raise ValueError("piece output contains no #FF transparency")
    about_pixels = bytes(
        nearest_index(about_pal[value], palette[:TRANSPARENT])
        for value in about_indexes
    )
    if TRANSPARENT in about_pixels:
        raise AssertionError("opaque About pixels mapped to #FF")
    about_tiles = retile(about_pixels, ABOUT_WIDTH, ABOUT_HEIGHT)

    piece_page = piece_out.ljust(PAGE_SIZE, bytes((TRANSPARENT,)))
    about_pages = [about_tiles[offset:offset + PAGE_SIZE]
                   for offset in range(0, len(about_tiles), PAGE_SIZE)]
    if len(about_pages) != ABOUT_PAGES or any(len(page) != PAGE_SIZE for page in about_pages):
        raise AssertionError("About tile pages are not exact")
    # Keep the generated source contract byte-for-byte compatible with the
    # established Stage 2 renderer.  GFX320 accepts RGB8 input and performs
    # any DSS-specific register ordering internally.
    palette_raw = bytes(component for rgb in palette for component in rgb)
    palette_page = palette_raw.ljust(PAGE_SIZE, b"\0")
    pages = [piece_page, *about_pages, palette_page]

    theme_indices = [
        {
            "light": palette.index(light),
            "dark": palette.index(dark),
        }
        for light, dark in THEME_RGB
    ]
    sets = list(meta.get("sets", []))
    if len(sets) != PIECE_SETS:
        raise ValueError("Next metadata must describe exactly three piece sets")
    piece_refs = {
        set_name: {
            piece: tile_ref(set_index * PIECES_PER_SET + piece_index)
            for piece_index, piece in enumerate(PIECE_ORDER)
        }
        for set_index, set_name in enumerate(sets)
    }
    about_refs = [tile_ref(TILES_PER_PAGE + index) for index in range(ABOUT_TILES)]
    manifest: dict[str, object] = {
        "format": "Shatranj Sprinter assets",
        "version": PIPELINE_VERSION,
        "page_size": PAGE_SIZE,
        "transparent_index": TRANSPARENT,
        "page_count": len(pages),
        "gfx_page_count": 1 + ABOUT_PAGES,
        "palette": {
            "page_index": 1 + ABOUT_PAGES,
            "offset": 0,
            "length": PALETTE_BYTES,
            "encoding": "RGB888",
            "theme_indices": theme_indices,
            "ui_indices": {
                "black": 0, "white": 1, "gray": 2, "error": 3,
                "success": 4, "blue": 5, "notice": 6, "cyan": 7,
                "magenta": 8, "outline": 9,
            },
        },
        "pieces": {
            "tile_size": TILE_SIZE,
            "sets": sets,
            "order": list(PIECE_ORDER),
            "tile_refs": piece_refs,
        },
        "about": {
            "x": 32, "y": 32,
            "width": ABOUT_WIDTH, "height": ABOUT_HEIGHT,
            "tile_columns": ABOUT_COLS, "tile_rows": ABOUT_ROWS,
            "tile_refs": about_refs,
        },
        "pages": [
            {
                "index": index,
                "kind": "pieces" if index == 0 else
                        "about" if index <= ABOUT_PAGES else "palette",
                "size": len(page),
                "sha256": hashlib.sha256(page).hexdigest(),
            }
            for index, page in enumerate(pages)
        ],
    }
    return pages, manifest


def write_defs(path: Path, manifest: dict[str, object]) -> None:
    palette = manifest["palette"]
    assert isinstance(palette, dict)
    themes = palette["theme_indices"]
    assert isinstance(themes, list)
    lines = [
        "; Generated by tools/build_sprinter_assets.py; do not edit.",
        f"DEFC SPRINTER_ASSET_BLOB_PAGE_COUNT = {manifest['page_count']}",
        f"DEFC SPRINTER_GFX_SOURCE_PAGE_COUNT = {manifest['gfx_page_count']}",
        f"DEFC SPRINTER_PALETTE_BLOB_INDEX = {palette['page_index']}",
        f"DEFC SPRINTER_PALETTE_BLOB_BYTES = {palette['length']}",
    ]
    for index, pair in enumerate(themes):
        lines.append(f"DEFC SPRINTER_THEME_{index}_LIGHT = {pair['light']}")
        lines.append(f"DEFC SPRINTER_THEME_{index}_DARK = {pair['dark']}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_c_defs(path: Path, manifest: dict[str, object]) -> None:
    palette = manifest["palette"]
    assert isinstance(palette, dict)
    themes = palette["theme_indices"]
    assert isinstance(themes, list)
    lines = [
        "/* Generated by tools/build_sprinter_assets.py; do not edit. */",
        "#ifndef SHATRANJ_SPRINTER_ASSETS_H",
        "#define SHATRANJ_SPRINTER_ASSETS_H",
        f"#define SPRINTER_ASSET_BLOB_PAGE_COUNT {manifest['page_count']}u",
        f"#define SPRINTER_GFX_SOURCE_PAGE_COUNT {manifest['gfx_page_count']}u",
        f"#define SPRINTER_PALETTE_BLOB_INDEX {palette['page_index']}u",
        f"#define SPRINTER_PALETTE_BLOB_BYTES {palette['length']}u",
    ]
    for index, pair in enumerate(themes):
        lines.append(f"#define SPRINTER_THEME_{index}_LIGHT {pair['light']}u")
        lines.append(f"#define SPRINTER_THEME_{index}_DARK {pair['dark']}u")
    lines.extend(["#endif", ""])
    path.write_text("\n".join(lines), encoding="ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pieces", type=Path, required=True)
    parser.add_argument("--piece-palette", type=Path, required=True)
    parser.add_argument("--piece-meta", type=Path, required=True)
    parser.add_argument("--about", type=Path, required=True)
    parser.add_argument("--page-prefix", type=Path, required=True)
    parser.add_argument("--manifest-out", type=Path, required=True)
    parser.add_argument("--asm-out", type=Path, required=True)
    parser.add_argument("--c-out", type=Path)
    args = parser.parse_args()
    try:
        pages, manifest = build(args.pieces, args.piece_palette,
                                args.piece_meta, args.about)
        args.manifest_out.parent.mkdir(parents=True, exist_ok=True)
        args.asm_out.parent.mkdir(parents=True, exist_ok=True)
        page_paths = []
        for index, page in enumerate(pages):
            path = Path(f"{args.page_prefix}{index}.bin")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(page)
            page_paths.append(path.as_posix())
        manifest["page_files"] = page_paths
        args.manifest_out.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        write_defs(args.asm_out, manifest)
        if args.c_out:
            args.c_out.parent.mkdir(parents=True, exist_ok=True)
            write_c_defs(args.c_out, manifest)
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f"build_sprinter_assets: {exc}") from exc
    print(f"[OK] Sprinter assets: {len(pages)} exact 16-KiB page(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
