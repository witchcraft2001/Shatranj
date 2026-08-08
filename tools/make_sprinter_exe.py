#!/usr/bin/env python3
"""Build a Sprinter DSS EXE from a raw loader body.

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

The output is a pure function of the inputs (no timestamps), so rebuilds
are byte-identical; check_sprinter_deps/S1 determinism checks rely on it.
"""

from __future__ import annotations

import argparse
from pathlib import Path

EXE_SIGNATURE = b"EXE"
EXE_VERSION = 0
EXE_HEADER_SIZE = 512

LD_ADDR = 0x8100
PC_REG = 0x8100
SP_REG = 0xBFF0

# The loader body lives in WIN2 below its own stack (port.md section 3.2).
MAX_BODY_SIZE = SP_REG - LD_ADDR


def build_exe(body: bytes, version: str) -> bytes:
    if not body:
        raise SystemExit("make_sprinter_exe: loader body is empty")
    if len(body) > MAX_BODY_SIZE:
        raise SystemExit(
            f"make_sprinter_exe: loader body is {len(body)} bytes, "
            f"exceeds {MAX_BODY_SIZE} (LD_ADDR..SP_REG)"
        )

    header = bytearray(EXE_HEADER_SIZE)
    header[0:3] = EXE_SIGNATURE
    header[3] = EXE_VERSION
    header[4:8] = EXE_HEADER_SIZE.to_bytes(4, "little")
    header[8:10] = len(body).to_bytes(2, "little")
    # 10-15 reserved, already zero
    header[16:18] = LD_ADDR.to_bytes(2, "little")
    header[18:20] = PC_REG.to_bytes(2, "little")
    header[20:22] = SP_REG.to_bytes(2, "little")

    info = f"Shatranj for Sprinter (Estex DSS) v{version}"
    info_bytes = info.encode("ascii")
    if len(info_bytes) > EXE_HEADER_SIZE - 22:
        raise SystemExit("make_sprinter_exe: info text does not fit the header")
    header[22:22 + len(info_bytes)] = info_bytes

    return bytes(header) + body


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--body", required=True, type=Path,
                        help="raw loader binary assembled at LD_ADDR")
    parser.add_argument("--version-file", required=True, type=Path,
                        help="project VERSION file (single source of truth)")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    body = args.body.read_bytes()
    version = args.version_file.read_text(encoding="ascii").strip()
    if not version:
        raise SystemExit("make_sprinter_exe: VERSION file is empty")

    exe = build_exe(body, version)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(exe)
    print(f"[OK] {args.output}: {len(exe)} bytes "
          f"(header {EXE_HEADER_SIZE} + body {len(body)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
