#!/usr/bin/env python3
"""Validate the Sprinter port's pinned submodules and prebuilt uNet DLLs.

Follows the weather-forecast check_deps.py pattern.  The gate traps loudly
on any pin drift (port.md rule R5): submodule URL/commit, DLL size+SHA-256,
the shared uNet ABI include, and the libman DLL-format verifier.
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
    "extern/libman": (
        "https://github.com/witchcraft2001/sprinter-libman.git",
        "d392c938d3235a8c6db09a5421c674631dfa1f23",
    ),
    "extern/unet_libs_asm": (
        "https://github.com/witchcraft2001/sprinter_unet_libs_asm.git",
        "8406c602b642868fbfe74cd3759ba9b758366104",
    ),
    "extern/sprinter-libs": (
        "https://github.com/witchcraft2001/sprinter-libs.git",
        "2c58d793cda75dab7e0b2d2836221f089ad8660b",
    ),
}

# Prebuilt DLLs from the pinned UNETLD core submodule.
DLLS = {
    "extern/unet_libs_asm/extern/core/dll/UNETESP.DLL": (
        15_467, "2f68f7a1b6cfa1667465944fbf970062426f7affddeb42ae9ac4d1a236a20ed7"),
    "extern/unet_libs_asm/extern/core/dll/UNETRTL.DLL": (
        18_145, "a017bb8c0de6db496092676f5ce4eb47dc5b833d812eb77bbc885bb925d17142"),
    "extern/unet_libs_asm/extern/core/dll/UNET509B.DLL": (
        23_743, "4f9d5d736f52dadeddba28db8a71f6c6e253f49da646bf17cb4b67a78b51ccb1"),
}
UNETLD_CORE_COMMIT = "8566311a53ed17f4f703d48b6aa3ec40256558a7"
UNETLD_CORE_URL = "https://github.com/witchcraft2001/unet_libs_core.git"
UNET_INC = "extern/unet_libs_asm/extern/core/bindings/asm/unet.inc"
SOURCE_HASHES = {
    "extern/unet_libs_asm/include/unetld.asm":
        "3036f3eaf771461176656e17154ebe226fedea59b10215c42f5006a749fe8066",
    UNET_INC: "48f21d3382c5c53386c0e10c2a1302df99888d783a2f9035138151aa807444dd",
}


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

    core = ROOT / "extern/unet_libs_asm/extern/core"
    core_modules = ROOT / "extern/unet_libs_asm/.gitmodules"
    if run("git", "config", "-f", str(core_modules), "--get",
           "submodule.extern/core.url") != UNETLD_CORE_URL:
        fail("UNETLD core submodule URL differs from the pinned source")
    if not core.is_dir() or run("git", "rev-parse", "HEAD", cwd=core) != UNETLD_CORE_COMMIT:
        fail("UNETLD core submodule is missing or at the wrong commit")
    if not (ROOT / UNET_INC).is_file():
        fail(f"uNet ABI include is missing: {UNET_INC}")
    for rel_path, expected_sha256 in SOURCE_HASHES.items():
        path = ROOT / rel_path
        if not path.is_file():
            fail(f"dependency source is missing: {rel_path}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected_sha256:
            fail(f"{rel_path}: SHA-256 {digest}, expected {expected_sha256}")


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
