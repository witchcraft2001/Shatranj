#!/usr/bin/env python3
"""Validate the Sprinter port's pinned submodules and prebuilt uNet DLLs.

Follows the weather-forecast check_deps.py pattern.  The gate traps loudly
on any pin drift (port.md rule R5): submodule URL/commit, DLL size+SHA-256,
byte-identity of the uNet ABI include between the two backends, and the
libman DLL-format verifier.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent

SUBMODULES = {
    "extern/esp_net": (
        "https://github.com/witchcraft2001/sprinter_net.git",
        "2a36652b167b49b7ee1bb7a3251d5a7e65d68fb7",
    ),
    "extern/rtl_net": (
        "https://github.com/witchcraft2001/sprinter-rtl8019a.git",
        "6e35924466b0a03d254b003669898dc5fd5eeade",
    ),
    "extern/libman": (
        "https://github.com/witchcraft2001/sprinter-libman.git",
        "d392c938d3235a8c6db09a5421c674631dfa1f23",
    ),
    "extern/sprinter-libs": (
        "https://github.com/witchcraft2001/sprinter-libs.git",
        "2c58d793cda75dab7e0b2d2836221f089ad8660b",
    ),
}

# Prebuilt network DLLs shipped by the uNet submodules.  These are the only
# DLLs the Sprinter target uses at runtime (graphics code is copied as
# source from extern/sprinter-libs, never linked as a DLL).
DLLS = {
    "extern/esp_net/UNETESP.DLL": (
        15_956,
        "53461c766423e19db1b939312f5fa64adcc052028b9c709b3a2353d53605fd4c",
    ),
    "extern/rtl_net/UNETRTL.DLL": (
        16_384,
        "453713e40f0ee5e3b0dc3c3d5154b3bb68985f586feb3106c06dc7cc52eaf50f",
    ),
}

UNET_INC = "src/include/unet.inc"


def run(*args: str, cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            args,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (subprocess.CalledProcessError, OSError) as exc:
        detail = ""
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            detail = f": {exc.stderr.strip()}"
        fail(f"command {' '.join(args)!r} failed{detail}")
    return result.stdout.strip()


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def check_python() -> None:
    if sys.version_info < (3, 10):
        fail("Python 3.10 or newer is required")


def check_submodules(check_clean: bool) -> None:
    gitmodules = ROOT / ".gitmodules"
    if not gitmodules.is_file():
        fail(".gitmodules is missing; run git submodule update --init --recursive")

    for rel_path, (expected_url, expected_commit) in SUBMODULES.items():
        path = ROOT / rel_path
        actual_url = run(
            "git", "config", "-f", str(gitmodules),
            "--get", f"submodule.{rel_path}.url",
        )
        if actual_url != expected_url:
            fail(f"{rel_path}: URL is {actual_url!r}, expected {expected_url!r}")
        if not (path / ".git").exists():
            fail(f"{rel_path} is not initialized; run git submodule update --init --recursive")
        actual_commit = run("git", "rev-parse", "HEAD", cwd=path)
        if actual_commit != expected_commit:
            fail(f"{rel_path}: commit {actual_commit}, expected {expected_commit}")
        if check_clean and run("git", "status", "--porcelain", cwd=path):
            fail(f"{rel_path} has local changes")


def check_dlls() -> None:
    for rel_path, (expected_size, expected_sha256) in DLLS.items():
        path = ROOT / rel_path
        if not path.is_file():
            fail(f"prebuilt DLL is missing: {rel_path}")
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if len(data) != expected_size:
            fail(f"{rel_path}: size {len(data)}, expected {expected_size}")
        if digest != expected_sha256:
            fail(f"{rel_path}: SHA-256 {digest}, expected {expected_sha256}")

    inc_paths = [
        ROOT / "extern/esp_net" / UNET_INC,
        ROOT / "extern/rtl_net" / UNET_INC,
    ]
    for inc_path in inc_paths:
        if not inc_path.is_file():
            fail(f"uNet ABI include is missing: {inc_path.relative_to(ROOT)}")
    if inc_paths[0].read_bytes() != inc_paths[1].read_bytes():
        fail("uNet ABI include files in ESP and RTL submodules differ")


def verify_with_libman() -> None:
    libman_src = ROOT / "extern/libman/src"
    if not libman_src.is_dir():
        fail("extern/libman/src is missing; run git submodule update --init --recursive")
    env = os.environ.copy()
    env["PYTHONPATH"] = str(libman_src)
    for rel_path in DLLS:
        try:
            subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "sprinter_mkdll.cli",
                    "verify",
                    str(ROOT / rel_path),
                    "--target",
                    "1.3",
                ],
                check=True,
                env=env,
            )
        except (subprocess.CalledProcessError, OSError):
            fail(f"libman DLL-format verification failed for {rel_path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check-clean",
        action="store_true",
        help="also reject local changes inside submodules",
    )
    args = parser.parse_args()

    check_python()
    check_submodules(args.check_clean)
    check_dlls()
    verify_with_libman()
    print("Sprinter dependencies: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
