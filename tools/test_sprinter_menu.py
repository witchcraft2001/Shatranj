#!/usr/bin/env python3
"""Run the shared menu reducer for Sprinter and the unchanged ZX/Next menu."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="shatranj-menu-") as tmp:
    for sprinter in (False, True):
        binary = str(Path(tmp) / ("sprinter" if sprinter else "spectrum"))
        command = [os.environ.get("CC", "cc"), "-Isrc", "-Ibuild/sprinter/generated",
                   "-D__z88dk_fastcall=", "-ffunction-sections", "-fdata-sections",
                   "tests/sprinter/test_menu.c", "-o", binary,
                   "-Wl,-dead_strip" if sys.platform == "darwin" else "-Wl,--gc-sections"]
        if sprinter:
            command.append("-DNETCHESSZX_SPRINTER")
        subprocess.run(command, cwd=ROOT, check=True)
        subprocess.run([binary], check=True)
print("[OK] Sprinter and ZX/Next menu order, wrap and Enter/Space actions")
