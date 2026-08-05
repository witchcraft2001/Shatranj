#!/usr/bin/env python3
"""Reject direct Sprinter disk RST calls outside the resident disk gate."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


DISK_FUNCTIONS = {
    "DSS_CREATE", "DSS_DELETE", "DSS_OPEN", "DSS_CLOSE", "DSS_READ",
    "DSS_WRITE", "DSS_MOVE_FP", "DSS_F_FIRST", "DSS_F_NEXT",
    "0X0A", "0X0E", "0X11", "0X12", "0X13", "0X14", "0X15", "0X19", "0X1A",
}


def scan(path: Path) -> list[str]:
    if path.name == "preload_loader.asm":
        return []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    failures: list[str] = []
    in_gate = False
    current_c = ""
    for lineno, raw in enumerate(lines, 1):
        code = raw.split(";", 1)[0].strip()
        if re.match(r"sprinter_disk_gate_rst:\s*$", code, re.IGNORECASE):
            in_gate = True
        if re.match(r"sprinter_disk_gate_rst_end:\s*$", code, re.IGNORECASE):
            in_gate = False
        match = re.search(r"\bLD\s+C\s*,\s*([^\s]+)", code, re.IGNORECASE)
        if match:
            current_c = match.group(1).rstrip(",").upper()
        if re.search(r"\bRST\s+(?:0X10|#10|10H)\b", code, re.IGNORECASE):
            if not in_gate and current_c in DISK_FUNCTIONS:
                failures.append(
                    f"{path}:{lineno}: direct DSS disk RST for {current_c}; use sprinter_disk_gate"
                )
            current_c = ""
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", type=Path, nargs="+")
    args = parser.parse_args()
    failures: list[str] = []
    for item in args.paths:
        paths = sorted(item.rglob("*.asm")) if item.is_dir() else [item]
        for path in paths:
            failures.extend(scan(path))
    if failures:
        for failure in failures:
            print(f"[ERR] {failure}", file=sys.stderr)
        return 1
    print("[OK] Sprinter DSS disk calls are confined to the resident gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
