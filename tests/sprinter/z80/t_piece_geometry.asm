; Shipping painter, with only the hardware primitives stubbed. Verify that
; FLIP changes destination geometry, flash changes the two-slot variant,
; and an unavailable group cannot reach the blitter.
    device noslot64k
    org 0
    jp start
    ds #100-$,0
    include "harness.inc"
    include "coldrender_test_defs.inc"
    include "fixed_layout.inc"
start:
    ld sp,#7000
    call t_begin
    ld a,#C9
    ld (gfx_fill_rect),a
    ld a,#C3
    ld (gfx_draw_tile),a
    ld hl,record
    ld (gfx_draw_tile+1),hl
    ld a,'K'
    ; Board address is a generated layout constant, not a duplicated anchor.
    ld (LOWRAM_CHESS_BOARD_ADDR),a
    xor a
    ld (_spectrum_gui_board_flipped),a
    ld (hilite_bg),a
    ld (calls),a
    ld a,41
    ld (#B8D8),a
    ld a,36
    ld (#B8D9),a
    ld hl,0
    call render_square
    ld a,(calls)
    cp 1
    ld a,1
    call t_expect_z
    ld a,(tile_width)
    cp 20
    ld a,2
    call t_expect_z
    ld a,(tile_stride)
    cp 20
    ld a,3
    call t_expect_z
    ld a,(tile_rows)
    cp 20
    ld a,4
    call t_expect_z
    ld a,(tile_x_byte)
    cp 10
    ld a,5
    call t_expect_z
    ld a,(tile_y)
    cp 42
    ld a,6
    call t_expect_z
    ld a,(tile_src_slot)
    cp 36
    ld a,7
    call t_expect_z
    ld a,1
    ld (_spectrum_gui_board_flipped),a
    ld a,8
    ld (hilite_bg),a
    ld hl,0
    call render_square
    ld a,(tile_x_byte)
    cp 178
    ld a,8
    call t_expect_z
    ld a,(tile_y)
    cp 210
    ld a,9
    call t_expect_z
    ld a,(tile_src_slot)
    cp 40
    ld a,10
    call t_expect_z
    ld a,#FF
    ld (#B8D8),a
    ld hl,0
    call render_square
    ld a,(calls)
    cp 2
    ld a,11
    call t_expect_z
    call t_end
    halt
record:
    ld a,(calls)
    inc a
    ld (calls),a
    ret
calls: db 0
    ds #4000-$,0
    incbin "resident.bin"
    incbin "cold_win3_page.bin"
