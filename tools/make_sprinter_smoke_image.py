#!/usr/bin/env python3
"""Build the Sprinter test medium: a FAT12 1.44M image with EXE + DLLs.

This image (build/sprinter/SHATRANJ-SMOKE.IMG) is the ONLY artifact handed
to testers -- never loose files or system-disk copies.  After building, the
EXE is read back from the image and its SHA-256 is compared against the
release EXE; the digest is printed so build reports can quote it.

The image is deterministic: fixed volume serial, fixed file timestamps
(mtools reads source mtimes; TZ is pinned to UTC for the mtools calls).
Requires mtools (mformat, mcopy, mdir).
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

VOLUME_LABEL = "SHATRANJ"
VOLUME_SERIAL = "53483031"  # 'SH01'
# FAT timestamps must be >= 1980; keep a fixed, obviously-artificial date.
FILE_TIMESTAMP = 1_735_689_600  # 2025-01-01 00:00:00 UTC


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def run_mtool(*args: str) -> str:
    env = os.environ.copy()
    env["TZ"] = "UTC"
    try:
        result = subprocess.run(
            args, check=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env=env,
        )
    except FileNotFoundError:
        fail(f"{args[0]} is not installed or not in PATH (install mtools)")
    except subprocess.CalledProcessError as exc:
        fail(f"{' '.join(args)} failed: {exc.stderr.strip()}")
    return result.stdout


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path,
                        help="release EXE to place in the image")
    parser.add_argument("--dll", action="append", required=True, type=Path,
                        help="DLL to place in the image (repeatable)")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    sources = [args.exe, *args.dll]
    for src in sources:
        if not src.is_file():
            fail(f"missing input: {src}")

    stage = args.output.parent / "image-stage"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    staged = []
    for src in sources:
        dst = stage / src.name.upper()
        shutil.copyfile(src, dst)
        os.utime(dst, (FILE_TIMESTAMP, FILE_TIMESTAMP))
        staged.append(dst)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        args.output.unlink()
    run_mtool("mformat", "-C", "-f", "1440", "-v", VOLUME_LABEL,
              "-N", VOLUME_SERIAL, "-i", str(args.output), "::")
    for dst in staged:
        run_mtool("mcopy", "-o", "-i", str(args.output),
                  str(dst), f"::{dst.name}")

    listing = run_mtool("mdir", "-b", "-i", str(args.output), "::")
    for dst in staged:
        if not any(line.endswith(f"/{dst.name}") for line in listing.splitlines()):
            fail(f"{dst.name} is missing from the FAT12 image")

    # Read the EXE back out of the image and prove it is the release EXE.
    readback = stage / "READBACK.EXE"
    run_mtool("mcopy", "-o", "-i", str(args.output),
              f"::{args.exe.name.upper()}", str(readback))
    release_digest = sha256(args.exe)
    image_digest = sha256(readback)
    if release_digest != image_digest:
        fail(
            f"EXE inside image differs from {args.exe}: "
            f"{image_digest} != {release_digest}"
        )
    shutil.rmtree(stage)

    print(f"[OK] {args.output}: FAT12 1.44M, "
          f"{', '.join(dst.name for dst in staged)}")
    print(f"[OK] {args.exe.name} sha256 {release_digest} "
          f"(identical in image and {args.exe.parent})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
