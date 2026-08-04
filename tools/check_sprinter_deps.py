#!/usr/bin/env python3
"""Validate pinned Sprinter submodules and their committed DLL artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, check=False
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--manifest", type=Path, default=Path("docs/sprinter-dependencies.json"))
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = json.loads((root / args.manifest).read_text(encoding="utf-8"))
    failures: list[str] = []

    for name, expected in manifest["submodules"].items():
        repo = root / expected["path"]
        if not (repo / ".git").exists():
            failures.append(f"{name}: submodule is not initialized")
            continue
        try:
            actual = git(repo, "rev-parse", "HEAD")
            if actual != expected["commit"]:
                failures.append(f"{name}: commit {actual}, expected {expected['commit']}")
            if git(repo, "status", "--porcelain"):
                failures.append(f"{name}: submodule has local modifications")
        except RuntimeError as exc:
            failures.append(f"{name}: {exc}")

    sys.path.insert(0, str(root / "extern/libman/src"))
    try:
        from sprinter_mkdll.format import decode_library
    except ImportError as exc:
        failures.append(f"libman verifier unavailable: {exc}")
        decode_library = None

    for name, expected in manifest["artifacts"].items():
        path = root / expected["path"]
        if not path.is_file():
            failures.append(f"{name}: missing {expected['path']}")
            continue
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if len(data) != expected["size"]:
            failures.append(f"{name}: size {len(data)}, expected {expected['size']}")
        if digest != expected["sha256"]:
            failures.append(f"{name}: SHA-256 {digest}, expected {expected['sha256']}")
        if decode_library is not None:
            try:
                decoded = decode_library(data)
                actual_format = decoded.header.format.value.upper()
                if actual_format != expected["format"]:
                    failures.append(f"{name}: format {actual_format}, expected {expected['format']}")
            except Exception as exc:  # verifier supplies actionable format errors
                failures.append(f"{name}: libman verification failed: {exc}")

    export = root / "extern/libman/libman/z80asm/libman.asm"
    if not export.is_file():
        failures.append("libman: z80asm export is missing")

    if failures:
        for failure in failures:
            print(f"[ERR] {failure}", file=sys.stderr)
        return 1
    print("[OK] Sprinter dependency commits, DLL hashes and L0/L1 formats")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
