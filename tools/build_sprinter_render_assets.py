#!/usr/bin/env python3
"""Pack additional opaque cells and precoloured AFNT rasters, without moving assets.

HDR indices 12..15: tightly packed cells; 16: code; 17..18: glyphs;
19: empty four-entry raster cache. Total additional allocation: eight pages.
"""
import argparse
import hashlib
import json
from pathlib import Path
import build_sprinter_piece_tiles as tiles

PAGE = 16384
ATTRS = (0x01, 0x0D, 0x0B, 0x0C, 0x10)


def build_cells():
    palette = tiles.gsp.load_palette_file(tiles.DEFAULT_PALETTE)
    pages = [bytearray(PAGE) for _ in range(4)]
    locations = []
    page, offset = 0, 0
    def put(data):
        nonlocal page, offset
        if offset + len(data) > PAGE:
            page += 1
            offset = 0
        assert page < 4
        address = (12 + page, offset)
        pages[page][offset:offset+len(data)] = data
        offset += len(data)
        return address
    for name in [x['name'] for x in palette['piece_sets']]:
        refs = tiles.piece_colours(palette, name)
        for key in tiles.PIECE_ORDER:
            piece = tiles.load_and_validate_piece(tiles.DEFAULT_PIECES_ROOT/name/(key+'.png'),40,20,refs)
            for bg in (2,3,8):
                cell = tiles.Image.new('RGBA',(48,24))
                cell.alpha_composite(piece,(4,2))
                # precompose_tile needs an RGB key only to identify the background.
                raster = tiles.precompose_tile(cell,48,24,{(0,0,0):bg},(0,0,0),refs)
                locations.append(put(raster))
    empty = [put(bytes([bg*17])*576) for bg in (2,3,8)]
    bands = [put(b''.join(bytes([((col+row)%2+2)*17])*24 for col in range(8))) for row in range(2)]
    return [bytes(p) for p in pages], locations, empty, bands


def build_fonts(font):
    rasters=font[768:]
    length=len(rasters)
    glyphs=[(font[256+ch]+256*font[512+ch]-768,font[ch]*8) for ch in range(256)]
    boundary=max(off for off,size in glyphs if 2*length+off<=PAGE)
    cut=2*length+boundary
    pad=PAGE-cut
    pages=[bytearray(PAGE),bytearray(PAGE)]
    offsets=[]
    for index,attr in enumerate(ATTRS):
        fg,bg=(attr&15)*17,(attr>>4)*17
        for off,value in enumerate(rasters):
            pos=index*length+off
            if pos>=cut: pos+=pad
            pages[pos//PAGE][pos%PAGE]=(value&(fg^bg))^bg
        row=[]
        for off,size in glyphs:
            pos=index*length+off
            if pos>=cut: pos+=pad
            assert pos//PAGE==(pos+size-1)//PAGE
            row.append(pos)
        offsets.append(row)
    return [bytes(p) for p in pages],offsets,5*length+pad,cut,pad,length


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out-dir',type=Path,required=True)
    ap.add_argument('--ensure',action='store_true')
    ap.add_argument('--inputs',nargs='*',type=Path,default=[])
    args=ap.parse_args(); out=args.out_dir; out.mkdir(parents=True,exist_ok=True)
    outputs=[out/f'cell_page{i}.bin' for i in range(4)]
    outputs += [out/f'glyph_page{i}.bin' for i in range(2)] + [out/'text_cache_page.bin']
    outputs += [out/'generated'/name for name in ('glyph_layout.inc','glyph_biases.inc',
                'board_bands.inc','cell_locations.inc','glyph_locations.inc')]
    if args.ensure and not args.inputs:
        ap.error('--ensure requires --inputs to detect source changes')
    inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(set(args.inputs)) if p.is_file()}
    manifest_path=out/'render_assets_manifest.json'
    if args.ensure and manifest_path.is_file() and all(p.is_file() for p in outputs):
        try:
            previous=json.loads(manifest_path.read_text())
        except (ValueError,OSError):
            previous={}
        if previous.get('inputs')==inputs:
            return

    cells,locations,empty,bands=build_cells()
    fonts,offsets,used,cut,pad,length=build_fonts(Path('extern/sprinter-libs/afnt640/font.bin').read_bytes())
    for i,page in enumerate(cells): (out/f'cell_page{i}.bin').write_bytes(page)
    for i,page in enumerate(fonts): (out/f'glyph_page{i}.bin').write_bytes(page)
    (out/'text_cache_page.bin').write_bytes(bytes(PAGE))
    gen=out/'generated'; gen.mkdir(exist_ok=True)
    (gen/'glyph_layout.inc').write_text(f'GLYPH_PAGE_CUT EQU {cut}\nGLYPH_PAGE_PAD EQU {pad}\n')
    (gen/'glyph_biases.inc').write_text('glyph_biases: DW '+','.join(str(i*length-768) for i in range(5))+'\n')
    (gen/'board_bands.inc').write_text(''.join(f'RENDER_BAND{i}_PAGE EQU {page}\nRENDER_BAND{i}_OFFSET EQU {offset}\n' for i,(page,offset) in enumerate(bands)))
    def table(name,items):
        return name+':\n'+''.join(f'    DB {page}\n    DW {offset}\n' for page,offset in items)
    (gen/'cell_locations.inc').write_text(table('cell_locations',locations)+table('empty_locations',empty)+table('band_locations',bands))
    # Tables belong to the code page: 2560 bytes, included in its 16 KiB.
    (gen/'glyph_locations.inc').write_text('glyph_locations:\n'+''.join('    DW '+','.join(str(v) for v in row)+'\n' for row in offsets for row in (row[:128],row[128:])))
    manifest={'inputs':inputs,'additional_pages':8,'additional_bytes':8*PAGE,'cell_size':[48,24],
              'cells':locations,'empty':empty,'bands':bands,'attributes':list(ATTRS),
              'glyph_bytes_used':used,'font_sha256':hashlib.sha256(Path('extern/sprinter-libs/afnt640/font.bin').read_bytes()).hexdigest()}
    (out/'render_assets_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'[OK] render assets: 108 cells, three empty cells, two bands; glyphs {used}/32768; eight pages total')

if __name__=='__main__': main()
