#!/usr/bin/env python3
"""Rebuild the Sprinter monoblock and compare its manifest and hashes."""

from __future__ import annotations

import argparse
import hashlib
import subprocess
from pathlib import Path


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--make", default="make")
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--bank-manifest", type=Path, required=True)
    parser.add_argument("--import-manifest", type=Path, required=True)
    parser.add_argument("--asset-manifest", type=Path, required=True)
    parser.add_argument("--monoblock-manifest", type=Path, required=True)
    args = parser.parse_args()
    paths = [args.exe, args.bank_manifest, args.import_manifest,
             args.asset_manifest, args.monoblock_manifest]
    before = [path.read_bytes() for path in paths]
    subprocess.run([args.make, "exe"], cwd=args.root, check=True)
    after = [path.read_bytes() for path in paths]
    for path, old, new in zip(paths, before, after):
        if old != new:
            raise SystemExit(f"[ERR] nondeterministic Sprinter output: {path}")
    print(f"[OK] deterministic Sprinter EXE sha256={digest(after[0])}")
    print(f"[OK] deterministic bank manifest sha256={digest(after[1])}")
    print(f"[OK] deterministic import manifest sha256={digest(after[2])}")
    print(f"[OK] deterministic asset manifest sha256={digest(after[3])}")
    print(f"[OK] deterministic monoblock manifest sha256={digest(after[4])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
