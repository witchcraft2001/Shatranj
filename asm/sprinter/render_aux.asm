; Additional rendering code, HDR asset 16. Only parameter cells cross the
; boundary; render_aux_call saves/restores WIN3 on the resident stack.
; No accelerator, WIN0 change, stack move or network storage here.
        DEVICE NOSLOT64K
        INCLUDE "render_aux_defs.inc"
        ORG #C000
        jp merge_rect
        jp cell_source
        jp glyph_source
        jp text_setup
        ASSERT $ = AUX_ENTRY_BOARD_FULL
        jp render_board_full
        jp cache_lookup
        jp cache_capture
        jp cache_reset
        jp prepare_print_colors
        jp cache_fast_lookup

render_board_full:
        ld a,1
        ld (flip_log_suspended),a
        ld (board_background_done),a
        xor a
        ld (.band),a
.band_loop:
        ld hl,(back_base)
        ld (tile_dest_base),hl
        ld a,BOARD_X/2
        ld (tile_x_byte),a
        xor a
        ld (tile_x_hi),a
        ld (tile_stride),a
        ld a,192
        ld (tile_width),a
        ld a,24
        ld (tile_rows),a
        ld a,#50
        ld (tile_alias),a
        ld a,(.band)
        ld b,a
        add a,a
        add a,b
        add a,a
        add a,a
        add a,a                         ; band * 24
        add a,BOARD_Y
        ld (tile_y),a
        ld a,(.band)
        and 1
        ld hl,band_locations
        jr z,.band_ready
        ld de,3
        add hl,de
.band_ready:
        ld e,(hl)
        inc hl
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,HDR_ADDR+HDR_ASSET_PAGE0_OFFSET
        ld d,0
        add hl,de
        ld a,(hl)
        ld (tile_src_page),a
        ld h,b
        ld l,c
        call gfx_draw_tile_offset
        ld hl,.band
        inc (hl)
        ld a,(hl)
        cp 8
        jr c,.band_loop
        xor a
        ld (.square),a
.square_loop:
        ld a,(.square)
        ld e,a
        ld d,0
        ld hl,LOWRAM_CHESS_BOARD_ADDR
        add hl,de
        ld a,(hl)
        cp '.'
        jr z,.next
        ld a,(.square)
        ld l,a
        ld h,0
        call render_square_entry
.next:
        ld hl,.square
        inc (hl)
        ld a,(hl)
        cp 64
        jr c,.square_loop
        xor a
        ld (board_background_done),a
        ld (flip_log_suspended),a
        ld hl,BOARD_X/2
        ld (flip_arg_x),hl
        ld hl,192
        ld (flip_arg_w),hl
        ld a,BOARD_Y
        ld (flip_arg_y),a
        ld a,192
        ld (flip_arg_h),a
        jp flip_log_rect
.band: DB 0
.square: DB 0

text_setup:
        ld a,#FF
        ld (text_attr_index),a
        ld a,(HDR_ADDR+7)
        cp 20
        ret c
        ld a,(text_precoloured_enabled)
        or a
        ret z
        ; Prepared rasters belong to the original, unchanged font only.
        ld a,(text_font_version)
        or a
        ret nz
        ld a,(text_font_page)
        ld hl,HDR_ADDR+HDR_ASSET_PAGE0_OFFSET
        cp (hl)
        ret nz
        ld a,(text_color)
        ld hl,text_attributes
        ld b,5
        ld c,0
.loop:
        cp (hl)
        jr z,.found
        inc hl
        inc c
        djnz .loop
        ret
.found:
        ld a,c
        ld (text_attr_index),a
        ld l,a
        ld h,0
        add hl,hl
        ld de,glyph_biases
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (text_glyph_bias),de
        ret
prepare_print_colors:
        ld      a,(color_valid)
        or      a
        jr      z,.ppc_rebuild
        ld      a,b
.ppc_prev:
        cp      0
        ret     z
.ppc_rebuild:
        ld      a,1
        ld      (color_valid),a
        ld      a,b
        ld      (.ppc_prev+1),a
        ld      (text_previous_color),a
        and     #0F
        ld      c,a
        rlca
        rlca
        rlca
        rlca
        or      c
        ld      (fg_pattern),a
        ld      a,b
        and     #F0
        ld      c,a
        rrca
        rrca
        rrca
        rrca
        or      c
        ld      (bg_pattern),a
        ld      c,a
        ld      a,(fg_pattern)
        xor     c                       ; foreground XOR background
        exx
        ld      hl,foreground_buffer
        call    fill_colour_buffer_640
        ld      a,(bg_pattern)
        ld      hl,background_buffer
        call    fill_colour_buffer_640
        exx
        ret

; Active in the alternate register set. Fill eight bytes at HL with A.
fill_colour_buffer_640:
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        ret

; --- accelerated per-column renderer (afnt640.asm text_out_640_rows_*,
; ported unchanged apart from raw opcodes -> ACC_* macros) -----------------
;
; Entered only via the self-modified dispatch jump in .char below. Main
; BC=staged string pointer, HL/DE=current glyph raster pointer/8 (column
; stride); alternate BC'=destination column address (constant), HL'/DE'=

text_attributes: DB #01,#0D,#0B,#0C,#10

; Packed cell address for the selected set, piece (0..11, FF=empty),
; background (0..2). Result in tile_src_page and tile_src_offset.
cell_source:
        ld a,(cell_piece)
        cp #FF
        ld hl,empty_locations
        jr z,.background
        ld c,a
        ld a,(LOWRAM_PIECE_STATE_ADDR)
        ld b,a
        add a,a
        add a,b
        add a,a
        add a,a                         ; set*12
        add a,c
        ld c,a
        add a,a
        add a,c                         ; *3 variants
        ld l,a
        ld h,0
        add hl,hl
        ld e,a
        ld d,0
        add hl,de                       ; *3 bytes per location
        ld de,cell_locations
        add hl,de
.background:
        ld a,(cell_background)
        ld e,a
        ld d,0
        add hl,de
        add hl,de
        add hl,de
        ld e,(hl)                       ; HDR index
        inc hl
        ld a,(hl)
        ld (tile_src_offset),a
        inc hl
        ld a,(hl)
        ld (tile_src_offset+1),a
        ld hl,HDR_ADDR+HDR_ASSET_PAGE0_OFFSET
        ld d,0
        add hl,de
        ld a,(hl)
        ld (tile_src_page),a
        ret

; A second parameter selects a repeated board band rather than a cell.
; Band table is copied into the cold renderer as addresses at build time.

; Resolve precoloured glyph offset for attr index (FF=ordinary renderer).
glyph_source:
        ld a,(text_attr_index)
        cp #FF
        ret z
        ld h,a
        ld a,(text_char)
        ld l,a
        add hl,hl                       ; attr*512 + char*2
        ld de,glyph_locations
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+17)
        bit 6,d
        jr z,.ready
        res 6,d
        ld a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+18)
.ready:
        ld (text_glyph_page),a
        ld (text_glyph_offset),de
        ret

; Candidate and current rectangle use exclusive word-sized edges. Y=256
; is representable internally; h=0 is converted only at the ring boundary.
merge_rect:
        ; All logging callers have restored system WIN0. Like a cold
        ; painter, this computation may run with this code page in WIN3.
        ei
        ld a,(flip_ring_count)
        or a
        jr nz,.nonempty
        ld hl,flip_arg_x
        ld de,flip_ring
        ld bc,6
        ldir
        ld a,1
        ld (flip_ring_count),a
        ret
.nonempty:
        push ix
        push iy
        ld hl,(flip_arg_x)
        ld (candidate),hl
        ld de,(flip_arg_w)
        add hl,de
        ld (candidate+2),hl
        ld a,(flip_arg_y)
        ld l,a
        ld h,0
        ld (candidate+4),hl
        ld a,(flip_arg_h)
        ld e,a
        ld d,0
        or a
        jr nz,.height
        inc d
.height:
        add hl,de
        ld (candidate+6),hl
.restart:
        ld ix,flip_ring
        xor a
        ld (scan_index),a
.scan:
        ld a,(scan_index)
        ld hl,flip_ring_count
        cp (hl)
        jp nc,.append
        call read_current
        call bounding
        ld hl,candidate
        call area
        ld (area_sum),hl
        ld (area_sum+2),a
        ld hl,current
        call area
        ld de,(area_sum)
        add hl,de
        ld e,a
        ld a,(area_sum+2)
        adc a,e
        ld (area_sum),hl
        ld (area_sum+2),a
        ld hl,union_rect
        call area
        ld de,(area_sum)
        or a
        sbc hl,de
        ld e,a
        ld a,(area_sum+2)
        ld d,a
        ld a,e
        sbc a,d
        jr c,.merge
        jr nz,.next
        ld a,h
        or l
        jr z,.merge
.next:
        ld de,6
        add ix,de
        ld hl,scan_index
        inc (hl)
        jr .scan
.merge:
        ld hl,union_rect
        ld de,candidate
        ld bc,8
        ldir
        ; Remove this entry by replacing it with the last; restart so
        ; transitive merges and newly contained entries are eliminated.
        ld hl,flip_ring_count
        dec (hl)
        ld a,(hl)
        call ring_address
        push ix
        pop de
        ld bc,6
        ldir
        jp .restart
.append:
        ld a,(flip_ring_count)
        cp FLIP_RING_MAX
        jr c,.store
        ; Overflow collapses *all* changes to their bounding rectangle,
        ; retaining board/panel bounds instead of forcing dirty_all.
        ld ix,flip_ring
        ld a,FLIP_RING_MAX
        ld (scan_index),a
.collapse:
        call read_current
        call bounding
        ld hl,union_rect
        ld de,candidate
        ld bc,8
        ldir
        ld de,6
        add ix,de
        ld hl,scan_index
        dec (hl)
        jr nz,.collapse
        xor a
        ld (flip_ring_count),a
.store:
        ld a,(flip_ring_count)
        call ring_address
        ex de,hl
        ld hl,(candidate)
        ld a,l
        ld (de),a
        inc de
        ld a,h
        ld (de),a
        inc de
        ld a,(candidate+4)
        ld (de),a
        inc de
        ld hl,(candidate+2)
        ld bc,(candidate)
        or a
        sbc hl,bc
        ld a,l
        ld (de),a
        inc de
        ld a,h
        ld (de),a
        inc de
        ld hl,(candidate+6)
        ld bc,(candidate+4)
        or a
        sbc hl,bc
        ld a,l
        ld (de),a
        ld hl,flip_ring_count
        inc (hl)
        pop iy
        pop ix
        ret

ring_address:
        ld l,a
        ld h,0
        add hl,hl
        ld d,h
        ld e,l
        add hl,hl
        add hl,de
        ld de,flip_ring
        add hl,de
        ret

read_current:
        ld l,(ix+0)
        ld h,(ix+1)
        ld (current),hl
        ld e,(ix+3)
        ld d,(ix+4)
        add hl,de
        ld (current+2),hl
        ld l,(ix+2)
        ld h,0
        ld (current+4),hl
        ld e,(ix+5)
        ld d,0
        ld a,e
        or a
        jr nz,.height
        inc d
.height:
        add hl,de
        ld (current+6),hl
        ret

bounding:
        ld hl,(candidate)
        ld de,(current)
        call min_word
        ld (union_rect),hl
        ld hl,(candidate+2)
        ld de,(current+2)
        call max_word
        ld (union_rect+2),hl
        ld hl,(candidate+4)
        ld de,(current+4)
        call min_word
        ld (union_rect+4),hl
        ld hl,(candidate+6)
        ld de,(current+6)
        call max_word
        ld (union_rect+6),hl
        ret
min_word:
        or a
        sbc hl,de
        add hl,de
        ret c
        ex de,hl
        ret
max_word:
        or a
        sbc hl,de
        add hl,de
        ret nc
        ex de,hl
        ret
; HL=edges -> A:HL area (17 bits). Width <=320, height <=256.
area:
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld c,(hl)
        inc hl
        ld b,(hl)
        inc hl
        push hl
        ld h,b
        ld l,c
        or a
        sbc hl,de
        ex de,hl                        ; width
        pop hl
        ld c,(hl)
        inc hl
        ld b,(hl)
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        or a
        sbc hl,bc                       ; height
        ld a,h
        or a
        jr z,.short
        ld a,d                          ; width * 256
        ld h,e
        ld l,0
        ret
.short:
        ld c,l
        ld b,8
        ld hl,0
        xor a
.mul:
        add hl,hl
        rla
        sla c
        jr nc,.skip
        add hl,de
        adc a,0
.skip:
        djnz .mul
        ret
; Four raster entries of 4 KiB each, LRU ordered oldest -> newest. Metadata
; is in this code page and includes the actually clipped/staged text,
; colour, byte width, font page and explicit font generation.
cache_fast_lookup:
        ld a,1
        jr cache_lookup_common
cache_lookup:
        xor a
cache_lookup_common:
        ld (cache_fast),a
        push ix
        xor a
        ld (text_cache_hit),a
        ld (cache_slot),a
        ld hl,320
        ld a,(cache_fast)
        or a
        jr nz,.width_ready
        ld hl,(text_scan_col)
.width_ready:
        ld de,(text_start_col)
        or a
        sbc hl,de
        jp c,.return                    ; X beyond the right edge must not wrap
        ld (cache_width),hl
        ld a,h
        or l
        jp z,.return
.scan:
        call cache_record
        ld a,(ix+0)
        or a
        jr z,.next
        ld a,(text_color)
        cp (ix+1)
        jr nz,.next
        ld a,(cache_fast)
        or a
        jr nz,.check_fits
        ld hl,(cache_width)
        ld a,l
        cp (ix+2)
        jr nz,.next
        ld a,h
        cp (ix+3)
        jr nz,.next
        jr .width_matches
.check_fits:
        ld e,(ix+2)
        ld d,(ix+3)
        ld hl,(cache_width)
        or a
        sbc hl,de
        jr c,.next
.width_matches:
        ld a,(text_font_page)
        cp (ix+4)
        jr nz,.next
        ld a,(text_font_version)
        cp (ix+5)
        jr nz,.next
        push ix
        pop hl
        ld de,6
        add hl,de
        ld de,TEXT_STAGE
.compare:
        ld a,(de)
        cp (hl)
        jr nz,.next
        or a
        jr z,.hit
        inc hl
        inc de
        jr .compare
.next:
        ld hl,cache_slot
        inc (hl)
        ld a,(hl)
        cp 4
        jr c,.scan
        ld a,(cache_fast)
        or a
        jp nz,.return
        ld a,(cache_lru)
        ld (cache_slot),a
        call cache_record
        xor a
        ld (ix+0),a                    ; commit valid only after capture
        ld a,(text_color)
        ld (ix+1),a
        ld hl,(cache_width)
        ld (ix+2),l
        ld (ix+3),h
        ld a,(text_font_page)
        ld (ix+4),a
        ld a,(text_font_version)
        ld (ix+5),a
        push ix
        pop de
        ld hl,6
        add hl,de
        ex de,hl
        ld hl,TEXT_STAGE
.copy_key:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        or a
        jr nz,.copy_key
        ld a,1
        ld (text_cache_pending),a
        call cache_touch
        jr .return
.hit:
        ld l,(ix+2)
        ld h,(ix+3)
        ld (cache_width),hl
        call cache_touch
        ld a,1
        ld (text_cache_hit),a
        call cache_transfer
.return:
        pop ix
        ret

cache_capture:
        push ix
        xor a
        ld (text_cache_hit),a
        call cache_transfer
        call cache_record
        ld (ix+0),1
        xor a
        ld (text_cache_pending),a
        pop ix
        ret

cache_record:
        ld a,(cache_slot)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl                      ; slot*8
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,hl                      ; slot*64
        add hl,de                      ; slot*72
        ld de,cache_records
        add hl,de
        push hl
        pop ix
        ret

cache_touch:
        ld hl,cache_lru
        ld a,(cache_slot)
.find:
        cp (hl)
        jr z,.shift
        inc hl
        jr .find
.shift:
        ld de,cache_lru+3
        push hl
        or a
        sbc hl,de
        pop hl
        jr z,.last
        inc hl
        ld a,(hl)
        dec hl
        ld (hl),a
        inc hl
        jr .shift
.last:
        ld a,(cache_slot)
        ld (hl),a
        ret

cache_transfer:
        xor a
        ld (cache_plane),a
        call .plane
        ld hl,(cache_width)
        ld de,161
        or a
        sbc hl,de
        ret c
        ld a,1
        ld (cache_plane),a
.plane:
        ld hl,(text_dest_base)
        ld (tile_dest_base),hl
        ld a,(text_y)
        ld (tile_y),a
        ld a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+19)
        ld (tile_src_page),a
        ld a,8
        ld (tile_rows),a
        ld a,160
        ld (tile_stride),a
        ld a,#50
        ld (tile_alias),a
        ld a,(cache_slot)
        rlca
        rlca
        rlca
        rlca
        ld h,a
        ld l,0
        ld (tile_src_offset),hl
        ld hl,(text_start_col)
        ld (tile_x_byte),hl
        ld hl,(cache_width)
        ld de,160
        ld a,h
        or a
        jr nz,.wide
        ld a,l
        cp 161
        jr c,.width
.wide:
        ld a,(cache_plane)
        or a
        jr nz,.second
        ld a,160
        jr .width
.second:
        or a
        sbc hl,de
        ld a,l
        push af
        ld hl,(tile_x_byte)
        add hl,de
        ld (tile_x_byte),hl
        ld hl,(tile_src_offset)
        ld de,1280
        add hl,de
        ld (tile_src_offset),hl
        pop af
.width:
        ld (tile_width),a
        ld a,(text_cache_hit)
        or a
        jp z,gfx_capture_rows
        ld hl,(tile_src_offset)
        jp gfx_draw_tile_offset

cache_reset:
        xor a
        ld hl,cache_records
        ld de,cache_records+1
        ld bc,4*72-1
        ld (hl),a
        ldir
        ret
cache_fast: DB 0
cache_slot: DB 0
cache_plane: DB 0
cache_width: DW 0
cache_lru: DB 0,1,2,3
cache_records: DS 4*72,0

candidate: DS 8
current: DS 8
union_rect: DS 8
area_sum: DS 3
scan_index: DB 0
        INCLUDE "cell_locations.inc"
        INCLUDE "glyph_locations.inc"
        INCLUDE "glyph_biases.inc"
render_aux_end:
        ASSERT $ <= #10000
        DS #10000-$,0
