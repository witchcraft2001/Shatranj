#!/usr/bin/env python3
"""Compose exact Sprinter WIN1/WIN2 pages from split z88dk sections."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


PAGE_SIZE = 0x4000
BASE_ORIGIN = 0x4000
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


def install_data(runtime_page: bytearray, data: bytes, map_path: Path,
                 name: str) -> None:
    data_origin = map_value(map_path, "CRT_ORG_DATA")
    bss_origin = map_value(map_path, "CRT_ORG_BSS")
    if data_origin + len(data) > bss_origin:
        raise ValueError(f"{name} DATA overlaps its BSS")
    insert(runtime_page, RUNTIME_ORIGIN, data_origin, data, f"{name} DATA")


def compose(base_stub: bytes, client_code: bytes, runtime: bytes,
            client_data: bytes, client_map: Path,
            extra_banks: list[tuple[str, bytes, bytes, Path]]) \
        -> tuple[bytes, bytes, list[tuple[str, bytes]]]:
    client_origin = map_value(client_map, "CRT_ORG_CODE")
    if len(base_stub) != client_origin - BASE_ORIGIN:
        raise ValueError("base transition stub does not end at client CODE")
    base = bytearray(PAGE_SIZE)
    runtime_page = bytearray(PAGE_SIZE)
    insert(base, BASE_ORIGIN, BASE_ORIGIN, base_stub, "base transition stub")
    insert(base, BASE_ORIGIN, client_origin, client_code, "client CODE")
    insert(runtime_page, RUNTIME_ORIGIN, RUNTIME_ORIGIN, runtime, "runtime")
    install_data(runtime_page, client_data, client_map, "client")
    composed_banks: list[tuple[str, bytes]] = []
    for name, code, data, map_path in extra_banks:
        page = bytearray(PAGE_SIZE)
        code_origin = map_value(map_path, "CRT_ORG_CODE")
        insert(page, BASE_ORIGIN, code_origin, code, f"{name} CODE")
        install_data(runtime_page, data, map_path, name)
        composed_banks.append((name, bytes(page)))
    return bytes(base), bytes(runtime_page), composed_banks


def parse_bank(value: str) -> tuple[str, Path, Path, Path, Path]:
    fields = value.split(":", 4)
    if len(fields) != 5:
        raise ValueError("--bank requires NAME:CODE:DATA:MAP:OUTPUT")
    return (fields[0], Path(fields[1]), Path(fields[2]), Path(fields[3]),
            Path(fields[4]))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-stub", type=Path, required=True)
    parser.add_argument("--client-code", type=Path, required=True)
    parser.add_argument("--client-data", type=Path, required=True)
    parser.add_argument("--client-map", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--base-out", type=Path, required=True)
    parser.add_argument("--runtime-out", type=Path, required=True)
    parser.add_argument("--bank", action="append", default=[])
    args = parser.parse_args()
    try:
        bank_specs = [parse_bank(value) for value in args.bank]
        base, runtime, banks = compose(
            args.base_stub.read_bytes(), args.client_code.read_bytes(),
            args.runtime.read_bytes(), args.client_data.read_bytes(), args.client_map,
            [(name, code.read_bytes(), data.read_bytes(), map_path)
             for name, code, data, map_path, _ in bank_specs],
        )
    except (OSError, ValueError) as exc:
        raise SystemExit(f"compose_sprinter_pages: {exc}") from exc
    args.base_out.parent.mkdir(parents=True, exist_ok=True)
    args.runtime_out.parent.mkdir(parents=True, exist_ok=True)
    args.base_out.write_bytes(base)
    args.runtime_out.write_bytes(runtime)
    for (_, _, _, _, output), (_, page) in zip(bank_specs, banks):
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(page)
    print(
        f"[OK] Sprinter base/runtime pages and {len(banks)} auxiliary "
        "resident bank(s): exact 16 KiB, split DATA installed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
