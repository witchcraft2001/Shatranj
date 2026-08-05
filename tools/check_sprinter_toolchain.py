#!/usr/bin/env python3
"""Probe the pinned z88dk fork and its SDCC/IY compiler contract."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zcc", required=True)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--build-dir", type=Path, required=True)
    args = parser.parse_args()

    resolved = shutil.which(args.zcc) if not os.path.isabs(args.zcc) else args.zcc
    if not resolved or not Path(resolved).is_file():
        raise SystemExit(f"[ERR] pinned Sprinter zcc not found: {args.zcc}")
    zcc = Path(resolved).resolve()
    zsdcc = zcc.with_name("z88dk-zsdcc")
    if not zsdcc.is_file() or not os.access(zsdcc, os.X_OK):
        raise SystemExit(
            f"[ERR] pinned z88dk fork lacks {zsdcc.name}: {zsdcc}\n"
            "Build zsdcc in that fork; Homebrew/system SDCC is not accepted."
        )

    args.build_dir.mkdir(parents=True, exist_ok=True)
    root = args.root.resolve()
    with tempfile.TemporaryDirectory(dir=args.build_dir) as temp_name:
        temp = Path(temp_name)
        source = temp / "sdcc_iy_probe.c"
        output = temp / "sdcc_iy_probe.o"
        source.write_text(
            "unsigned char sprinter_sdcc_iy_probe(unsigned char x) { return x + 1; }\n",
            encoding="ascii",
        )
        command = [
            str(zcc), "+z80", "-vn", "-compiler=sdcc", "-clib=sdcc_iy",
            "-Cs--reserve-regs-iy", "-Cs--no-reg-params",
            "-DNETCHESSZX_SPRINTER", "-DNETCHESSZX_SDCC_IY",
            "-c", str(source), "-o", str(output),
        ]
        subprocess.run(command, check=True)
        if not output.is_file() or output.stat().st_size == 0:
            raise SystemExit("[ERR] pinned z88dk SDCC/IY probe produced no object")
        common = [
            str(zcc), "+z80", "-vn", "-compiler=sdcc", "-clib=sdcc_iy",
            "-SO3", "-Cs--reserve-regs-iy", "-Cs--no-reg-params",
            "--opt-code-size", "--fomit-frame-pointer",
            "-DNETCHESSZX_SPRINTER", "-DNETCHESSZX_SDCC_IY",
            "-DNETCHESSZX_FIXED_LOW_RAM", f"-I{root / 'src'}",
            f"-I{args.build_dir.resolve()}", "-c",
        ]
        for relative in (
            Path("src/spectrum/overlay/saveload_ovl.c"),
            Path("src/spectrum/overlay/fileui_ovl.c"),
        ):
            object_path = temp / f"{relative.stem}.o"
            subprocess.run(
                [*common, str(root / relative), "-o", str(object_path)], check=True
            )
            if not object_path.is_file() or object_path.stat().st_size == 0:
                raise SystemExit(f"[ERR] SDCC/IY produced no object for {relative}")
    print(f"[OK] pinned z88dk SDCC/IY and Stage-2 overlay compile probe: {zcc}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
