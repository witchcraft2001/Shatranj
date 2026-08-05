#!/usr/bin/env python3
"""Create the Stage-1 FAT12 smoke image and its empty SYS/CONFIG directory."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    for tool in ("mformat", "mcopy", "mmd"):
        if shutil.which(tool) is None:
            raise SystemExit(f"missing mtools command: {tool}")
    for path in args.files:
        if not path.is_file():
            raise SystemExit(f"missing smoke-image input: {path}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as temp_name:
        image = Path(temp_name) / args.output.name
        subprocess.run(["mformat", "-C", "-i", str(image), "-f", "1440", "::"], check=True)
        subprocess.run(["mmd", "-i", str(image), "::SYS"], check=True)
        subprocess.run(["mmd", "-i", str(image), "::SYS/CONFIG"], check=True)
        for path in args.files:
            subprocess.run(["mcopy", "-i", str(image), "-o", str(path), f"::{path.name}"], check=True)
        image.replace(args.output)
    print(f"[OK] FAT12 Sprinter smoke image: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
