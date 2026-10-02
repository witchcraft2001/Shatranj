#!/usr/bin/env python3
"""Build the Sprinter test medium: a FAT12 1.44M image with EXE + DLLs.

This image (build/sprinter/SHATRANJ-SMOKE.IMG) is the MAME test medium;
hardware gets SHATRANJ-HW.zip. Every member is read back and compared with
its source; SHA-256 digests are printed so build reports can quote them.

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

VOLUME_LABEL = "SHATRANJ"
VOLUME_SERIAL = "53483031"  # 'SH01'
# FAT timestamps must be >= 1980; keep a fixed, obviously-artificial date.
FILE_TIMESTAMP = 1_735_689_600  # 2025-01-01 00:00:00 UTC


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def run_mtool(*args: str) -> str:
    env = os.environ.copy()
    env["TZ"] = "UTC"
    # mformat stamps the volume-label directory entry with wall-clock "now",
    # which -m (mtime preservation for files) does not cover.  mtools honours
    # SOURCE_DATE_EPOCH for exactly that entry, so pin it to the same instant
    # as the staged files; without it two rebuilds straddling a FAT
    # two-second tick produce byte-different images.
    env["SOURCE_DATE_EPOCH"] = str(FILE_TIMESTAMP)
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
    expected_names = {src.name.upper() for src in sources}
    if len(expected_names) != len(sources):
        fail("duplicate input filenames")

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
        # -m: preserve the staged file's mtime (pinned to FILE_TIMESTAMP
        # above). Without it mcopy stamps the FAT directory entry with
        # wall-clock "now" -- the image was silently non-deterministic
        # across rebuilds at different times of day, and a rebuilt image
        # could look like a stale one to a human inspecting it with mdir.
        run_mtool("mcopy", "-m", "-o", "-i", str(args.output),
                  str(dst), f"::{dst.name}")

    listing = run_mtool("mdir", "-b", "-i", str(args.output), "::")
    actual_names = {Path(line).name for line in listing.splitlines()}
    if actual_names != expected_names:
        fail(f"FAT12 members {sorted(actual_names)}, expected {sorted(expected_names)}")

    # Prove that both the EXE and all pinned DLLs survived packaging.
    readback = stage / "READBACK.BIN"
    digests = []
    for src in sources:
        run_mtool("mcopy", "-o", "-i", str(args.output),
                  f"::{src.name.upper()}", str(readback))
        digest = sha256(src)
        image_digest = sha256(readback)
        if digest != image_digest:
            fail(f"{src.name} inside image differs from {src}: "
                 f"{image_digest} != {digest}")
        digests.append((src.name.upper(), digest))
    shutil.rmtree(stage)

    print(f"[OK] {args.output}: FAT12 1.44M, "
          f"{', '.join(dst.name for dst in staged)}")
    for name, digest in digests:
        print(f"[OK] {name} sha256 {digest} (identical in image and source)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
