#!/usr/bin/env python3
"""Prepare reproducible MAME piece review and production-path cycle probes.

Run after `make sprinter-smoke-image`. The sole mounted test medium remains
SHATRANJ-SMOKE.IMG. Harness code lives in the inactive WIN2 overlay slot during
this diagnostic run only; no release bytes or page assignments are changed.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def symbols(path):
    return {m[1]: int(m[2], 16) for m in re.finditer(
        r'^(\S+)\s*(?:=\s*\$|:\s*EQU\s*0x)([\da-fA-F]+)', path.read_text(), re.M)}


def prepare(phase):
    build = ROOT / 'build/sprinter'
    out = build / 'pieces40-mame' / phase
    for name in ('snap', 'cfg', 'nvram', 'diff'):
        (out / name).mkdir(parents=True, exist_ok=True)
    inputs = build / 'pieces40-baseline' if phase == 'baseline' else build
    s = symbols(inputs / 'resident_c.map') | symbols(inputs / 'platform_primitives.sym')
    probe_base = s['OVL_SLOT_ADDR']
    code = bytearray()
    markers = []
    def emit(*data): code.extend(data)
    def word(n): emit(n & 255, n >> 8)
    def call(name):
        emit(0xCD); word(s[name])
    def store(name, value):
        emit(0x3E, value, 0x32); word(s[name])
    def mark(label):
        markers.append((probe_base + len(code), label)); emit(0)
    # frame_wait is patched to JP here, so preserve its caller's registers.
    emit(0xF5, 0xC5, 0xD5, 0xE5, 0xDD, 0xE5, 0xFD, 0xE5)
    # Restore its entry before invoking it from the probe.
    # Filled from CPU memory by Lua, since the platform image may have a gap.
    for i in range(3):
        emit(0x3E, 0, 0x32); word(s['frame_wait'] + i)
    patches = [9, 14, 19]  # immediate operands after the eight PUSH bytes
    for repeat in range(6):
        for scenario in ('tile', 'occupied', 'board', 'switch'):
            call('frame_wait')
            call('flip_ring_reset')
            mark(f'{scenario}.{repeat}.start')
            if scenario == 'tile':
                # Set-0 king on a light square; offsets/shape from the packer.
                manifest = json.loads((inputs / 'piece_tiles_manifest.json').read_text())
                width, height = manifest['cell']['w'], manifest['cell']['h']
                store('tile_width', width // 2); store('tile_stride', width // 2)
                store('tile_rows', height); store('tile_alias', 0x50)
                store('tile_x_byte', 10); store('tile_x_hi', 0); store('tile_y', 42)
                # Read current set's first physical page/slot from WIN2 state.
                emit(0x3A); word(0xB8D8); emit(0x32); word(s['tile_src_page'])
                emit(0x3A); word(0xB8D9); emit(0x32); word(s['tile_src_slot'])
                emit(0x2A); word(s['back_base']); emit(0x22); word(s['tile_dest_base'])
                call('gfx_draw_tile')
            elif scenario == 'occupied':
                emit(0x21, 0, 0); call('_render_square')
            elif scenario == 'board': call('_render_board_full')
            else:
                emit(0x21, 0x92, 0, 0xE5); call('_handle_menu_action'); emit(0xE1)
            mark(f'{scenario}.{repeat}.drawn')
            call('frame_wait')
            mark(f'{scenario}.{repeat}.synced')
    emit(0xFD, 0xE1, 0xDD, 0xE1, 0xE1, 0xD1, 0xC1, 0xF1, 0xC3); word(s['frame_wait'])
    assert len(code) < 0x300, 'probe must not reach persistent state'
    lua = '''if _G.pieces40_review then return end
_G.pieces40_review=true
local machine=manager.machine
local cpu=machine.devices[":maincpu"]
local mem=cpu.spaces["program"]
local screen=machine.screens[":screen"]
local fields={}
for tag, port in pairs(machine.ioport.ports) do
 if tag:find("^:kbd:") then for name, field in pairs(port.fields) do fields[name]=field end end
end
local function frames(n) for _=1,n do coroutine.yield() end end
local function press(name, shift)
 if not fields[name] then
  for key,field in pairs(fields) do
   if key:lower()==name:lower() or key:lower()=="cursor "..name:lower() then fields[name]=field; break end
  end
 end
 if not fields[name] then for key,_ in pairs(fields) do print("KEY "..key) end end
 if shift then fields["Left Shift"]:set_value(1); frames(3) end
 assert(fields[name],name):set_value(1); frames(3); fields[name]:set_value(0); frames(5)
 if shift then fields["Left Shift"]:set_value(0); frames(3) end
end
local function line(text)
 for ch in text:gmatch(".") do
  if ch:match("%l") then press(ch:upper()) elseif ch==":" then press(";",true) else press(ch) end
 end
 press("Enter")
end
local function menu(index)
 press("Tab"); for _=1,index do press("P") end; press("Enter"); frames(100)
end
local co=coroutine.create(function()
 while machine.time:as_double()<10 do frames(1) end
 line("b:\\\\shatranj.exe"); frames(3500)
 screen:snapshot("00-start.png")
'''
    lua += f'local probe_base={probe_base}\nlocal saved={{}}\nfor i=0,767 do saved[i]=mem:read_u8(probe_base+i) end\n'
    lua += 'local code={' + ','.join(map(str, code)) + '}\n'
    for i, pos in enumerate(patches):
        lua += f'code[{pos+1}]=mem:read_u8({s["frame_wait"]+i})\n'
    lua += 'for i,v in ipairs(code) do mem:write_u8(probe_base+i-1,v) end\n'
    for addr, label in markers:
        lua += f'''cpu.debug:bpset({addr},"1",'logerror "PIECE_BENCH {label} %d\\n",totalcycles;go')\n'''
    lua += f'mem:write_u8({s["frame_wait"]},0xC3); mem:write_u16({s["frame_wait"]+1},{probe_base})\n'
    lua += '''frames(600)
 screen:snapshot("01-bench-done.png")
 for i,v in pairs(saved) do mem:write_u8(probe_base+i,v) end
 local focus=0
 local function activate(index)
  press("Tab")
  while focus~=index do press("P"); focus=(focus+1)%7 end
  press("Enter"); frames(100)
 end
 for set=0,2 do
  for theme=0,4 do
   screen:snapshot(string.format("set%d-theme%d.png",set,theme))
   activate(4)
  end
  activate(5)
 end
 screen:snapshot("02-cycle-return.png")
 activate(5) -- retain MPChess through About/fade
 mem:write_u8(HINTS_ADDRESS,1)
 press("Down"); press("Down"); press("Space"); frames(100)
 screen:snapshot("03-selected-hints.png")
 activate(5) -- change set with selection/hints live
 screen:snapshot("03-selected-new-set.png")
 activate(3)
 screen:snapshot("03-flipped.png")
 activate(6); frames(200)
 screen:snapshot("04-about.png"); press("Enter"); frames(300)
 screen:snapshot("05-about-return.png")
 -- In flipped view e2 -> e4 moves down two display rows.
 press("Down"); press("Down"); press("Space")
 for i=1,12 do frames(1); screen:snapshot(string.format("06-move-%02d.png",i)) end
 frames(100); screen:snapshot("07-moved.png")
 print("Piece review complete")
 machine:exit()
end)
emu.register_frame_done(function()
 if coroutine.status(co)=="suspended" then
  local ok,err=coroutine.resume(co)
  if not ok then print("Piece review error: "..tostring(err)); machine:exit() end
 end
end)
'''
    lua = lua.replace('HINTS_ADDRESS', str(s['_netchesszx_movement_hints']))
    (out / 'review.lua').write_text(lua)
    print(out)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=('baseline','final'))
    prepare(parser.parse_args().phase)
