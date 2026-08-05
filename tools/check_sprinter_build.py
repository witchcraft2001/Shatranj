#!/usr/bin/env python3
"""Validate the Stage-1 Sprinter PRELOAD image, banks and WIN2 contracts."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from make_sprinter_exe import (
    BASE_TRANSITION,
    EXE_VERSION,
    HEADER_SIZE,
    LOADER_LOAD,
    LOADER_STACK,
    MANIFEST_MAGIC,
    MANIFEST_SIZE,
    PAGE_SIZE,
    RUNTIME_ENTRY,
)


def symbols(path: Path) -> dict[str, int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return {
        name: int(value, 16)
        for name, value in re.findall(
            r"^([A-Za-z_][A-Za-z0-9_]*)\s+=\s+\$([0-9A-Fa-f]+)\b",
            text,
            re.MULTILINE,
        )
    }


def fail_if(condition: bool, message: str, failures: list[str]) -> None:
    if condition:
        failures.append(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--loader-map", type=Path, required=True)
    parser.add_argument("--runtime-map", type=Path, required=True)
    parser.add_argument("--base-map", type=Path, required=True)
    parser.add_argument("--bank-manifest", type=Path, required=True)
    parser.add_argument("--monoblock-manifest", type=Path, required=True)
    parser.add_argument("--layout", type=Path, required=True)
    parser.add_argument("--release-dir", type=Path)
    args = parser.parse_args()

    data = args.exe.read_bytes()
    loader = symbols(args.loader_map)
    runtime = symbols(args.runtime_map)
    base = symbols(args.base_map)
    bank = json.loads(args.bank_manifest.read_text(encoding="utf-8"))
    mono = json.loads(args.monoblock_manifest.read_text(encoding="utf-8"))
    layout = json.loads(args.layout.read_text(encoding="utf-8"))
    failures: list[str] = []
    payload = b""

    fail_if(data[:3] != b"EXE", "missing DSS EXE signature", failures)
    fail_if(data[3] != EXE_VERSION, "DSS EXE version must be exactly 1", failures)
    fail_if(int.from_bytes(data[4:8], "little") != HEADER_SIZE,
            "DSS code offset is not 512", failures)
    loader_size = int.from_bytes(data[8:10], "little")
    for offset, expected, name in (
        (16, LOADER_LOAD, "load"),
        (18, LOADER_LOAD, "entry"),
        (20, LOADER_STACK, "stack"),
    ):
        actual = int.from_bytes(data[offset:offset + 2], "little")
        fail_if(actual != expected,
                f"header {name}=0x{actual:04X}, expected 0x{expected:04X}", failures)
    manifest_offset = HEADER_SIZE + loader_size
    fail_if(len(data) < manifest_offset + MANIFEST_SIZE,
            "EXE is truncated before the monoblock manifest", failures)
    if len(data) >= manifest_offset + MANIFEST_SIZE:
        manifest = data[manifest_offset:manifest_offset + MANIFEST_SIZE]
        fail_if(manifest[:4] != MANIFEST_MAGIC, "bad monoblock magic", failures)
        fail_if(manifest[4] != 1, "bad monoblock manifest version", failures)
        page_count = manifest[5]
        cold_count = manifest[6]
        fail_if(cold_count != page_count - 2, "bad cold-page count", failures)
        fail_if(int.from_bytes(manifest[8:10], "little") != PAGE_SIZE,
                "payload page size is not 16 KiB", failures)
        fail_if(int.from_bytes(manifest[10:12], "little") != RUNTIME_ENTRY,
                "bad runtime entry in manifest", failures)
        fail_if(int.from_bytes(manifest[12:14], "little") != BASE_TRANSITION,
                "bad base transition in manifest", failures)
        expected_size = manifest_offset + MANIFEST_SIZE + page_count * PAGE_SIZE
        fail_if(len(data) != expected_size,
                f"EXE size {len(data)} does not describe exact 16 KiB payloads ({expected_size})",
                failures)
        payload = data[manifest_offset + MANIFEST_SIZE:]
        if len(payload) >= 2 * PAGE_SIZE:
            base_page = payload[:PAGE_SIZE]
            runtime_page = payload[PAGE_SIZE:2 * PAGE_SIZE]
            transition = b"\x3E\x00\xD3\xC2\x3A\x44\x81\xD3\xE2\xC3\x40\x82"
            fail_if(base_page[:len(transition)] != transition,
                    "base transition does not patch WIN2 and restore WIN3", failures)
            fail_if(base_page[0x30:0x32] != b"HS",
                    "base WIN1 canary is missing", failures)
            fail_if(runtime_page[:257] != bytes([0x81]) * 257,
                    "IM2 vector table is not 257 bytes of 0x81", failures)
            fail_if(runtime_page[0x200] != 0xC3,
                    "fixed WIN2 overlay gate is not a JP", failures)
            gate_targets = {
                0x8200: "sprinter_overlay_exec",
                0x8203: "sprinter_overlay_exec_cached",
                0x8206: "sprinter_esx_fopen",
                0x8209: "sprinter_esx_fcreate",
                0x820C: "sprinter_esx_fread",
                0x820F: "sprinter_esx_fwrite",
                0x8212: "sprinter_esx_fclose",
                0x8215: "sprinter_esx_funlink",
                0x8218: "sprinter_esx_opendir",
                0x821B: "sprinter_esx_readdir",
                0x821E: "sprinter_far_base_probe",
                0x8221: "sprinter_puts",
                0x8224: "sprinter_fat_date",
                0x8227: "sprinter_fat_time",
                0x822A: "sprinter_noop",
                0x822D: "sprinter_noop",
                0x8230: "sprinter_noop",
                0x8233: "sprinter_noop",
                0x8236: "sprinter_clock_ready",
                0x8239: "sprinter_frame_wait",
                0x823C: "sprinter_key_poll_c",
            }
            for address, target_name in gate_targets.items():
                gate = runtime_page[address - 0x8000:address - 0x8000 + 3]
                expected_target = runtime.get(target_name)
                fail_if(
                    len(gate) != 3 or gate[0] != 0xC3 or
                    int.from_bytes(gate[1:3], "little") != expected_target,
                    f"fixed WIN2 gate 0x{address:04X} does not jump to {target_name}",
                    failures,
                )
            cached = runtime.get("sprinter_overlay_exec_cached", 0) - 0x8000
            c_abi_prefix = b"\x21\x02\x00\x39\x7E\x23\x5E\xDD\xE5\xFD\xE5"
            fail_if(runtime_page[cached:cached + len(c_abi_prefix)] != c_abi_prefix,
                    "overlay exec gate does not retain the SDCC/IY stack ABI", failures)
            entry_di = runtime.get("sprinter_overlay_entry_di", 0) - 0x8000
            fail_if(entry_di < 0 or runtime_page[entry_di:entry_di + 1] != b"\xF3",
                    "cold overlay entries do not start under DI", failures)

    fail_if(mono.get("page_count") != 2 + len(bank.get("pages", [])),
            "packer manifests disagree on page count", failures)
    fail_if(mono.get("image_size") != len(data),
            "monoblock JSON image size is stale", failures)

    fail_if(loader.get("sprinter_preload_start") != 0x8100,
            "PRELOAD loader is not linked at 0x8100", failures)
    loader_end = loader.get("sprinter_preload_end", 0)
    fail_if(loader_end - 0x8100 != loader_size,
            "PRELOAD loader header size does not match its map", failures)
    fail_if(loader_end > 0xBBF0, "PRELOAD loader enters stack reserve", failures)
    fail_if(runtime.get("sprinter_runtime_page_start") != 0x8000,
            "runtime page does not begin at 0x8000", failures)
    fail_if(runtime.get("sprinter_im2_handler") != 0x8181,
            "common IM2 handler is not at 0x8181", failures)
    fail_if(runtime.get("sprinter_runtime_start") != RUNTIME_ENTRY,
            "resident runtime does not begin at 0x8240", failures)
    fail_if(runtime.get("sprinter_runtime_end", 0) > 0xBBF0,
            "resident code enters the stack reserve", failures)
    fail_if(runtime.get("sprinter_disk_gate_rst_end", 0) -
            runtime.get("sprinter_disk_gate_rst", 0) != 1,
            "resident disk gate must contain exactly one RST instruction", failures)
    fail_if(runtime.get("_overlay_code_slot") != 0x4000,
            "Sprinter compatibility overlay lower bound is not 0x4000", failures)
    fail_if(base.get("sprinter_base_transition") != 0x4000,
            "base transition is not at 0x4000", failures)
    fail_if(base.get("sprinter_base_canary") != 0x4030,
            "base canary moved", failures)
    for name, expected in {
        "_spectrum_overlay_exec": 0x8200,
        "_spectrum_overlay_exec_cached": 0x8203,
        "_spectrum_overlay_context": 0xA000,
        "_spectrum_overlay_loaded_id": 0xA163,
        "_spectrum_fileui_count": 0xA1A7,
        "_spectrum_fileui_used_mask": 0xA159,
        "_spectrum_frame_wait": 0x8239,
        "_spectrum_key_poll": 0x823C,
    }.items():
        fail_if(runtime.get(name) != expected,
                f"Sprinter C ABI symbol {name} is not fixed at 0x{expected:04X}", failures)

    module_ids = [int(item["id"]) for item in bank.get("modules", [])]
    fail_if(module_ids != sorted(module_ids) or len(module_ids) != len(set(module_ids)),
            "bank modules are not in unique stable overlay-ID order", failures)
    for module in bank.get("modules", []):
        module_id = int(module["id"])
        base_addr = int(module["base"])
        length = int(module["length"])
        entries = [int(value) for value in module["entries"]]
        bank_index = int(module["bank"])
        payload_page = int(module["payload_page"])
        fail_if(base_addr & 1 != 0, f"module {module_id} is not 2-byte aligned", failures)
        fail_if(length <= 0 or length > 0x800,
                f"module {module_id} exceeds the 2 KiB ceiling", failures)
        fail_if(base_addr < 0x4000 or base_addr + length > 0x8000,
                f"module {module_id} leaves WIN1", failures)
        fail_if(payload_page != bank_index + 2,
                f"module {module_id} has inconsistent payload page", failures)
        fail_if(bank_index < 0 or bank_index >= len(bank.get("pages", [])),
                f"module {module_id} names a missing cold page", failures)
        for entry in entries:
            fail_if(not base_addr <= entry < base_addr + length,
                    f"module {module_id} has invalid entry 0x{entry:04X}", failures)
        if len(payload) >= (payload_page + 1) * PAGE_SIZE:
            page = payload[payload_page * PAGE_SIZE:(payload_page + 1) * PAGE_SIZE]
            offset = base_addr - 0x4000
            table_count = page[offset]
            table_entries = [
                int.from_bytes(
                    page[offset + 1 + index * 2:offset + 3 + index * 2],
                    "little",
                )
                for index in range(table_count)
            ]
            fail_if(table_count != int(module["entry_count"]) or
                    table_entries != entries,
                    f"module {module_id} entry table disagrees with the atlas", failures)

    stack_top = int(layout["stack_top"], 0)
    headroom = int(layout["stack_headroom"], 0)
    addresses = [int(value, 0) for value in layout["symbols"].values()]
    fail_if(stack_top != 0xBFF0 or headroom < 0x400,
            "stack top/headroom contract is invalid", failures)
    fail_if(max(addresses) >= stack_top - headroom,
            "fixed WIN2 state enters the 1 KiB stack headroom", failures)
    fail_if(any(address >= 0xC000 for address in addresses),
            "persistent fixed state is present in WIN3", failures)
    find_regions = [item for item in layout.get("regions", [])
                    if item.get("name") == "dss_find_buffer"]
    fail_if(len(find_regions) != 1 or int(find_regions[0]["size"], 0) < 0x100,
            "DSS DOS-name F_First buffer is smaller than 256 bytes", failures)

    fail_if(b"UNET" in data or b"GFX320.DLL" in data or b"NET=" in data,
            "Stage-1 monoblock contains a DLL/network dependency", failures)
    if args.release_dir:
        names = sorted(path.name for path in args.release_dir.iterdir() if path.is_file())
        fail_if(names != ["GFX320.DLL", "SHATRANJ.EXE"],
                f"unexpected Sprinter release artifacts: {names}", failures)

    if failures:
        for failure in failures:
            print(f"[ERR] {failure}", file=sys.stderr)
        return 1
    print("[OK] Sprinter PRELOAD, bank atlas, IM2, WIN2 map and stack gates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
