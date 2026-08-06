#!/usr/bin/env python3
"""Forbid application-side UART RTS/MCR flow-control manipulation."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


FORBIDDEN = re.compile(
    r"\b(?:RTS|MCR|UART_MCR|UART_RX_PAUSE|UART_RX_RESUME|16550)\b",
    re.IGNORECASE,
)
SOURCE_SUFFIXES = {".asm", ".inc", ".c", ".h"}


def source_files(paths: list[Path]) -> list[Path]:
    result: list[Path] = []
    for path in paths:
        if path.is_dir():
            result.extend(item for item in path.rglob("*")
                          if item.suffix.lower() in SOURCE_SUFFIXES)
        elif path.suffix.lower() in SOURCE_SUFFIXES:
            result.append(path)
    return sorted(set(result))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path, nargs="+")
    args = parser.parse_args()
    failures = []
    for path in source_files(args.path):
        for number, line in enumerate(path.read_text(
                encoding="utf-8", errors="replace").splitlines(), 1):
            if FORBIDDEN.search(line):
                failures.append(f"{path}:{number}: {line.strip()}")
    if failures:
        for failure in failures:
            print(f"[ERR] direct UART flow control: {failure}", file=sys.stderr)
        return 1
    print("[OK] Sprinter flow control uses only uNet RXPAUSE/RXRESUME calls")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
