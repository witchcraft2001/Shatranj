#!/usr/bin/env python3
"""Pixel and page-boundary checks for the added render assets."""
import sys
import unittest
import subprocess
import tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import build_sprinter_render_assets as render
import build_sprinter_piece_tiles as tiles


class RenderAssets(unittest.TestCase):
    def test_all_108_cells_preserve_existing_piece_pixels_and_margins(self):
        pages,locations,empty,bands=render.build_cells()
        palette=tiles.gsp.load_palette_file(tiles.DEFAULT_PALETTE)
        sets=[s['name'] for s in palette['piece_sets']]
        old,info=tiles.build_pages(tiles.DEFAULT_PIECES_ROOT,sets,palette,40,20)
        self.assertEqual(len(pages),4)
        for ordinal,(page,offset) in enumerate(locations):
            self.assertLessEqual(offset+576,16384)
            cell=pages[page-12][offset:offset+576]
            group,bg=divmod(ordinal,3)
            set_index,piece=divmod(group,12)
            location=info['sets'][set_index]['groups'][piece]
            old_page=tiles.ASSET_PAGE_INDICES.index(location['asset_page_index'])
            old_offset=(location['slot_base']+bg*tiles.TILE_SLOTS)*256
            tile=old[old_page][old_offset:old_offset+400]
            fill=(2,3,8)[bg]*17
            for row in range(24):
                expected=bytes([fill])*24 if row<2 or row>=22 else bytes([fill])*2+tile[(row-2)*20:(row-1)*20]+bytes([fill])*2
                self.assertEqual(cell[row*24:(row+1)*24],expected,(ordinal,row))
        for (page,off),bg in zip(empty,(2,3,8)):
            self.assertEqual(pages[page-12][off:off+576],bytes([bg*17])*576)
        for row,(page,off) in enumerate(bands):
            self.assertEqual(pages[page-12][off:off+192],b''.join(bytes([((col+row)%2+2)*17])*24 for col in range(8)))

    def test_ensure_preserves_valid_outputs_and_repairs_missing_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)
            command=[sys.executable,str(ROOT/'tools/build_sprinter_render_assets.py'),
                     '--out-dir',str(out),'--ensure','--inputs',
                     str(ROOT/'tools/build_sprinter_render_assets.py')]
            subprocess.run(command,cwd=ROOT,check=True,capture_output=True)
            paths=[p for p in out.rglob('*') if p.is_file()]
            before={p:p.stat().st_mtime_ns for p in paths}
            result=subprocess.run(command,cwd=ROOT,check=True,capture_output=True)
            self.assertEqual(result.stdout,b'')
            self.assertEqual(before,{p:p.stat().st_mtime_ns for p in paths})
            missing=out/'glyph_page1.bin'
            expected=missing.read_bytes()
            missing.unlink()
            subprocess.run(command,cwd=ROOT,check=True,capture_output=True)
            self.assertEqual(missing.read_bytes(),expected)

    def test_precoloured_glyphs_and_direct_offset_formula(self):
        font=(ROOT/'extern/sprinter-libs/afnt640/font.bin').read_bytes()
        pages,offsets,used,cut,pad,length=render.build_fonts(font)
        self.assertLessEqual(used,32768)
        for attr_index,attr in enumerate(render.ATTRS):
            for ch in range(256):
                original=font[256+ch]+font[512+ch]*256
                size=font[ch]*8
                address=original+attr_index*length-768
                if address>=cut: address+=pad
                self.assertEqual(address,offsets[attr_index][ch])
                self.assertEqual(address//16384,(address+size-1)//16384)
                fg,bg=(attr&15)*17,(attr>>4)*17
                expected=bytes((v&(fg^bg))^bg for v in font[original:original+size])
                self.assertEqual(pages[address//16384][address%16384:address%16384+size],expected)

if __name__=='__main__': unittest.main()
