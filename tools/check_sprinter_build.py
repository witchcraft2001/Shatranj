#!/usr/bin/env python3
"""Validate the Stage-3 Sprinter image, resident banks and uNet contracts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

from sprinter_slow_ops import slow_ui_flags

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


EXPECTED_MODULE_IDS = list(range(15))
SLOW_MODULE_IDS = {10, 12, 13}
GATE_FIRST = 0x8200
GATE_LAST = 0x82D8


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


def resident_import_definitions(path: Path) -> dict[str, int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return {
        name: int(value, 16)
        for name, value in re.findall(
            r"^DEFC\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*0x([0-9A-Fa-f]+)\b",
            text,
            re.MULTILINE,
        )
    }


def validate_resident_imports(directory: Path, runtime: dict[str, int]) -> list[str]:
    failures: list[str] = []
    for name in ("app", "ui", "protocol"):
        path = directory / f"{name}_imports.asm"
        if not path.is_file():
            failures.append(f"missing resident import file {path}")
            continue
        for symbol, address in resident_import_definitions(path).items():
            expected = runtime.get(symbol)
            if expected is not None and address != expected:
                failures.append(
                    f"{name} resident import {symbol}=0x{address:04X}, "
                    f"final runtime has 0x{expected:04X}"
                )
    return failures


def fail_if(condition: bool, message: str, failures: list[str]) -> None:
    if condition:
        failures.append(message)


def integer(value: object) -> int:
    return int(str(value), 0)


def region(layout: dict[str, object], name: str) -> tuple[int, int]:
    records = [item for item in layout.get("regions", []) if item.get("name") == name]
    if len(records) != 1:
        raise ValueError(f"fixed layout has no unique {name!r} region")
    return integer(records[0]["address"]), integer(records[0]["size"])


def validate_assets(asset: dict[str, object], asset_pages: list[bytes],
                    failures: list[str]) -> None:
    count = int(asset.get("page_count", -1))
    gfx_count = int(asset.get("gfx_page_count", -1))
    fail_if(count != 5 or len(asset_pages) != count,
            "Sprinter asset bundle must contain exactly five pages", failures)
    fail_if(gfx_count != 4, "GFX source page count must be exactly four", failures)
    fail_if(int(asset.get("page_size", 0)) != PAGE_SIZE,
            "asset page size is not 16 KiB", failures)
    fail_if(int(asset.get("transparent_index", -1)) != 0xFF,
            "asset transparency index is not 0xFF", failures)
    records = asset.get("pages", [])
    fail_if(len(records) != len(asset_pages), "asset page records are stale", failures)
    for index, page in enumerate(asset_pages):
        fail_if(len(page) != PAGE_SIZE, f"asset page {index} is not exact", failures)
        if index < len(records):
            expected = records[index].get("sha256")
            fail_if(hashlib.sha256(page).hexdigest() != expected,
                    f"asset page {index} SHA-256 is stale", failures)
    palette = asset.get("palette", {})
    fail_if(not isinstance(palette, dict) or palette.get("encoding") != "RGB888",
            "asset palette is not RGB888", failures)
    if isinstance(palette, dict):
        fail_if(int(palette.get("page_index", -1)) != 4 or
                int(palette.get("offset", -1)) != 0 or
                int(palette.get("length", -1)) != 768,
                "palette descriptor is outside its exact page", failures)
    pieces = asset.get("pieces", {})
    for refs in pieces.get("tile_refs", {}).values() if isinstance(pieces, dict) else []:
        fail_if(any(not 0 <= int(value) < 36 for value in refs.values()),
                "piece TileRef is outside the 36-tile page", failures)
    about = asset.get("about", {})
    if isinstance(about, dict):
        refs = [int(value) for value in about.get("tile_refs", [])]
        fail_if(len(refs) != 16 * 12 or
                any((value >> 8) >= gfx_count or (value & 0xFF) >= 64 for value in refs),
                "About TileRefs leave the four GFX pages", failures)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--loader-map", type=Path, required=True)
    parser.add_argument("--runtime-map", type=Path, required=True)
    parser.add_argument("--base-map", type=Path, required=True)
    parser.add_argument("--client-data", type=Path, required=True)
    parser.add_argument("--ui-map", type=Path, required=True)
    parser.add_argument("--ui-data", type=Path, required=True)
    parser.add_argument("--protocol-map", type=Path, required=True)
    parser.add_argument("--protocol-data", type=Path, required=True)
    parser.add_argument("--resident-import-plan", type=Path, required=True)
    parser.add_argument("--bank-manifest", type=Path, required=True)
    parser.add_argument("--import-manifest", type=Path, required=True)
    parser.add_argument("--asset-manifest", type=Path, required=True)
    parser.add_argument("--monoblock-manifest", type=Path, required=True)
    parser.add_argument("--layout", type=Path, required=True)
    parser.add_argument("--release-dir", type=Path)
    args = parser.parse_args()

    data = args.exe.read_bytes()
    loader = symbols(args.loader_map)
    runtime = symbols(args.runtime_map)
    base = symbols(args.base_map)
    ui = symbols(args.ui_map)
    protocol = symbols(args.protocol_map)
    bank = json.loads(args.bank_manifest.read_text(encoding="utf-8"))
    imports = json.loads(args.import_manifest.read_text(encoding="utf-8"))
    resident_imports = json.loads(
        args.resident_import_plan.read_text(encoding="utf-8")
    )
    asset = json.loads(args.asset_manifest.read_text(encoding="utf-8"))
    mono = json.loads(args.monoblock_manifest.read_text(encoding="utf-8"))
    layout = json.loads(args.layout.read_text(encoding="utf-8"))
    failures: list[str] = []
    payload = b""
    binary_manifest = b""
    runtime_page = b""

    failures.extend(validate_resident_imports(
        args.resident_import_plan.parent / "resident_imports", runtime
    ))

    fail_if(data[:3] != b"EXE" or len(data) < HEADER_SIZE,
            "missing DSS EXE signature/header", failures)
    fail_if(data[3] != EXE_VERSION, "DSS EXE version must be exactly 1", failures)
    fail_if(int.from_bytes(data[4:8], "little") != HEADER_SIZE,
            "DSS code offset is not 512", failures)
    loader_size = int.from_bytes(data[8:10], "little")
    for offset, expected, name in (
        (16, LOADER_LOAD, "load"), (18, LOADER_LOAD, "entry"),
        (20, LOADER_STACK, "stack"),
    ):
        actual = int.from_bytes(data[offset:offset + 2], "little")
        fail_if(actual != expected,
                f"header {name}=0x{actual:04X}, expected 0x{expected:04X}", failures)

    manifest_offset = HEADER_SIZE + loader_size
    if len(data) >= manifest_offset + MANIFEST_SIZE:
        binary_manifest = data[manifest_offset:manifest_offset + MANIFEST_SIZE]
        fail_if(binary_manifest[:4] != MANIFEST_MAGIC, "bad monoblock magic", failures)
        fail_if(binary_manifest[4] != 2, "monoblock manifest is not version 2", failures)
        page_count = binary_manifest[5]
        cold_count = binary_manifest[6]
        asset_count = binary_manifest[7]
        fail_if(cold_count + asset_count != page_count - 2,
                "cold/asset page counts are inconsistent", failures)
        fail_if(int.from_bytes(binary_manifest[8:10], "little") != PAGE_SIZE,
                "payload page size is not 16 KiB", failures)
        fail_if(int.from_bytes(binary_manifest[10:12], "little") != RUNTIME_ENTRY,
                "bad runtime entry in manifest", failures)
        fail_if(int.from_bytes(binary_manifest[12:14], "little") != BASE_TRANSITION,
                "bad base transition in manifest", failures)
        fail_if(binary_manifest[20] != 2 or binary_manifest[21] != 2 + cold_count,
                "cold/asset physical ranges are inconsistent", failures)
        fail_if(binary_manifest[22] != 4 or binary_manifest[23] != 4,
                "GFX/palette page descriptors are wrong", failures)
        fail_if(int.from_bytes(binary_manifest[24:26], "little") != 768,
                "palette length is not RGB888/256", failures)
        expected_size = manifest_offset + MANIFEST_SIZE + page_count * PAGE_SIZE
        fail_if(len(data) != expected_size,
                "EXE does not contain exact 16 KiB payload pages", failures)
        payload = data[manifest_offset + MANIFEST_SIZE:]
    else:
        failures.append("EXE is truncated before the monoblock manifest")

    if len(payload) >= 2 * PAGE_SIZE:
        base_page = payload[:PAGE_SIZE]
        runtime_page = payload[PAGE_SIZE:2 * PAGE_SIZE]
        transition = b"\x3E\x00\xD3\xC2\x3A\x44\x81\xD3\xE2\xC3\x00\x85"
        fail_if(base_page[:len(transition)] != transition,
                "base transition does not enter the Stage-3 runtime", failures)
        fail_if(base_page[0x30:0x32] != b"HS", "base canary is missing", failures)
        expected_vectors = bytearray([0x81] * 257)
        fail_if(runtime_page[:257] != expected_vectors,
                "IM2 vector table does not route every source to the safe handler",
                failures)
        for address in range(GATE_FIRST, GATE_LAST + 1, 3):
            gate = runtime_page[address - 0x8000:address - 0x8000 + 3]
            target = int.from_bytes(gate[1:3], "little") if len(gate) == 3 else 0
            fail_if(len(gate) != 3 or gate[0] != 0xC3 or not 0x8000 <= target < 0xC000,
                    f"resident gate 0x{address:04X} is not a WIN2 JP", failures)
        for address, target_name in {
            0x8200: "sprinter_overlay_exec",
            0x8203: "sprinter_overlay_exec_cached",
            0x8206: "sprinter_esx_fopen",
            0x821E: "sprinter_esx_move_fp",
            0x8221: "sprinter_fat_date",
            0x8224: "sprinter_fat_time",
            0x8227: "sprinter_clock_ready",
            0x822A: "sprinter_frame_wait",
            0x822D: "_spectrum_input_poll_event",
        }.items():
            gate = runtime_page[address - 0x8000:address - 0x8000 + 3]
            fail_if(int.from_bytes(gate[1:3], "little") != runtime.get(target_name),
                    f"resident gate 0x{address:04X} misses {target_name}", failures)
        data_origin = base.get("CRT_ORG_DATA", 0)
        client_data = args.client_data.read_bytes()
        offset = data_origin - 0x8000
        fail_if(runtime_page[offset:offset + len(client_data)] != client_data,
                "split client DATA was not installed in WIN2", failures)
        for name, mapped, path in (
            ("UI", ui, args.ui_data),
            ("protocol", protocol, args.protocol_data),
        ):
            bank_data = path.read_bytes()
            data_address = mapped.get("CRT_ORG_DATA", 0)
            data_offset = data_address - 0x8000
            fail_if(runtime_page[data_offset:data_offset + len(bank_data)] != bank_data,
                    f"split {name} DATA was not installed in WIN2", failures)

    fail_if(loader.get("sprinter_preload_start") != LOADER_LOAD,
            "PRELOAD loader is not linked at 0x8100", failures)
    fail_if(loader.get("SPRINTER_RUNTIME_ENTRY") != RUNTIME_ENTRY or
            loader.get("SPRINTER_BASE_TRANSITION") != BASE_TRANSITION,
            "PRELOAD loader does not share the manifest entry constants", failures)
    loader_end = loader.get("sprinter_preload_end", 0)
    fail_if(loader_end - LOADER_LOAD != loader_size,
            "PRELOAD loader size disagrees with the EXE header", failures)
    fail_if(runtime.get("sprinter_runtime_page_start") != 0x8000 or
            runtime.get("sprinter_im2_handler") != 0x8181 or
            runtime.get("sprinter_runtime_start") != RUNTIME_ENTRY,
            "runtime/IM2 fixed entry addresses moved", failures)
    fixed_start = min(integer(item["address"]) for item in layout.get("regions", [])
                      if integer(item["address"]) >= 0x9000)
    fail_if(runtime.get("__tail", 0xC000) > fixed_start,
            "runtime code/rodata overlaps fixed WIN2 state", failures)
    fail_if(runtime.get("sprinter_disk_gate_rst_end", 0) -
            runtime.get("sprinter_disk_gate_rst", 0) != 1,
            "resident disk gate must contain exactly one RST instruction", failures)

    fail_if(not 0x4100 <= base.get("_main", 0) < 0x8000 or
            runtime.get("sprinter_app_main") != base.get("_main"),
            "runtime does not call the direct resident app entry", failures)
    data_start, data_capacity = region(layout, "base_data")
    bss_start, bss_capacity = region(layout, "base_bss")
    fail_if(base.get("CRT_ORG_CODE") != 0x4100 or
            base.get("__CODE_END_tail", 0x8001) > 0x8000,
            "app resident CODE leaves WIN1", failures)
    fail_if(base.get("CRT_ORG_DATA") != data_start or
            base.get("__DATA_END_tail", 0) > data_start + data_capacity,
            "client DATA leaves its fixed WIN2 region", failures)
    fail_if(base.get("__rodata_compiler_size", -1) != 0,
            "app compiler constants remain in pageable WIN1", failures)
    fail_if(base.get("CRT_ORG_BSS") != bss_start or
            base.get("__BSS_END_tail", 0) > bss_start + bss_capacity,
            "client BSS leaves its fixed WIN2 region", failures)
    for name, mapped, data_region, bss_region in (
        ("UI", ui, "ui_data", "ui_bss"),
        ("protocol", protocol, "protocol_data", "protocol_bss"),
    ):
        mapped_data, data_size = region(layout, data_region)
        mapped_bss, bss_size = region(layout, bss_region)
        fail_if(mapped.get("CRT_ORG_CODE") != 0x4000 or
                mapped.get("__CODE_END_tail", 0x8001) > 0x8000,
                f"{name} resident CODE leaves WIN1", failures)
        fail_if(mapped.get("CRT_ORG_DATA") != mapped_data or
                mapped.get("__DATA_END_tail", 0) > mapped_data + data_size,
                f"{name} DATA leaves its fixed WIN2 region", failures)
        fail_if(mapped.get("CRT_ORG_BSS") != mapped_bss or
                mapped.get("__BSS_END_tail", 0) > mapped_bss + bss_size,
                f"{name} BSS leaves its fixed WIN2 region", failures)

    module_ids = [int(item["id"]) for item in bank.get("modules", [])]
    fail_if(module_ids != EXPECTED_MODULE_IDS,
            f"production cold IDs are {module_ids}, expected {EXPECTED_MODULE_IDS}", failures)
    resident_page_count = int(bank.get("resident_page_count", -1))
    cold_page_count = int(bank.get("cold_page_count", -1))
    fail_if(resident_page_count != 2 or cold_page_count < 1,
            "bank manifest must contain UI/protocol plus cold pages", failures)
    bank_pages = [Path(value).read_bytes() for value in bank.get("pages", [])]
    fail_if(len(bank_pages) != resident_page_count + cold_page_count or
            any(len(page) != PAGE_SIZE for page in bank_pages),
            "resident/cold banks are not exact 16 KiB pages", failures)
    for module in bank.get("modules", []):
        module_id = int(module["id"])
        address = int(module["base"])
        length = int(module["length"])
        entries = [int(value) for value in module["entries"]]
        fail_if(address & 1 != 0 or length <= 0 or length > 0x800 or
                address < 0x4000 or address + length > 0x8000,
                f"cold module {module_id} violates alignment/size/WIN1", failures)
        fail_if(any(not address <= entry < address + length for entry in entries),
                f"cold module {module_id} has an invalid entry", failures)
        fail_if(int(module.get("flags", -1)) !=
                (1 if module_id in SLOW_MODULE_IDS else 0),
                f"cold module {module_id} has the wrong slow-operation class",
                failures)
        fail_if(int(module.get("payload_page", -1)) < 4,
                f"cold module {module_id} overlaps a resident page", failures)

    import_ids = [int(item["id"]) for item in imports.get("modules", [])]
    fail_if(import_ids != EXPECTED_MODULE_IDS,
            "cold import manifest does not cover the production atlas", failures)
    for module in imports.get("modules", []):
        for item in module.get("imports", []):
            address = int(item.get("address", 0))
            fail_if(not 0x8000 <= address < 0xC000,
                    f"module {module['id']} import {item.get('symbol')} is outside WIN2",
                    failures)
            thunk_limit = 0xA000 + len(resident_imports.get("exports", [])) * 8
            fail_if(item.get("kind") != "far" and
                    0xA000 <= address < thunk_limit,
                    f"module {module['id']} import {item.get('symbol')} "
                    "enters a resident page gate from a cold bank", failures)
            fail_if(int(module["id"]) in SLOW_MODULE_IDS and
                    item.get("symbol") == "_spectrum_net_background_drain",
                    f"slow module {module['id']} can RECV while RX is paused",
                    failures)
    plan_names = [str(item.get("name")) for item in resident_imports.get("banks", [])]
    fail_if(plan_names != ["app", "ui", "protocol"],
            "resident import plan does not cover app/UI/protocol in order", failures)
    fail_if(not 0x8000 <= runtime.get("_sprinter_cold_text", 0) < 0xC000,
            "cold text bridge is not resident in WIN2", failures)
    for item in resident_imports.get("exports", []):
        expected_flags = (slow_ui_flags(str(item["symbol"]))
                          if str(item["bank"]) == "ui" else 0)
        fail_if(int(item.get("flags", -1)) != expected_flags,
                f"resident UI gate {item['symbol']} has the wrong slow class",
                failures)
    for module in imports.get("modules", []):
        for item in module.get("imports", []):
            if item.get("kind") == "far":
                fail_if(int(item.get("flags", -1)) !=
                        slow_ui_flags(str(item["symbol"])),
                        f"cold UI gate {item['symbol']} has the wrong slow class",
                        failures)
    if runtime_page:
        gate = runtime.get("sprinter_resident_call", 0)
        resident_maps = {"app": base, "ui": ui, "protocol": protocol}
        for index, item in enumerate(resident_imports.get("exports", [])):
            address = 0xA000 + index * 8
            target = resident_maps[str(item["bank"])].get(str(item["symbol"]), 0)
            page_class = (int(item["page"]) |
                          (0x80 if int(item.get("flags", 0)) & 1 else 0))
            expected = bytes((0x3E, page_class, 0xCD,
                              gate & 0xFF, gate >> 8,
                              target & 0xFF, target >> 8, 0x00))
            actual = runtime_page[address - 0x8000:address - 0x8000 + 8]
            fail_if(actual != expected,
                    f"resident thunk {item['symbol']} does not preserve fastcall HL",
                    failures)
        far_gate = runtime.get("sprinter_far_call", 0)
        seen_far: set[int] = set()
        for module in imports.get("modules", []):
            for item in module.get("imports", []):
                if item.get("kind") != "far":
                    continue
                address = int(item["address"])
                if address in seen_far:
                    continue
                seen_far.add(address)
                target = int(item["target"])
                page_class = (int(item["page"]) |
                              (0x80 if int(item.get("flags", 0)) & 1 else 0))
                expected = bytes((0x3E, page_class, 0xCD,
                                  far_gate & 0xFF, far_gate >> 8,
                                  target & 0xFF, target >> 8, 0x00))
                actual = runtime_page[address - 0x8000:address - 0x8000 + 8]
                fail_if(actual != expected,
                        f"far thunk {item['symbol']} does not preserve fastcall HL",
                        failures)

    asset_paths = [Path(value) for value in asset.get("page_files", [])]
    asset_pages = [path.read_bytes() for path in asset_paths]
    validate_assets(asset, asset_pages, failures)
    bank_count = len(bank_pages)
    asset_start = 2 + bank_count
    for index, page in enumerate(bank_pages):
        start = (2 + index) * PAGE_SIZE
        fail_if(payload[start:start + PAGE_SIZE] != page,
                f"resident/cold payload page {index} differs from its manifest", failures)
    for index, page in enumerate(asset_pages):
        start = (asset_start + index) * PAGE_SIZE
        fail_if(payload[start:start + PAGE_SIZE] != page,
                f"asset payload page {index} differs from its manifest", failures)

    symbols_layout = {name: integer(value) for name, value in layout["symbols"].items()}
    sizes_layout = {name: integer(value) for name, value in
                    layout.get("symbol_sizes", {}).items()}
    stack_floor = integer(layout["stack_top"]) - integer(layout["stack_headroom"])
    for item in layout.get("regions", []):
        start = integer(item["address"])
        end = start + integer(item["size"])
        fail_if(start < 0x8000 or end > stack_floor,
                f"fixed region {item['name']} leaves persistent WIN2", failures)
    for name in (
        "SPRINTER_GFX_PALETTE", "SPRINTER_GFX_CONFIG", "SPRINTER_GFX_REGS",
        "SPRINTER_NET_PACKET", "SPRINTER_NET_STREAM", "SPRINTER_NET_RECV",
        "SPRINTER_NET_INFO", "SPRINTER_NET_IP", "SPRINTER_NET_ENV",
    ):
        address = symbols_layout.get(name, 0)
        fail_if(not 0x8000 <= address < 0xC000 or
                address + sizes_layout.get(name, 1) > stack_floor,
                f"{name} is not wholly resident in WIN2", failures)
        if name in runtime:
            fail_if(runtime[name] != address,
                    f"runtime {name}=0x{runtime[name]:04X}, expected fixed "
                    f"address 0x{address:04X}", failures)
    if binary_manifest:
        fail_if(int.from_bytes(binary_manifest[26:28], "little") !=
                symbols_layout.get("SPRINTER_ASSET_PAGE_TABLE") or
                int.from_bytes(binary_manifest[28:30], "little") !=
                symbols_layout.get("SPRINTER_GFX_PALETTE"),
                "asset publication addresses disagree with fixed layout", failures)

    fail_if(stack_floor != 0xBEF0 or integer(layout["stack_headroom"]) < 0x0100,
            "uNet call stack margin is below 256 bytes", failures)
    expected_pages = 2 + len(bank_pages) + len(asset_pages)
    fail_if(mono.get("page_count") != expected_pages or
            mono.get("image_size") != len(data),
            "JSON monoblock manifest is stale", failures)
    fail_if(any(value not in data for value in
                (b"GFX320.DLL", b"UNETESP.DLL", b"UNETRTL.DLL")),
            "Stage-3 runtime does not name all packaged DLLs", failures)
    fail_if(b"STAGE2_ECHO" in data or b"ECHO READY" in data,
            "production image still contains the Stage-2 echo transport", failures)
    if args.release_dir:
        names = sorted(path.name for path in args.release_dir.iterdir() if path.is_file())
        fail_if(names != ["GFX320.DLL", "SHATRANJ.EXE", "UNETESP.DLL",
                          "UNETRTL.DLL"],
                f"unexpected Sprinter release artifacts: {names}", failures)
        dependencies = json.loads(
            Path("docs/sprinter-dependencies.json").read_text(encoding="utf-8")
        )
        for name in ("GFX320.DLL", "UNETESP.DLL", "UNETRTL.DLL"):
            record = dependencies["artifacts"][name]
            artifact = args.release_dir / name
            fail_if(artifact.stat().st_size != int(record["size"]) or
                    hashlib.sha256(artifact.read_bytes()).hexdigest() != record["sha256"],
                    f"packaged {name} does not match its pinned hash", failures)

    if failures:
        for failure in failures:
            print(f"[ERR] {failure}", file=sys.stderr)
        return 1
    print("[OK] Sprinter Stage-3 EXE, uNet package, resident/cold banks and WIN2 ABI")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
