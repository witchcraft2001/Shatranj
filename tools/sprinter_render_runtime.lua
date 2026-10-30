-- Executed after the timing harness and before the visual review. All CPU
-- calls run through the shipped entry points; Lua only supplies fixtures.
cpu.debug:bpclear()
local ports=cpu.spaces["io"]
local entry=SYMBOL_frame_wait
local base=SYMBOL_OVL_SLOT_ADDR
local size=SYMBOL_OVL_SLOT_SIZE
local saved_code={}
for i=0,size-1 do saved_code[i]=mem:read_u8(base+i) end
local results={}
local function put16(t,n) t[#t+1]=n%256;t[#t+1]=math.floor(n/256)%256 end
local function op(t,...) for _,v in ipairs({...}) do t[#t+1]=v end end
local function st(t,addr,value) op(t,0x3e,value,0x32);put16(t,addr) end
local function sw(t,addr,value) op(t,0x21);put16(t,value);op(t,0x22);put16(t,addr) end
local function call(t,addr) op(t,0xcd);put16(t,addr) end
local function cpu_run(body,check,prepare,during)
 local old={mem:read_u8(entry),mem:read_u8(entry+1),mem:read_u8(entry+2)}
 local code={0xf5,0xc5,0xd5,0xe5,0xdd,0xe5,0xfd,0xe5}
 for i=0,2 do st(code,entry+i,old[i+1]) end
 st(code,base+size-1,0x11)
 local ready_spin=base+#code
 op(code,0xc3);put16(code,ready_spin)
 local body_start=base+#code
 for _,v in ipairs(body) do code[#code+1]=v end
 st(code,base+size-1,0xa5)
 local spin=base+#code
 op(code,0xc3);put16(code,spin)
 local epilogue=base+#code
 op(code,0xfd,0xe1,0xdd,0xe1,0xe1,0xd1,0xc1,0xf1,0xc3);put16(code,entry)
 assert(#code<900)
 mem:write_u8(base+size-1,0)
 for i,v in ipairs(code) do mem:write_u8(base+i-1,v) end
 mem:write_u8(entry,0xc3);mem:write_u16(entry+1,base)
 local deadline=machine.time:as_double()+120
 while mem:read_u8(base+size-1)~=0x11 do
  assert(machine.time:as_double()<deadline,"runtime harness did not start")
  frames(1)
 end
 if prepare then prepare() end
 mem:write_u16(ready_spin+1,body_start)
 local tick=0
 while mem:read_u8(base+size-1)~=0xa5 do
  if during then during(tick) end
  tick=tick+1
  assert(machine.time:as_double()<deadline,"runtime harness timed out")
  frames(1)
 end
 if check then check() end
 mem:write_u16(spin+1,epilogue)
 frames(3)
 for i,v in pairs(saved_code) do mem:write_u8(base+i,v) end
end
local function vram(fn)
 local page=ports:read_u8(0xe2)
 ports:write_u8(0xe2,0x50)
 fn()
 ports:write_u8(0x89,0xc0)
 ports:write_u8(0xe2,page)
end
for _,width in ipairs({255,256,320}) do
 for direction=0,1 do
  local src=direction==0 and 0xc000 or 0xc140
  local dst=direction==0 and 0xc140 or 0xc000
  local function fixture()
   vram(function()
   for y=0,255 do
    ports:write_u8(0x89,y)
    for x=0,319 do
     mem:write_u8(src+x,(x*7+y*13+direction)%256)
     mem:write_u8(dst+x,0xee)
    end
   end
   end)
  end
  local code={}
  st(code,SYMBOL_flip_request,0)
  call(code,SYMBOL_flip_ring_reset)
  sw(code,SYMBOL_front_base,src);sw(code,SYMBOL_back_base,dst)
  sw(code,SYMBOL_flip_arg_x,0);sw(code,SYMBOL_flip_arg_w,width)
  st(code,SYMBOL_flip_arg_y,0);st(code,SYMBOL_flip_arg_h,0)
  call(code,SYMBOL_flip_log_rect);call(code,SYMBOL_flip_sync)
  cpu_run(code,function()
   vram(function()
    for y=0,255 do
     ports:write_u8(0x89,y)
     for x=0,319 do
      local expected=(x*7+y*13+direction)%256
      assert(mem:read_u8(src+x)==expected,"source changed")
      assert(mem:read_u8(dst+x)==(x<width and expected or 0xee),string.format("copy %d dir%d row%d col%d",width,direction,y,x))
     end
    end
   end)
  end,fixture)
 end
end
results.copy="255/256/320 bytes, 256 rows, both directions passed"
print(results.copy)
-- Every non-NUL glyph, all accelerated attributes and two fallback ones.
local function text_body(text,attr,y,precolour,cache,x,version)
 local t={}
 call(t,SYMBOL_flip_ring_reset)
 st(t,SYMBOL_text_precoloured_enabled,precolour)
 st(t,SYMBOL_text_cache_enabled,cache)
 st(t,SYMBOL_text_font_version,version or 0)
 op(t,0x11);put16(t,base+1024)
 op(t,0xdd,0x21);put16(t,x or 0)
 op(t,0x0e,y,0x3e,attr,0x21);put16(t,0xc000)
 call(t,SYMBOL_text_print)
 st(t,SYMBOL_text_cache_enabled,0)
 st(t,SYMBOL_text_precoloured_enabled,0)
 for i=1,#text do mem:write_u8(base+1023+i,text:byte(i)) end
 mem:write_u8(base+1024+#text,0)
 return t
end
local function raster(y,width)
 local bytes={}
 vram(function()
  for row=0,7 do
   ports:write_u8(0x89,y+row)
   for x=0,width-1 do bytes[#bytes+1]=mem:read_u8(0xc000+x) end
  end
 end)
 return bytes
end
local glyphs=0
for _,attr in ipairs({1,13,11,12,16,0x26,0xf1}) do
 for first=1,255,32 do
  local chars={};local width=0
  for ch=first,math.min(first+31,255) do chars[#chars+1]=string.char(ch);width=width+FONT_WIDTHS[ch+1] end
  local text=table.concat(chars)
  local reference
  cpu_run(text_body(text,attr,64,0,0),function() reference=raster(64,width) end)
  cpu_run(text_body(text,attr,80,1,0),function()
   local got=raster(80,width)
   for i,v in ipairs(reference) do assert(got[i]==v,"precoloured glyph mismatch") end
  end)
  cpu_run(text_body(text,attr,96,0,1),function()
   local got=raster(96,width)
   for i,v in ipairs(reference) do assert(got[i]==v,"cache miss raster mismatch") end
  end)
  cpu_run(text_body(text,attr,112,0,1),function()
   assert(mem:read_u8(SYMBOL_text_cache_hit)==1,"expected cache hit attr="..attr.." first="..first)
   local got=raster(112,width)
   for i,v in ipairs(reference) do assert(got[i]==v,"cache hit raster mismatch") end
  end)
  glyphs=glyphs+#text
 end
end
results.glyphs=tostring(glyphs).." glyph/attribute pairs, reference/precolour/cache miss/cache hit identical"
-- Clipping must preserve the whole row outside the actual output.
for _,y in ipairs({64,80,96}) do
 vram(function()
  for row=0,7 do
   ports:write_u8(0x89,y+row)
   for col=0,319 do mem:write_u8(0xc000+col,0x66) end
  end
 end)
end
local clipped
cpu_run(text_body("WWWWWWWWWW",0x26,64,0,0,620),function() clipped=raster(64,320) end)
for _,y in ipairs({80,96}) do
 cpu_run(text_body("WWWWWWWWWW",0x26,y,0,1,620),function()
  local got=raster(y,320)
  for i,v in ipairs(clipped) do assert(got[i]==v,"clipped cache raster/guard mismatch") end
 end)
end
cpu_run(text_body("WWWWWWWWWW",0x26,112,0,1,620,1),function()
 assert(mem:read_u8(SYMBOL_text_cache_hit)==0,"font generation failed to invalidate key")
end)
local clear={0x21,0x15,0xc0};call(clear,SYMBOL_render_aux_call);cpu_run(clear)
for _,text in ipairs({"cache A","cache B","cache C","cache D"}) do cpu_run(text_body(text,1,96,0,1)) end
cpu_run(text_body("cache A",1,96,0,1),function() assert(mem:read_u8(SYMBOL_text_cache_hit)==1,"LRU touch") end)
cpu_run(text_body("cache E",1,96,0,1))
cpu_run(text_body("cache A",1,96,0,1),function() assert(mem:read_u8(SYMBOL_text_cache_hit)==1,"MRU entry evicted") end)
cpu_run(text_body("cache B",1,96,0,1),function() assert(mem:read_u8(SYMBOL_text_cache_hit)==0,"LRU entry retained") end)
-- A cached key must not turn an off-screen X into a wrapped width.
vram(function()
 for row=0,7 do
  ports:write_u8(0x89,128+row)
  for col=0,639 do mem:write_u8(0xc000+col,0x66) end
 end
end)
cpu_run(text_body("cache A",1,128,0,1,642),function()
 assert(mem:read_u8(SYMBOL_text_cache_hit)==0,"off-screen cache hit")
 for _,value in ipairs(raster(128,640)) do assert(value==0x66,"off-screen text changed VRAM") end
end)
-- Mutating a font generation must also disable the immutable precolour set.
local function font_access(fn)
 local page=ports:read_u8(0x82)
 ports:write_u8(0x82,mem:read_u8(SYMBOL_text_font_page))
 fn()
 ports:write_u8(0x82,page)
end
local font_offset,original_byte
font_access(function()
 font_offset=mem:read_u8(256+65)+256*mem:read_u8(512+65)
 original_byte=mem:read_u8(font_offset)
 mem:write_u8(font_offset,255-original_byte)
end)
local changed_font
cpu_run(text_body("A",1,128,0,0,0,1),function() changed_font=raster(128,3) end)
cpu_run(text_body("A",1,144,1,0,0,1),function()
 assert(mem:read_u8(SYMBOL_text_attr_index)==255,"changed font used static precolour")
 local got=raster(144,3)
 for i,value in ipairs(changed_font) do assert(got[i]==value,"changed-font fallback differs") end
end)
font_access(function() mem:write_u8(font_offset,original_byte) end)
results.cache="clipping/row guards, font generation and four-entry LRU plus off-screen X and changed-font fallback passed"

-- Repeated set changes exercise both cold pages and all asset pages.
local stress={}
st(stress,SYMBOL_text_cache_enabled,0);st(stress,SYMBOL_text_precoloured_enabled,0)
call(stress,SYMBOL_resolve_buffers)
sw(stress,base+1000,300)
sw(stress,base+1002,0)
st(stress,SYMBOL_key_code,0)
local loop=base+31+#stress -- cpu_run's 8 PUSH bytes + three 5-byte stores
op(stress,0x21,0x92,0,0xe5)
local action_operand=#stress+2
call(stress,SYMBOL_handle_menu_action);op(stress,0xe1)
call(stress,SYMBOL_frame_wait)
local drain=base+31+#stress
call(stress,SYMBOL_key_poll)
op(stress,0x3a);put16(stress,SYMBOL_key_code);op(stress,0xb7,0xca)
local no_key_patch=#stress+1;put16(stress,0)
op(stress,0xfe,0x61,0xc2)
local clear_key_patch=#stress+1;put16(stress,0)
op(stress,0x2a);put16(stress,base+1002);op(stress,0x23,0x22);put16(stress,base+1002)
local clear_key=base+31+#stress
st(stress,SYMBOL_key_code,0)
op(stress,0xc3);put16(stress,drain)
local no_key=base+31+#stress
stress[no_key_patch]=no_key%256;stress[no_key_patch+1]=math.floor(no_key/256)
stress[clear_key_patch]=clear_key%256;stress[clear_key_patch+1]=math.floor(clear_key/256)
op(stress,0x2a);put16(stress,base+1000);op(stress,0x2b,0x22);put16(stress,base+1000)
op(stress,0x7c,0xb5,0xc2);put16(stress,loop)
local function inject_keys(tick)
 -- Use the same three-frame hold as the ordinary UI automation. A
 -- one-frame matrix pulse can fall between keyboard-controller scans.
 if tick<600 and tick%6==0 then fields["A"]:set_value(1) end
 if tick%6==3 then fields["A"]:set_value(0) end
end
local control={}
for i,value in ipairs(stress) do control[i]=value end
control[action_operand]=SYMBOL_frame_wait%256
control[action_operand+1]=math.floor(SYMBOL_frame_wait/256)
cpu_run(control,function()
 assert(mem:read_u16(base+1002)==100,"idle keyboard control: "..mem:read_u16(base+1002).."/100")
end,nil,inject_keys)
fields["A"]:set_value(0)
results.input_control="100/100 three-frame keypresses received without redraw"
local win0=ports:read_u8(0x82)
local win3=ports:read_u8(0xe2)
cpu_run(stress,function()
 assert(ports:read_u8(0x82)==win0,"WIN0 changed during stress")
 assert(ports:read_u8(0xe2)==win3,"WIN3 changed during stress")
 assert(mem:read_u16(base+1002)==100,"keyboard intake: "..mem:read_u16(base+1002).."/100")
end,nil,inject_keys)
fields["A"]:set_value(0)
results.stress="300 set changes with frame waits, WIN0/WIN3 preserved; 100/100 injected keypresses received"
-- DSS disk operations are correctness checks, separate from render/DI
-- timing. Restore the saved position through the real application path.
cpu.debug:bpclear()
local initial={}
for i=0,63 do initial[i]=mem:read_u8(SYMBOL_LOWRAM_CHESS_BOARD_ADDR+i) end
local save_name="R13BENCH"
local function set_name(text)
 for i=1,#text do mem:write_u8(base+1023+i,text:byte(i)) end
 mem:write_u8(base+1024+#text,0)
end
local function named_call(target)
 local t={0x21};put16(t,base+1024);op(t,0xe5);call(t,target);op(t,0xc1)
 return t
end
set_name(save_name)
cpu_run(named_call(SYMBOL_local_save_game),function()
 assert(mem:read_u8(SYMBOL_LOWRAM_OVERLAY_CONTEXT_ADDR+4)==0,"DSS save failed")
end)
set_name(save_name)
local load=named_call(SYMBOL_local_load_game)
-- Damage the display model so a no-op load cannot pass.
local damaged={}
st(damaged,SYMBOL_LOWRAM_CHESS_BOARD_ADDR,string.byte('.'))
for _,v in ipairs(load) do damaged[#damaged+1]=v end
call(damaged,SYMBOL_frame_wait)
cpu_run(damaged,function()
 for i=0,63 do assert(mem:read_u8(SYMBOL_LOWRAM_CHESS_BOARD_ADDR+i)==initial[i],"loaded board differs") end
 screen:snapshot("08-loaded.png")
end)
set_name(save_name)
local erase={0x21,2,0,0xe5,0x21};put16(erase,base+1024)
op(erase,0xe5,0x21,0,0,0xe5);call(erase,SYMBOL_spectrum_saveload_run)
op(erase,0xc1,0xc1,0xc1)
cpu_run(erase,function()
 assert(mem:read_u8(SYMBOL_LOWRAM_OVERLAY_CONTEXT_ADDR+4)==0,"DSS erase failed")
end)
results.saveload="real local save/load/erase passed; damaged display model restored"
local session={}
st(session,SYMBOL_netchesszx_local_color,0)
call(session,SYMBOL_net_session_begin);call(session,SYMBOL_frame_wait)
cpu_run(session,function()
 for i=0,63 do assert(mem:read_u8(SYMBOL_LOWRAM_CHESS_BOARD_ADDR+i)==initial[i],"session board differs") end
 screen:snapshot("09-session.png")
end)
set_name("Runtime check")
cpu_run(named_call(SYMBOL_net_drop))
results.session="real session-begin repaint and disconnect cleanup passed; no network peer"

local reset={}
call(reset,SYMBOL_resolve_buffers)
st(reset,SYMBOL_text_cache_enabled,0);st(reset,SYMBOL_text_precoloured_enabled,0)
call(reset,SYMBOL_about_restore_screen)
cpu_run(reset)
local output=assert(io.open(RUNTIME_RESULTS_PATH,"w"))
for key,value in pairs(results) do output:write(key..": "..value.."\n") end
output:close()
print("Render runtime checks passed")
