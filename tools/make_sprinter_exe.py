#!/usr/bin/env python3
"""Build a Sprinter DSS EXE from a loader, a boot manifest, a resident and
zero or more asset pages.

Header layout follows the authoritative Estex-DSS source
(Shared_Includes/constants/EXE_Header.z80), not the manual:

    0-2    'EXE' signature
    3      EXE version byte (0)
    4-7    32-bit LE offset of the code in the file (= 512, header size)
    8-9    16-bit LE primary loader size; != 0 selects the DSS PRELOAD
           path: DSS reads exactly this many bytes to LD_ADDR and jumps
           there with the EXE file handle kept open in the PSP
    10-15  reserved (zero)
    16-17  LD_ADDR  - load address of the code
    18-19  PC_REG   - entry point
    20-21  SP_REG   - initial stack pointer
    22-511 free text

The file layout beyond the header is: loader body (exactly LOADER@8
bytes; this is all DSS itself reads) + a 32-byte STM1 manifest + the raw
resident payload (resident_page_count * 16 KiB) + zero or more raw asset
pages (16 KiB each). preload_loader.asm streams all of those pages
uniformly through WIN1 (port.md section 3.2) and only tells resident and
asset pages apart via the manifest's asset-page-count field: resident
pages stream first, asset pages follow. asm/sprinter/manifest.inc defines
the exact same 32-byte v2 layout so the loader and
tests/sprinter/z80/t_manifest.asm agree byte-for-byte with this tool.

The output is a pure function of the inputs (no timestamps), so rebuilds
are byte-identical; sprinter-check's determinism check relies on it.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_sprinter_layout as gsl

EXE_SIGNATURE = b"EXE"
EXE_VERSION = 0
EXE_HEADER_SIZE = 512

LD_ADDR = 0x8100
PC_REG = 0x8100
SP_REG = 0xBFF0

# The loader body lives in WIN2 below its own stack (port.md section 3.2).
MAX_LOADER_SIZE = SP_REG - LD_ADDR

MANIFEST_SIZE = 32
MANIFEST_MAGIC = b"STM1"
MANIFEST_VERSION = 2
MANIFEST_PAYLOAD_UNIT = 256


def build_manifest(page_count: int, entry: int, payload_size: int,
                    asset_pages: int) -> bytes:
    if not (0 < page_count <= 0xFF):
        raise SystemExit(f"make_sprinter_exe: page_count {page_count} out of range")
    if not (0 <= entry <= 0xFFFF):
        raise SystemExit(f"make_sprinter_exe: entry {entry:#06x} out of range")
    if payload_size % MANIFEST_PAYLOAD_UNIT != 0:
        raise SystemExit(
            f"make_sprinter_exe: payload_size {payload_size} is not a "
            f"multiple of {MANIFEST_PAYLOAD_UNIT}"
        )
    payload_units = payload_size // MANIFEST_PAYLOAD_UNIT
    if not (0 <= payload_units <= 0xFFFF):
        raise SystemExit(
            f"make_sprinter_exe: payload_size {payload_size} does not fit "
            "the manifest's 16-bit field even in 256-byte units"
        )
    if not (0 <= asset_pages < page_count):
        raise SystemExit(
            f"make_sprinter_exe: asset_pages {asset_pages} must be less "
            f"than page_count {page_count} (at least one resident page)"
        )
    manifest = bytearray(MANIFEST_SIZE)
    manifest[0:4] = MANIFEST_MAGIC
    manifest[4] = MANIFEST_VERSION
    manifest[5] = page_count
    manifest[6:8] = entry.to_bytes(2, "little")
    manifest[8:10] = payload_units.to_bytes(2, "little")
    manifest[10] = asset_pages
    # 11-31 reserved, already zero.
    return bytes(manifest)


def build_exe(loader: bytes, resident: bytes, version: str,
              assets: list[bytes] | None = None,
              layout: dict | None = None) -> bytes:
    assets = assets or []
    if not loader:
        raise SystemExit("make_sprinter_exe: loader body is empty")
    if len(loader) > MAX_LOADER_SIZE:
        raise SystemExit(
            f"make_sprinter_exe: loader body is {len(loader)} bytes, "
            f"exceeds {MAX_LOADER_SIZE} (LD_ADDR..SP_REG)"
        )
    if not resident:
        raise SystemExit("make_sprinter_exe: resident payload is empty")

    if layout is None:
        layout = gsl.load_layout_file(Path("src/sprinter/fixed_layout.json"))
    errors = gsl.validate_layout(layout)
    if errors:
        raise SystemExit(
            "make_sprinter_exe: fixed_layout.json invalid: " + "; ".join(errors)
        )
    symbols = gsl.compute_symbols(layout)
    page_size = symbols["WIN1_END"] - symbols["RESIDENT_BASE"]
    if len(resident) % page_size != 0:
        raise SystemExit(
            f"make_sprinter_exe: resident is {len(resident)} bytes, not a "
            f"multiple of the {page_size}-byte page size"
        )
    for i, asset in enumerate(assets):
        if len(asset) != page_size:
            raise SystemExit(
                f"make_sprinter_exe: asset {i} is {len(asset)} bytes, "
                f"expected exactly {page_size} (one page)"
            )
    resident_page_count = len(resident) // page_size
    page_count = resident_page_count + len(assets)
    payload = resident + b"".join(assets)
    manifest = build_manifest(page_count, symbols["TRAMPOLINE_ADDR"], len(payload),
                              len(assets))

    header = bytearray(EXE_HEADER_SIZE)
    header[0:3] = EXE_SIGNATURE
    header[3] = EXE_VERSION
    header[4:8] = EXE_HEADER_SIZE.to_bytes(4, "little")
    header[8:10] = len(loader).to_bytes(2, "little")
    # 10-15 reserved, already zero
    header[16:18] = LD_ADDR.to_bytes(2, "little")
    header[18:20] = PC_REG.to_bytes(2, "little")
    header[20:22] = SP_REG.to_bytes(2, "little")

    info = f"Shatranj for Sprinter (Estex DSS) v{version}"
    info_bytes = info.encode("ascii")
    if len(info_bytes) > EXE_HEADER_SIZE - 22:
        raise SystemExit("make_sprinter_exe: info text does not fit the header")
    header[22:22 + len(info_bytes)] = info_bytes

    return bytes(header) + loader + manifest + payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--loader", required=True, type=Path,
                        help="raw PRELOAD loader binary assembled at LD_ADDR")
    parser.add_argument("--resident", required=True, type=Path,
                        help="raw resident image (resident_page_count * 16 KiB)")
    parser.add_argument("--assets", action="append", default=[], type=Path,
                        help="raw asset page, exactly 16 KiB (repeatable)")
    parser.add_argument("--layout", type=Path,
                        default=Path("src/sprinter/fixed_layout.json"))
    parser.add_argument("--version-file", required=True, type=Path,
                        help="project VERSION file (single source of truth)")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    loader = args.loader.read_bytes()
    resident = args.resident.read_bytes()
    assets = [path.read_bytes() for path in args.assets]
    layout = gsl.load_layout_file(args.layout)
    version = args.version_file.read_text(encoding="ascii").strip()
    if not version:
        raise SystemExit("make_sprinter_exe: VERSION file is empty")

    exe = build_exe(loader, resident, version, assets=assets, layout=layout)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(exe)
    print(f"[OK] {args.output}: {len(exe)} bytes "
          f"(header {EXE_HEADER_SIZE} + loader {len(loader)} + "
          f"manifest {MANIFEST_SIZE} + resident {len(resident)} + "
          f"{len(assets)} asset page(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
