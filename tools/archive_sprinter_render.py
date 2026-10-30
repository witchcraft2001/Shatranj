#!/usr/bin/env python3
"""Archive the unmodified production renderer before a comparison run."""
import hashlib
import json
import shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
BUILD=ROOT/'build/sprinter'
out=BUILD/'render-baseline'
if out.exists() and any(out.iterdir()):
    raise SystemExit('render-baseline already exists; preserve it for the matched comparison.')
platforms=[ROOT/'release/SHATRANJ.tap',ROOT/'release/SHATRANJ.OVL',ROOT/'release/SHATRANJ.DAT',ROOT/'release/Next/SHATRANJ.nex']
assert all(p.is_file() for p in platforms),'Build the ZX/Next baseline artifacts first.'
out.mkdir(parents=True,exist_ok=True)
files=[p for p in BUILD.iterdir() if p.is_file() and p.suffix in ('.bin','.sym','.map','.json')]
files.append(ROOT/'release/Sprinter/SHATRANJ.EXE')
for path in files: shutil.copy2(path,out/path.name)
(out/'zx-next-sha256.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in platforms},indent=2)+'\n')
print(f'[OK] {out}: {len(files)} release/map/asset files and ZX/Next checksums')
