#!/usr/bin/env python3
"""Package the Sprinter real-hardware test kit: EXE + both uNet DLLs.

Real Sprinter hardware does not consume the FAT12 smoke image the way MAME
mounts it, so hardware testing gets the same bytes in a different container:
the three files flat in one archive, to be unpacked into a single directory
(l_load resolves the DLL next to the EXE through DSS APPINFO, not PATH and
not the current directory).

The archive always lands at build/sprinter/SHATRANJ-HW.zip -- one fixed,
predictable path, never a scratch directory.  Like the smoke image it is
deterministic (fixed member timestamps, no host paths) and it prints the
SHA-256 of every member so build reports can quote them and the running
build is never in question.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import zipfile

# Same instant as the smoke image's staged files, for the same reason.
ZIP_TIMESTAMP = (2025, 1, 1, 0, 0, 0)


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--dll", action="append", required=True, type=Path,
                        help="DLL to place in the archive (repeatable)")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    members = [args.exe, *args.dll]
    for src in members:
        if not src.is_file():
            fail(f"missing input: {src}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        args.output.unlink()
    with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as archive:
        for src in members:
            info = zipfile.ZipInfo(src.name.upper(), date_time=ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, src.read_bytes())

    print(f"[OK] {args.output}: {', '.join(m.name.upper() for m in members)}")
    for src in members:
        digest = hashlib.sha256(src.read_bytes()).hexdigest()
        print(f"[OK] {src.name.upper()} sha256 {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
