#!/usr/bin/env python3
"""Reject unsafe cold-bank imports and persistent WIN3/shared WIN1 state."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def map_constants(path: Path) -> dict[str, int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return {
        name: int(value, 16)
        for name, value in re.findall(
            r"^([A-Za-z_][A-Za-z0-9_]*)\s+=\s+\$([0-9A-Fa-f]+)\b",
            text,
            re.MULTILINE,
        )
    }


def validate(manifest: dict[str, object], sources: list[Path]) -> list[str]:
    failures: list[str] = []
    for source in sources:
        text = source.read_text(encoding="utf-8", errors="replace")
        if re.search(r"\b(?:_?spectrum_overlay_exec(?:_cached)?)\b", text):
            failures.append(f"{source}: nested bank dispatch import")
    for module in manifest.get("modules", []):
        module_id = int(module["id"])
        base = int(module["base"])
        end = base + int(module["length"])
        path = Path(str(module["map"]))
        for name, address in map_constants(path).items():
            if name.startswith("__"):
                continue
            if 0x4000 <= address < 0x8000 and not base <= address < end:
                failures.append(
                    f"module {module_id}: direct WIN1 import {name}=0x{address:04X}; "
                    "use a generated WIN2 far-call thunk"
                )
            if address >= 0xC000:
                failures.append(
                    f"module {module_id}: persistent import {name}=0x{address:04X} is in WIN3"
                )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--source", type=Path, action="append", default=[])
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    failures = validate(manifest, args.source)
    if failures:
        for failure in failures:
            print(f"[ERR] {failure}", file=sys.stderr)
        return 1
    print("[OK] Sprinter cold imports, far thunks and nested-dispatch policy")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
