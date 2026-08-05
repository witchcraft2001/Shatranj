#!/usr/bin/env python3
"""Compose exact Sprinter WIN1/WIN2 pages from split z88dk sections."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


PAGE_SIZE = 0x4000
BASE_ORIGIN = 0x4000
CLIENT_ORIGIN = 0x4100
RUNTIME_ORIGIN = 0x8000


def map_value(path: Path, name: str) -> int:
    text = path.read_text(encoding="utf-8", errors="replace")
    match = re.search(
        rf"^{re.escape(name)}\s+=\s+\$([0-9A-Fa-f]+)\b", text, re.MULTILINE
    )
    if not match:
        raise ValueError(f"{path}: missing map symbol {name}")
    return int(match.group(1), 16)


def insert(page: bytearray, origin: int, address: int, data: bytes,
           name: str) -> None:
    offset = address - origin
    if offset < 0 or offset + len(data) > len(page):
        raise ValueError(f"{name} leaves its 16 KiB window")
    if any(page[offset:offset + len(data)]):
        raise ValueError(f"{name} overlaps an existing non-zero section")
    page[offset:offset + len(data)] = data


def compose(base_stub: bytes, client_code: bytes, runtime: bytes,
            client_data: bytes, client_map: Path) -> tuple[bytes, bytes]:
    if len(base_stub) != CLIENT_ORIGIN - BASE_ORIGIN:
        raise ValueError("base transition stub must be exactly 256 bytes")
    base = bytearray(PAGE_SIZE)
    runtime_page = bytearray(PAGE_SIZE)
    insert(base, BASE_ORIGIN, BASE_ORIGIN, base_stub, "base transition stub")
    insert(base, BASE_ORIGIN, CLIENT_ORIGIN, client_code, "client CODE")
    insert(runtime_page, RUNTIME_ORIGIN, RUNTIME_ORIGIN, runtime, "runtime")
    data_origin = map_value(client_map, "CRT_ORG_DATA")
    bss_origin = map_value(client_map, "CRT_ORG_BSS")
    if data_origin + len(client_data) > bss_origin:
        raise ValueError("client DATA overlaps client BSS")
    insert(runtime_page, RUNTIME_ORIGIN, data_origin, client_data, "client DATA")
    return bytes(base), bytes(runtime_page)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-stub", type=Path, required=True)
    parser.add_argument("--client-code", type=Path, required=True)
    parser.add_argument("--client-data", type=Path, required=True)
    parser.add_argument("--client-map", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--base-out", type=Path, required=True)
    parser.add_argument("--runtime-out", type=Path, required=True)
    args = parser.parse_args()
    try:
        base, runtime = compose(
            args.base_stub.read_bytes(), args.client_code.read_bytes(),
            args.runtime.read_bytes(), args.client_data.read_bytes(), args.client_map,
        )
    except (OSError, ValueError) as exc:
        raise SystemExit(f"compose_sprinter_pages: {exc}") from exc
    args.base_out.parent.mkdir(parents=True, exist_ok=True)
    args.runtime_out.parent.mkdir(parents=True, exist_ok=True)
    args.base_out.write_bytes(base)
    args.runtime_out.write_bytes(runtime)
    print("[OK] Sprinter base/runtime pages: exact 16 KiB, split DATA installed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
