#!/usr/bin/env python3
"""Prepare or summarize 30 production renderer samples on the canonical image.

The diagnostic bytecode temporarily occupies OVL_SLOT and restores it before
ordinary gameplay. MAME totalcycles, at turbo 21 MHz, measures emulated time.
"""
import argparse
import hashlib
import json
import re
import statistics
import shutil
import subprocess
from pathlib import Path
from test_sprinter_piece_mame import symbols, prepare as prepare_review

ROOT=Path(__file__).resolve().parent.parent
BUILD=ROOT/'build/sprinter'
LONG='The quick brown fox jumps over the dog'
SCENARIOS=('tile','empty','occupied','cursor','selection','board','pieces','flip',
           'short','long','long_precoloured','chat','cache_first','cache_repeat','cache_evict')


def prepare(phase="final"):
    prepare_review('final')
    template=(BUILD/'pieces40-mame/final/review.lua').read_text()
    out=BUILD/('render-profile-baseline' if phase=='baseline' else 'render-profile'); out.mkdir(exist_ok=True)
    for folder in ('snap','cfg','nvram','diff'): (out/folder).mkdir(exist_ok=True)
    inputs=BUILD/'render-baseline' if phase=='baseline' else BUILD
    scenarios=tuple(n for n in SCENARIOS if not n.startswith('cache_') and n!='long_precoloured') if phase=='baseline' else SCENARIOS
    s=symbols(inputs/'resident_c.map')|symbols(inputs/'platform_primitives.sym')
    base=s['OVL_SLOT_ADDR']; limit=s['OVL_SLOT_SIZE']
    code=bytearray(); markers=[]; patches=[]; fixups=[]
    def emit(*data): code.extend(data)
    def word(n): emit(n&255,(n>>8)&255)
    def call(name): emit(0xCD); word(s[name])
    def call_aux(addr): emit(0x21); word(addr); call('render_aux_call')
    def store(name,value): emit(0x3E,value,0x32); word(s[name] if isinstance(name,str) else name)
    def hl(n): emit(0x21); word(n)
    def text_pointer(register,which):
        emit(register); fixups.append((len(code),which)); word(0)
    def mark(label): markers.append((base+len(code),label)); emit(0)
    emit(0xF5,0xC5,0xD5,0xE5,0xDD,0xE5,0xFD,0xE5)
    for i in range(3):
        emit(0x3E); patches.append((len(code),s['frame_wait']+i)); emit(0,0x32);word(s['frame_wait']+i)
    counter=base+limit-1
    def loop_start(): store(counter,30); return base+len(code)
    def loop_end(addr): hl(counter); emit(0x35,0xC2); word(addr)
    for name in scenarios:
        top=loop_start()
        call('frame_wait'); call('flip_ring_reset')
        if 'text_cache_enabled' in s:
            store('text_cache_enabled',int(name.startswith('cache_')))
            store('text_precoloured_enabled',int(name=='long_precoloured'))
        if name=='cache_first': call_aux(0xC015)
        if name in ('cursor','selection'):
            state=s['LOWRAM_RENDER_SHARED_ADDR']
            store(state+1,6 if name=='selection' else 4);store(state+2,4)
            store(state+3,255);store(state+4,255)
            store('_netchesszx_movement_hints',1)
        if name=='flip': store(s['LOWRAM_RENDER_SHARED_ADDR'],0)
        mark(name+'.start')
        if name=='tile':
            for key,val in {'tile_width':20,'tile_stride':20,'tile_rows':20,'tile_alias':0x50,
                            'tile_x_byte':10,'tile_x_hi':0,'tile_y':42}.items(): store(key,val)
            emit(0x3A);word(s['LOWRAM_PIECE_STATE_ADDR']+1);emit(0x32);word(s['tile_src_page'])
            emit(0x3A);word(s['LOWRAM_PIECE_STATE_ADDR']+2);emit(0x32);word(s['tile_src_slot'])
            emit(0x2A);word(s['back_base']);emit(0x22);word(s['tile_dest_base'])
            call('gfx_draw_tile')
        elif name in ('empty','occupied'): hl(16 if name=='empty' else 0);call('_render_square')
        elif name=='cursor': store('key_code',0x84);call('_board_cursor_move')
        elif name=='selection': store('key_code',32);call('_board_select_or_move')
        elif name=='board': call('_render_board_full')
        elif name=='pieces': hl(0x92);emit(0xE5);call('_handle_menu_action');emit(0xE1)
        elif name=='flip': call('_menu_flip_board')
        elif name=='chat': text_pointer(0x21,'long');call('_spectrum_render_input')
        else:
            if name=='cache_evict':
                # Five distinct keys cycle through a four-entry cache.
                hl(counter);emit(0x7E,0xE6,7,0xC6,65,0x32);fixups.append((len(code),'evict'));word(0)
            text_pointer(0x11,'short' if name=='short' else 'evict' if name=='cache_evict' else 'long')
            emit(0xDD,0x21);word(420);emit(0x0E,200,0x3E,1,0x2A);word(s['back_base']);call('text_print')
        mark(name+'.drawn');call('frame_wait');mark(name+'.synced');loop_end(top)
    if 'text_cache_enabled' in s: store('text_cache_enabled',0)
    for offset,value in ((0,0),(1,4),(2,4),(3,255),(4,255)):
        store(s['LOWRAM_RENDER_SHARED_ADDR']+offset,value)
    store('_netchesszx_movement_hints',0)
    call('_saveload_full_redraw')
    mark('complete')
    emit(0xFD,0xE1,0xDD,0xE1,0xE1,0xD1,0xC1,0xF1,0xC3);word(s['frame_wait'])
    strings={}
    for name,value in (('short','White'),('long',LONG),('evict',LONG)):
        strings[name]=base+len(code);code.extend(value.encode()+b'\0')
    for index,name in fixups: code[index:index+2]=strings[name].to_bytes(2,'little')
    assert len(code)<limit-1,(len(code),limit)
    lua=f'local probe_base={base}\nlocal saved={{}}\nfor i=0,{limit-1} do saved[i]=mem:read_u8(probe_base+i) end\n'
    lua+='local code={'+','.join(map(str,code))+'}\n'
    for pos,addr in patches: lua+=f'code[{pos+1}]=mem:read_u8({addr})\n'
    lua+='for i,v in ipairs(code) do mem:write_u8(probe_base+i-1,v) end\n'
    for addr,label in markers:
        lua+=f'''cpu.debug:bpset({addr},"1",'logerror "RENDER {label} %d\\n",totalcycles;go')\n'''
    lua+=f'''cpu.debug:bpset({s['flip_sync']},"1",'logerror "RENDER sync %d\\n",totalcycles;go')\n'''
    # Count actual burst lengths and CPU capture bytes in the same samples.
    for key in ('gfx_blit_common.copy_size','gfx_draw_tile.copy_size','flip_sync.copy_size','gfx_fill_rect.hfill_size',
                'gfx_fill_rect.vfill_size','gfx_hline.hfill_size'):
        if key in s:
            lua+=f'''cpu.debug:bpset({s[key]},"1",'logerror "BURST %d\\n",b@0x{s[key]+1:x};go')\n'''
    for key,operations in (('text_print.rows_general',4),('text_print.rows_black',3),('text_print.rows_precoloured',2)):
        if key in s:
            lua+=f'''cpu.debug:bpset({s[key]},"1",'logerror "TEXT {operations}\\n";go')\n'''
    if 'gfx_capture_rows.loop' in s:
        lua+=f'''cpu.debug:bpset({s['gfx_capture_rows.loop']},"1",'logerror "CPUCOPY %d\\n",b@0x{s['tile_width']:x};go')\n'''
    if phase=='baseline' and 'flip_sync.copy_size' not in s:
        lua+=f'''cpu.debug:bpset({s['flip_sync.copy_row']},"1",'logerror "CPUCOPY %d\\n",w@0x{s['flip_sync.w']:x};go')\n'''
    # Observe executed DI/EI opcodes, including nested DI, in both code
    # pages and the resident. Conditions reject data and other mapped pages.
    irq_addresses=set()
    for file,origin in (('resident.bin',0x4000),('cold_win3_page.bin',0xC000),('render_aux.bin',0xC000)):
        if (inputs/file).is_file():
            irq_addresses.update(origin+i for i,value in enumerate((inputs/file).read_bytes()) if value in (0xf3,0xfb))
    irq_lua='local function irq_probes()\n'
    for addr in sorted(irq_addresses):
        irq_lua+=f'''cpu.debug:bpset({addr},"b@pc==0xf3 || b@pc==0xfb",'logerror "IRQ %d %d %d %d\\n",totalcycles,b@pc,iff1,pc;go')\n'''
    irq_lua+='end\nirq_probes()\n'
    lua+=irq_lua
    lua+=f'mem:write_u8({s["frame_wait"]},0xC3);mem:write_u16({s["frame_wait"]+1},{base})\n'
    lua+='frames(4000)\n screen:snapshot("01-bench-done.png")\n'
    begin=template.index('local probe_base=');end=template.index(' for i,v in pairs(saved)')
    lua=template[:begin]+lua+template[end:]
    if phase=='final':
        runtime=(ROOT/'tools/sprinter_render_runtime.lua').read_text()
        def replace_symbol(match):
            name=match[1]
            return str(s[name] if name in s else s['_'+name])
        runtime=re.sub(r'SYMBOL_(\w+)',replace_symbol,runtime)
        runtime=runtime.replace('cpu.debug:bpclear()','cpu.debug:bpclear()\nirq_probes()')
        widths=list((ROOT/'extern/sprinter-libs/afnt640/font.bin').read_bytes()[:256])
        runtime=runtime.replace('FONT_WIDTHS','({'+','.join(map(str,widths))+'})')
        runtime=runtime.replace('RUNTIME_RESULTS_PATH',json.dumps(str(out/'runtime-checks.txt')))
        lua=lua.replace(' local focus=0',runtime+'\n local focus=0')
    else:
        lua=lua.replace(' local focus=0',' if true then machine:exit();return end\n local focus=0')
    (out/'review.lua').write_text(lua)
    if shutil.which('luac'):
        subprocess.run(['luac','-p',str(out/'review.lua')],check=True)
    (out/'manifest.json').write_text(json.dumps({'samples':30,'scenarios_order':scenarios,'phase':phase,'clock_hz':21000000,'long_text':LONG,
        'long_characters':len(LONG),'probe_bytes':len(code),'exe_sha256':hashlib.sha256((ROOT/'release/Sprinter/SHATRANJ.EXE').read_bytes()).hexdigest()},indent=2)+'\n')
    print(out)


def report(phase="final"):
    out=BUILD/("render-profile-baseline" if phase=="baseline" else "render-profile"); raw=(out/'error.log').read_text(encoding='utf-8-sig')
    result=json.loads((out/'manifest.json').read_text())
    expected_exe=BUILD/'render-baseline/SHATRANJ.EXE' if phase=='baseline' else ROOT/'release/Sprinter/SHATRANJ.EXE'
    assert result['exe_sha256']==hashlib.sha256(expected_exe.read_bytes()).hexdigest(),'profile EXE differs from release/archive'
    if phase=='final':
        run=(out/'run.log').read_text()
        assert 'Render runtime checks passed' in run and 'Piece review complete' in run,run[-2000:]
    records={name:[] for name in result.get('scenarios_order',SCENARIOS)}; current=None
    di_start=None; di_spans=[]
    for line in raw.splitlines():
        irq=re.search(r'IRQ (\d+) (\d+) (\d+)',line)
        if irq:
            cycles,opcode,iff=map(int,irq.groups())
            if opcode==243 and iff: di_start=cycles
            if opcode==251 and di_start is not None:
                di_spans.append((cycles-di_start)/21000+0.002);di_start=None
        m=re.search(r'RENDER (\S+) (\d+)',line)
        if m:
            event,cycles=m[1],int(m[2])
            if event=='complete': current=None;continue
            if event=='sync':
                if current and 'drawn' in current: current['sync']=cycles
                continue
            name,event=event.split('.')
            if event=='start':
                current={'start':cycles,'draw_bursts':[],'sync_bursts':[],'draw_text_ops':[],'sync_text_ops':[],'draw_cpu':[],'sync_cpu':[]};records[name].append(current)
            elif current: current[event]=cycles
        m=re.search(r'BURST (\d+)',line)
        if m and current: current['sync_bursts' if 'drawn' in current else 'draw_bursts'].append(int(m[1]) or 256)
        text_event=re.search(r'TEXT (\d+)',line)
        cpu_event=re.search(r'CPUCOPY (\d+)',line)
        if current:
            prefix='sync_' if 'drawn' in current else 'draw_'
            if text_event: current[prefix+'text_ops'].append(int(text_event[1]))
            if cpu_event: current[prefix+'cpu'].append(int(cpu_event[1]))
    result['max_di_ms']=max(di_spans) if di_spans else None
    result['di_spans']=len(di_spans)
    result['scenarios']={}
    for name,rows in records.items():
        assert len(rows)==30 and all('sync' in r and 'synced' in r for r in rows),(name,len(rows),rows[-1:])
        metrics={}
        for metric,left,right in (('draw_ms','start','drawn'),('wait_ms','drawn','sync'),('sync_ms','sync','synced'),('total_ms','start','synced')):
            values=[(r[right]-r[left])/21000 for r in rows]
            metrics[metric]={'median':statistics.median(values),'max':max(values)}
        for stage in ('draw','sync'):
            metrics[stage+'_burst_bytes']={'median':statistics.median(sum(r[stage+'_bursts']) for r in rows),'max':max(sum(r[stage+'_bursts']) for r in rows)}
            metrics[stage+'_burst_count']={'median':statistics.median(len(r[stage+'_bursts']) for r in rows),'max':max(len(r[stage+'_bursts']) for r in rows)}
        for stage in ('draw','sync'):
            metrics[stage+'_output_bytes']={'median':statistics.median(sum(r[stage+'_bursts'])+8*len(r[stage+'_text_ops']) for r in rows)}
            metrics[stage+'_accelerator_ops']={'median':statistics.median(len(r[stage+'_bursts'])+sum(r[stage+'_text_ops']) for r in rows)}
            metrics[stage+'_cpu_raster_bytes']={'median':statistics.median(sum(r[stage+'_cpu']) for r in rows)}
        result['scenarios'][name]=metrics
        print(name, ' '.join(f'{key}={metrics[key]["median"]:.3f}' for key in ('draw_ms','wait_ms','sync_ms','total_ms')))
    print('Maximum observed DI span:',result['max_di_ms'],'ms')
    if phase=='final':
        from verify_sprinter_piece_review import verify_images
        import build_sprinter_piece_tiles as tiles
        result['pixels']=verify_images(tiles.gsp.load_palette_file(tiles.DEFAULT_PALETTE),out/'snap')
        result['runtime_checks']=(out/'runtime-checks.txt').read_text().splitlines()
    result['raw']=records
    (out/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    if phase=='final':
        assert result['max_di_ms'] is not None and result['max_di_ms']<2, result['max_di_ms']


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('mode',choices=('prepare','report'));ap.add_argument('--phase',choices=('baseline','final'),default='final')
    args=ap.parse_args()
    prepare(args.phase) if args.mode=='prepare' else report(args.phase)
