#!/usr/bin/env python3
"""Compare source SVG browser renders, archived art and separate candidates."""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw
import rasterize_sprinter_pieces as r

ROOT=Path(__file__).resolve().parent.parent


def preview(old_root, new_root, output):
    output.mkdir(parents=True,exist_ok=True)
    palette=r.gsp.load_palette_file(r.DEFAULT_PALETTE)
    names=r.load_selected_sets(r.SELECTED_SETS_JSON,None)
    keys=[s+k for s in r.SIDES for k in r.PIECE_KINDS]
    sources=ROOT/'build/sprinter/preview/source1024'
    tiles={}
    for name in names:
        tiles[name]={key:Image.open(new_root/name/(key+'.png')).convert('RGBA') for key in keys}
        sheet=Image.new('RGB',(1240,690),(24,24,24)); draw=ImageDraw.Draw(sheet)
        for col,key in enumerate(keys):
            draw.text((45+col*100,3),key,fill='white')
            fitted=r.fit_to_square(Image.open(sources/(name+'_'+key+'.png')).convert('RGBA'),r.TILE_W*8)
            source=Image.new('RGBA',(384,384),(0,0,0,0)); source.alpha_composite(fitted,(32,32))
            old=Image.open(old_root/name/(key+'.png')).convert('RGBA')
            new=tiles[name][key]
            for row,img in enumerate((source,old,new)):
                if row==0:
                    cell=Image.new('RGBA',(384,384),(240,217,181,255)); cell.alpha_composite(img)
                    cell=cell.resize((96,96),Image.Resampling.LANCZOS)
                else:
                    cell=Image.new('RGBA',(48,24),(240,217,181,255))
                    cell.alpha_composite(img,((48-img.width)//2,(24-img.height)//2))
                    cell=cell.resize((96,96),Image.Resampling.NEAREST)
                sheet.paste(cell.convert('RGB'),(40+col*100,20+row*110))
                silhouette=Image.new('RGBA',img.size,(240,240,240,255)); silhouette.putalpha(img.getchannel('A'))
                if row==0:
                    cell=Image.new('RGBA',(384,384),(24,24,24,255)); cell.alpha_composite(silhouette)
                    cell=cell.resize((96,96),Image.Resampling.LANCZOS)
                else:
                    cell=Image.new('RGBA',(48,24),(24,24,24,255)); cell.alpha_composite(silhouette,((48-img.width)//2,(24-img.height)//2))
                    cell=cell.resize((96,96),Image.Resampling.NEAREST)
                sheet.paste(cell.convert('RGB'),(40+col*100,360+row*110))
        for row,label in enumerate(('SVG','OLD','NEW')):
            draw.text((2,30+row*110),label,fill='white'); draw.text((2,370+row*110),label,fill='white')
        sheet.save(output/(name+'-comparison.png'))
        # All themes, both tones and flash, at actual corrected scale + 4x.
        r.build_preview({name:tiles[name]},palette,output/(name+'-themes.png'))
        # Archived art preview uses the same cells but its own tile geometry.
        old_tiles={name:{key:Image.open(old_root/name/(key+'.png')).convert('RGBA') for key in keys}}
        r.build_preview(old_tiles,palette,output/(name+'-old-themes.png'))
    print(output)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--old-root',type=Path,default=ROOT/'build/sprinter/pieces40-baseline/pieces')
    parser.add_argument('--new-root',type=Path,default=ROOT/'build/sprinter/pieces40-candidates')
    parser.add_argument('--output',type=Path,default=ROOT/'build/sprinter/preview/pieces40')
    args=parser.parse_args(); preview(args.old_root,args.new_root,args.output)
