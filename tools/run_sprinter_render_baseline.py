#!/usr/bin/env python3
"""Profile the archived shipping EXE, then restore canonical current packages."""
import subprocess
from pathlib import Path
from profile_sprinter_render import prepare,report
ROOT=Path(__file__).resolve().parent.parent
release=ROOT/'release/Sprinter/SHATRANJ.EXE'
archive=ROOT/'build/sprinter/render-baseline/SHATRANJ.EXE'
if not archive.is_file(): raise SystemExit('Archive the unchanged baseline release and maps in build/sprinter/render-baseline first.')
current=release.read_bytes()
try:
    release.write_bytes(archive.read_bytes())
    subprocess.run(['make','sprinter-smoke-image'],cwd=ROOT,check=True)
    prepare('baseline')
    subprocess.run(['bash','tools/run_sprinter_render_mame.sh','render-profile-baseline'],cwd=ROOT,check=True)
    report('baseline')
finally:
    release.write_bytes(current)
    subprocess.run(['make','sprinter-smoke-image','sprinter-hw-zip'],cwd=ROOT,check=True)
