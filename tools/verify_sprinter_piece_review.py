#!/usr/bin/env python3
"""Verify MAME review pixels and summarize matched production-path probes."""
import hashlib
import json
import re
import statistics
from pathlib import Path
from PIL import Image
import build_sprinter_piece_tiles as tiles

ROOT=Path(__file__).resolve().parent.parent
BUILD=ROOT/'build/sprinter'
REVIEW=BUILD/'pieces40-mame'


def timings(phase):
    records={}
    log=(REVIEW/phase/'error.log').read_text(encoding='utf-8-sig')
    for name,repeat,event,cycles in re.findall(r'PIECE_BENCH (\w+)\.(\d+)\.(\w+) (\d+)',log):
        records.setdefault((name,repeat),{})[event]=int(cycles)
    result={}
    for name in ('tile','occupied','board','switch'):
        values=[row for (key,_),row in records.items() if key==name]
        assert len(values)==6 and all(len(row)==3 for row in values), (phase,name,values)
        result[name]={}
        for key,left,right in (('draw_ms','start','drawn'),('wait_and_sync_ms','drawn','synced'),
                               ('total_ms','start','synced')):
            numbers=[(row[right]-row[left])/21000 for row in values]
            result[name][key]={'median':statistics.median(numbers),'min':min(numbers),'max':max(numbers)}
    return result


def verify_images(palette, snaps=None):
    snaps=snaps or REVIEW/'final/snap'
    keys=['bR','bN','bB','bQ','bK','bB','bN','bR']+['bP']*8
    keys+=['.']*32+['wP']*8+['wR','wN','wB','wQ','wK','wB','wN','wR']
    checked=0
    def verify(path,name,theme,flipped=False):
        nonlocal checked
        with Image.open(path) as opened: screen=opened.convert('RGB')
        for index,key in enumerate(keys):
            if key=='.': continue
            row,col=divmod(index,8)
            display_row,display_col=(7-row,7-col) if flipped else (row,col)
            bg=tiles.gsp._parse_rgb(theme['entries'][str(2+(row+col)%2)],'theme')
            with Image.open(ROOT/'assets/sprinter/pieces'/name/(key+'.png')) as opened:
                png=opened.convert('RGBA')
            cell=Image.new('RGBA',(48,24),bg+(255,))
            cell.alpha_composite(png,(4,2))
            if flipped and (row,col)==(6,4):
                for marker in ('select','cursor'):
                    with Image.open(ROOT/'assets/sprinter/markers'/(marker+'.png')) as opened:
                        cell.alpha_composite(opened.convert('RGBA'))
            for y in range(tiles.TILE_H):
                for x in range(tiles.TILE_W):
                    expected=cell.getpixel((4+x,2+y))[:3]
                    actual=screen.getpixel((118+display_col*48+4+x,56+display_row*24+2+y))
                    assert actual==expected,(path.name,key,x,y,actual,expected)
            checked+=1
    for set_index,record in enumerate(palette['piece_sets']):
        for theme_index,theme in enumerate(palette['themes']):
            verify(snaps/f'set{set_index}-theme{theme_index}.png',record['name'],theme)
    for file in ('03-flipped.png','05-about-return.png'):
        verify(snaps/file,'totoy',palette['themes'][0],True)
    for file in ('08-loaded.png','09-session.png'):
        if (snaps/file).is_file():
            verify(snaps/file,palette['piece_sets'][0]['name'],palette['themes'][0])
    # Hint dots and selection survive set changes, flip and About/fade.
    for file in ('03-selected-hints.png','03-selected-new-set.png','03-flipped.png','05-about-return.png'):
        with Image.open(snaps/file) as image:
            colours=image.convert('RGB').getcolors(image.width*image.height)
            counts={colour:n for n,colour in colours}
        assert counts.get((57,193,90),0)>0, (file,'missing legal-move hints')
        assert counts.get((255,210,74),0)>0, (file,'missing selection')
    # The pre-move flash is on flipped e2 (display row 1, column 3).
    # Its whole 40x20 precomposition must match, including its background.
    png=Image.open(ROOT/'assets/sprinter/pieces/totoy/wP.png').convert('RGBA')
    matched=[]
    for file in sorted(snaps.glob('06-move-*.png')):
        with Image.open(file) as image: screen=image.convert('RGB')
        good=True
        for y in range(tiles.TILE_H):
            for x in range(tiles.TILE_W):
                pixel=png.getpixel((x,y)); expected=pixel[:3] if pixel[3] else (255,210,74)
                if screen.getpixel((118+3*48+4+x,56+1*24+2+y))!=expected:
                    good=False; break
            if not good: break
        if good: matched.append(file.name)
    assert matched,'no exact flash tile captured'
    return {'piece_rectangles':checked,'piece_pixels':checked*tiles.TILE_W*tiles.TILE_H,
            'flash_frames':matched,'hints_selection_flip_about':'passed'}


def main():
    palette=tiles.gsp.load_palette_file(tiles.DEFAULT_PALETTE)
    report={'clock_hz':21000000,'samples_per_scenario':6,
            'baseline':timings('baseline'),'final':timings('final'),
            'pixels':verify_images(palette),
            'exe_sha256':hashlib.sha256((ROOT/'release/Sprinter/SHATRANJ.EXE').read_bytes()).hexdigest()}
    path=REVIEW/'report.json';path.write_text(json.dumps(report,indent=2)+'\n')
    for name in report['baseline']:
        old=report['baseline'][name]['draw_ms']['median'];new=report['final'][name]['draw_ms']['median']
        print(f'{name}: {old:.4f} -> {new:.4f} ms ({(new/old-1)*100:+.2f}%), '
              f'total {report["baseline"][name]["total_ms"]["median"]:.4f} -> '
              f'{report["final"][name]["total_ms"]["median"]:.4f} ms')
    print(report['pixels']);print(path)


if __name__=='__main__': main()
