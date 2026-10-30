#!/usr/bin/env python3
"""Verify physical asset ordering and the complete +128 KiB render budget."""
import hashlib
import json
from pathlib import Path
from gen_sprinter_platform_defs import parse_sym

ROOT=Path(__file__).resolve().parent.parent
BUILD=ROOT/'build/sprinter'
PAGE=16384
BASE=('assets_page.bin','piece_page1.bin','piece_page2.bin','ovl_win3_page.bin',
      'cold_win3_page.bin','ovl_win3_page2.bin','about_page0.bin','about_page1.bin',
      'about_page2.bin','about_page3.bin','piece_page3.bin','piece_page4.bin')
EXTRA=('cell_page0.bin','cell_page1.bin','cell_page2.bin','cell_page3.bin',
       'render_aux.bin','glyph_page0.bin','glyph_page1.bin','text_cache_page.bin')

def main():
    exe=(ROOT/'release/Sprinter/SHATRANJ.EXE').read_bytes()
    loader_size=int.from_bytes(exe[8:10],'little')
    start=512+loader_size
    manifest=exe[start:start+32]
    assert manifest[:4]==b'STM1' and manifest[4]==2,'invalid EXE manifest'
    pages,assets=manifest[5],manifest[10]
    resident=pages-assets
    assert resident==2,'resident allocation changed'
    assert assets==len(BASE)+len(EXTRA)==20,'unexpected asset-page count'
    assert len(EXTRA)*PAGE==128*1024,'additional render allocation exceeds budget'
    payload=start+32
    assert len(exe)==payload+pages*PAGE,'unexpected payload length'
    records=[]
    for index,name in enumerate(BASE+EXTRA):
        data=(BUILD/name).read_bytes()
        assert len(data)==PAGE,(name,len(data))
        off=payload+(resident+index)*PAGE
        assert exe[off:off+PAGE]==data,(index,name,'wrong HDR placement')
        records.append({'hdr_index':index,'file':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
    aux=parse_sym(BUILD/'render_aux.sym')
    used=aux['render_aux_end']-0xC000
    assert 0<used<=PAGE,'second code page overflow'
    report={'resident_pages':resident,'base_asset_pages':len(BASE),
            'additional_pages':len(EXTRA),'additional_bytes':len(EXTRA)*PAGE,
            'second_code_bytes_including_tables_and_metadata':used,
            'exe_sha256':hashlib.sha256(exe).hexdigest(),'assets':records}
    (BUILD/'render_memory_report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'[OK] render package: 20 correctly placed assets, exactly +128 KiB; second code page {used}/{PAGE} bytes')

if __name__=='__main__': main()
