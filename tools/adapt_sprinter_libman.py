#!/usr/bin/env python3
"""Generate the pinned libman 1.3 sources for the Sprinter runtime."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


FILES = ("libman.asm", "libman13.asm", "libman_core.inc",
         "libman_core13.asm", "libman_state.inc")
DISK_FUNCTIONS = {0x11, 0x12, 0x13, 0x15}


def adapt(text: str) -> tuple[str, int]:
    lines = text.splitlines()
    last_function: int | None = None
    replacements = 0
    result: list[str] = []
    load = re.compile(
        r"^(?:\s*[A-Za-z_.$][A-Za-z0-9_.$]*\s*:\s*)?\s*"
        r"ld\s+(?:bc|c)\s*,\s*(?:([0-9a-f]+)h|(DSS_OPEN|DSS_CLOSE))",
        re.I,
    )
    for line in lines:
        match = load.match(line)
        if match:
            if match.group(2):
                last_function = 0x11 if match.group(2).upper() == "DSS_OPEN" else 0x12
            else:
                value = int(match.group(1), 16)
                last_function = value & 0xFF
        if re.match(r"^\s*rst\s+10h(?:\s|$)", line, re.I):
            if last_function in DISK_FUNCTIONS:
                indent = line[:len(line) - len(line.lstrip())]
                line = indent + "call    sprinter_disk_gate"
                replacements += 1
            last_function = None
        result.append(line)
    return "\n".join(result) + "\n", replacements


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    count = 0
    for name in FILES:
        text = (args.source / name).read_text(encoding="utf-8")
        if name in {"libman_core13.asm", "libman_state.inc"}:
            text, changed = adapt(text)
            count += changed
        (args.output / name).write_text(text, encoding="utf-8")
    if count != 7:
        raise SystemExit(f"adapt_sprinter_libman: expected 7 disk gates, found {count}")
    print(f"[OK] Sprinter libman adapter: {count} disk calls use the resident gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
