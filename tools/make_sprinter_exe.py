#!/usr/bin/env python3
"""Build the deterministic Shatranj DSS PRELOAD monoblock.

The executable body is deliberately simple: the primary loader, a fixed-size
manifest and an integral number of raw 16 KiB pages.  DSS reads only the
loader before transferring control, so the loader can allocate the complete
page block and stream the tail without ever relying on another artifact.
"""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


EXE_SIGNATURE = b"EXE"
EXE_VERSION = 1
HEADER_SIZE = 512
LOADER_LOAD = 0x8100
LOADER_STACK = 0xBFF0
PAGE_SIZE = 0x4000
MANIFEST_SIZE = 32
MANIFEST_MAGIC = b"STM1"
RUNTIME_ENTRY = 0x8500
BASE_TRANSITION = 0x4000
BASE_RUNTIME_PATCH = 0x4001
RUNTIME_PAGE_TABLE = 0x8101
MAX_PAGES = 64


def layout_symbol(path: Path, name: str) -> int:
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0] == "DEFC" and parts[1] == name:
            return int(parts[3], 0)
    raise ValueError(f"{path} does not define {name}")


def require_page(path: Path, *, allow_short: bool) -> bytes:
    data = path.read_bytes()
    if not data:
        raise ValueError(f"empty page input: {path}")
    if len(data) > PAGE_SIZE:
        raise ValueError(f"page input exceeds 16 KiB: {path} ({len(data)} bytes)")
    if not allow_short and len(data) != PAGE_SIZE:
        raise ValueError(f"packed bank must be exactly 16 KiB: {path} ({len(data)} bytes)")
    return data.ljust(PAGE_SIZE, b"\0")


def make_header(loader_size: int) -> bytes:
    if not 0 < loader_size <= 0x3AF0:
        raise ValueError(f"PRELOAD loader size is outside WIN2 body bounds: {loader_size}")
    header = bytearray(HEADER_SIZE)
    header[:3] = EXE_SIGNATURE
    header[3] = EXE_VERSION
    struct.pack_into("<I", header, 4, HEADER_SIZE)
    struct.pack_into("<H", header, 8, loader_size)
    struct.pack_into("<H", header, 16, LOADER_LOAD)
    struct.pack_into("<H", header, 18, LOADER_LOAD)
    struct.pack_into("<H", header, 20, LOADER_STACK)
    return bytes(header)


def make_manifest(page_count: int, cold_count: int, asset_count: int = 0,
                  gfx_page_count: int = 0, palette_asset_index: int = 0,
                  palette_length: int = 0,
                  asset_page_table: int = 0,
                  palette_destination: int = 0) -> bytes:
    if not 2 <= page_count <= MAX_PAGES:
        raise ValueError(f"monoblock page count must be 2..{MAX_PAGES}, got {page_count}")
    if cold_count + asset_count != page_count - 2:
        raise ValueError("cold/asset counts do not match monoblock page count")
    if asset_count:
        if gfx_page_count >= asset_count:
            raise ValueError("asset bundle needs a palette page after GFX pages")
        if not gfx_page_count <= palette_asset_index < asset_count:
            raise ValueError("palette asset index must follow GFX pages")
    elif gfx_page_count or palette_asset_index or palette_length:
        raise ValueError("asset descriptors require asset pages")
    manifest = bytearray(MANIFEST_SIZE)
    manifest[:4] = MANIFEST_MAGIC
    manifest[4] = 2
    manifest[5] = page_count
    manifest[6] = cold_count
    manifest[7] = asset_count
    struct.pack_into("<H", manifest, 8, PAGE_SIZE)
    struct.pack_into("<H", manifest, 10, RUNTIME_ENTRY)
    struct.pack_into("<H", manifest, 12, BASE_TRANSITION)
    struct.pack_into("<H", manifest, 14, RUNTIME_PAGE_TABLE)
    struct.pack_into("<H", manifest, 16, MANIFEST_SIZE)
    struct.pack_into("<H", manifest, 18, BASE_RUNTIME_PATCH)
    manifest[20] = 2
    manifest[21] = 2 + cold_count
    manifest[22] = gfx_page_count
    manifest[23] = palette_asset_index
    struct.pack_into("<H", manifest, 24, palette_length)
    struct.pack_into("<H", manifest, 26, asset_page_table)
    struct.pack_into("<H", manifest, 28, palette_destination)
    return bytes(manifest)


def build_monoblock(loader: bytes, base: bytes, runtime: bytes,
                    cold_pages: list[bytes], asset_pages: list[bytes] | None = None,
                    *, gfx_page_count: int = 0,
                    palette_asset_index: int = 0,
                    palette_length: int = 0,
                    asset_page_table: int = 0,
                    palette_destination: int = 0) -> tuple[bytes, dict[str, object]]:
    if asset_pages is None:
        asset_pages = []
    pages = [base, runtime, *cold_pages, *asset_pages]
    manifest = make_manifest(
        len(pages), len(cold_pages), len(asset_pages), gfx_page_count,
        palette_asset_index, palette_length, asset_page_table,
        palette_destination,
    )
    image = make_header(len(loader)) + loader + manifest + b"".join(pages)
    expected = HEADER_SIZE + len(loader) + MANIFEST_SIZE + len(pages) * PAGE_SIZE
    if len(image) != expected:
        raise AssertionError("internal monoblock size mismatch")
    description: dict[str, object] = {
        "format": "Shatranj Sprinter monoblock",
        "version": 2,
        "header_size": HEADER_SIZE,
        "loader_load": LOADER_LOAD,
        "loader_size": len(loader),
        "manifest_size": MANIFEST_SIZE,
        "page_size": PAGE_SIZE,
        "page_count": len(pages),
        "base_page_index": 0,
        "runtime_page_index": 1,
        "cold_page_count": len(cold_pages),
        "cold_page_range": [2, 2 + len(cold_pages)],
        "asset_page_count": len(asset_pages),
        "asset_page_range": [2 + len(cold_pages), len(pages)],
        "gfx_page_count": gfx_page_count,
        "palette_asset_index": palette_asset_index,
        "palette_length": palette_length,
        "asset_page_table": asset_page_table,
        "palette_destination": palette_destination,
        "runtime_entry": RUNTIME_ENTRY,
        "base_transition": BASE_TRANSITION,
        "runtime_page_table": RUNTIME_PAGE_TABLE,
        "image_size": len(image),
    }
    return image, description


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--loader", type=Path, required=True)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--cold-page", type=Path, action="append", default=[])
    parser.add_argument("--bank-manifest", type=Path)
    parser.add_argument("--asset-manifest", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest-out", type=Path, required=True)
    # PRELOAD publishes the asset page table and the palette staging buffer to
    # the resident runtime, so both addresses belong to the fixed WIN2 layout.
    # Read them from the generated include rather than repeating them here.
    parser.add_argument("--layout-inc", type=Path, required=True)
    args = parser.parse_args()

    try:
        loader = args.loader.read_bytes()
        if not loader:
            raise ValueError("PRELOAD loader is empty")
        base = require_page(args.base, allow_short=True)
        runtime = require_page(args.runtime, allow_short=True)
        if args.bank_manifest and args.cold_page:
            raise ValueError("use either --bank-manifest or --cold-page, not both")
        if args.bank_manifest:
            bank_manifest = json.loads(args.bank_manifest.read_text(encoding="utf-8"))
            cold_paths = [Path(value) for value in bank_manifest["pages"]]
        else:
            cold_paths = args.cold_page
        cold_pages = [require_page(path, allow_short=False) for path in cold_paths]
        asset_pages: list[bytes] = []
        asset_manifest: dict[str, object] = {}
        if args.asset_manifest:
            asset_manifest = json.loads(args.asset_manifest.read_text(encoding="utf-8"))
            asset_paths = [Path(value) for value in asset_manifest["page_files"]]
            asset_pages = [require_page(path, allow_short=False) for path in asset_paths]
            if int(asset_manifest["page_count"]) != len(asset_pages):
                raise ValueError("asset manifest page count is stale")
        palette = asset_manifest.get("palette", {})
        if not isinstance(palette, dict):
            raise ValueError("asset palette descriptor is invalid")
        image, description = build_monoblock(
            loader, base, runtime, cold_pages, asset_pages,
            gfx_page_count=int(asset_manifest.get("gfx_page_count", 0)),
            palette_asset_index=int(palette.get("page_index", 0)),
            palette_length=int(palette.get("gameplay_profile", {}).get("length", 0)),
            asset_page_table=layout_symbol(
                args.layout_inc, "SPRINTER_ASSET_PAGE_TABLE") if asset_pages else 0,
            palette_destination=layout_symbol(
                args.layout_inc, "SPRINTER_GFX_PALETTE") if asset_pages else 0,
        )
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f"make_sprinter_exe: {exc}") from exc

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.manifest_out.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    args.manifest_out.write_text(
        json.dumps(description, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"[OK] Sprinter PRELOAD monoblock: {len(cold_pages)} cold bank(s), "
        f"{len(asset_pages)} asset page(s), "
        f"{len(image)} bytes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
