#!/usr/bin/env python3
"""Merge the +pps_low cold image and the named WIN2 runtime section."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


HEADER_SIZE = 512
RUNTIME_ORG = 0x8100
STACK_TOP = 0xBFF0


def symbol(map_text: str, name: str) -> int:
    match = re.search(rf"^{re.escape(name)}\s+=\s+\$([0-9A-Fa-f]+)\b", map_text, re.MULTILINE)
    if not match:
        raise ValueError(f"missing map symbol: {name}")
    return int(match.group(1), 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cold", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--map", dest="map_file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    cold = bytearray(args.cold.read_bytes())
    runtime = args.runtime.read_bytes()
    map_text = args.map_file.read_text(encoding="utf-8")
    load_address = int.from_bytes(cold[16:18], "little")

    if cold[:3] != b"EXE" or cold[3] not in (0, 1):
        raise SystemExit("invalid DSS EXE header produced by +pps_low CRT")
    if int.from_bytes(cold[4:8], "little") != HEADER_SIZE:
        raise SystemExit("unexpected DSS EXE code offset")
    if symbol(map_text, "sprinter_runtime_start") != RUNTIME_ORG:
        raise SystemExit("SPRINTER_RUNTIME is not linked at 0x8100")
    if symbol(map_text, "sprinter_runtime_end") - RUNTIME_ORG != len(runtime):
        raise SystemExit("named runtime section size does not match the map")
    if load_address != 0x4100:
        raise SystemExit(f"unexpected +pps_low load address: 0x{load_address:04X}")

    cold[20:22] = STACK_TOP.to_bytes(2, "little")
    body = cold[HEADER_SIZE:]
    runtime_offset = RUNTIME_ORG - load_address
    if len(body) > runtime_offset:
        raise SystemExit("cold WIN1 image overlaps the WIN2 runtime")
    image = cold[:HEADER_SIZE] + body + bytes(runtime_offset - len(body)) + runtime
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
