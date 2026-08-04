#!/usr/bin/env python3
"""Validate the stage-0 DSS EXE header and two-window link map."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def symbols(map_text: str) -> dict[str, int]:
    return {
        name: int(value, 16)
        for name, value in re.findall(
            r"^([A-Za-z_][A-Za-z0-9_]*)\s+=\s+\$([0-9A-Fa-f]+)\b",
            map_text,
            re.MULTILINE,
        )
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--map", dest="map_file", type=Path, required=True)
    parser.add_argument("--makefile", type=Path, default=Path("Makefile"))
    parser.add_argument("--bootstrap", type=Path, default=Path("src/sprinter/bootstrap.asm"))
    args = parser.parse_args()
    data = args.exe.read_bytes()
    table = symbols(args.map_file.read_text(encoding="utf-8"))
    failures: list[str] = []

    if data[:3] != b"EXE":
        failures.append("missing DSS EXE signature")
    if len(data) < 512 or int.from_bytes(data[4:8], "little") != 512:
        failures.append("invalid 512-byte DSS EXE header")
    if data[3] not in (0, 1):
        failures.append(f"unsupported DSS EXE header version {data[3]}")
    expected_header = {16: 0x4100, 18: 0x4100, 20: 0xBFF0}
    for offset, expected in expected_header.items():
        actual = int.from_bytes(data[offset : offset + 2], "little")
        if actual != expected:
            failures.append(f"header word @{offset}: 0x{actual:04X}, expected 0x{expected:04X}")

    ranges = {
        "sprinter_runtime": (0x8000, 0xBBF0),
        "sprinter_dll_name": (0x8000, 0xC000),
        "sprinter_register_blocks": (0x8000, 0xC000),
        "sprinter_descriptors": (0x8000, 0xC000),
        "sprinter_palette": (0x8000, 0xC000),
        "sprinter_libman": (0x8000, 0xC000),
    }
    for prefix, (low, high) in ranges.items():
        start = table.get(prefix + "_start")
        end = table.get(prefix + "_end")
        if start is None or end is None:
            failures.append(f"missing {prefix} map gate")
        elif not (low <= start < end <= high):
            failures.append(f"{prefix}: 0x{start:04X}..0x{end:04X} outside 0x{low:04X}..0x{high:04X}")
    canary = table.get("sprinter_win1_canary", -1)
    if not 0x4000 <= canary < 0x8000:
        failures.append("WIN1 canary is not in WIN1")
    if table.get("sprinter_stack_top") != 0xBFF0 or table.get("sprinter_stack_headroom", 0) < 0x400:
        failures.append("stack top/headroom contract is not published")

    make_text = args.makefile.read_text(encoding="utf-8")
    for token in (
        "+pps_low",
        "-compiler=sdcc",
        "-clib=default",
        "-Cs--reserve-regs-iy",
        "-Cs--no-reg-params",
        "-DNETCHESSZX_SPRINTER",
        "-DNETCHESSZX_SDCC_IY",
    ):
        if token not in make_text:
            failures.append(f"missing Sprinter toolchain contract token: {token}")

    bootstrap_text = args.bootstrap.read_text(encoding="utf-8")
    if "call    _dss_exit" not in bootstrap_text or "defc DSS_EXIT" in bootstrap_text:
        failures.append("bootstrap does not terminate exclusively through dss_exit")

    expected_size = 512 + (table["sprinter_runtime_end"] - 0x4100)
    if len(data) != expected_size:
        failures.append(f"EXE size {len(data)}, expected {expected_size} from map")

    if failures:
        for failure in failures:
            print(f"[ERR] {failure}", file=sys.stderr)
        return 1
    print("[OK] Sprinter DSS header, SDCC-IY flags and WIN1/WIN2 map gates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
