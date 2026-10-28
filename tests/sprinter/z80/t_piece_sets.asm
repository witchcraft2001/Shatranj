; S14: execute the shipping MENU_CONFIG entries through their entry table.
; Stub palette upload and VRAM painters; verify the persistent WIN2 state,
; theme isolation, long cycling, 16-bit menu positions and staged strings.
    device noslot64k
    org 0
    jp start
    ds #100-$,0
    include "harness.inc"
    include "platform_test_defs.inc"
    include "coldrender_test_defs.inc"
    include "menu_test_defs.inc"
start:
    ld sp,#7000
    call t_begin
    ld a,#C9
    ; Exercise the real video_init/palette upload loop, stubbing only VRAM I/O.
    ld (plat_write_palette_entry),a
    ld a,#C3
    ld (plat_write_palette_entry),a
    ld hl,skip_rgb
    ld (plat_write_palette_entry+1),hl
    ld a,#C9
    ld (gfx_fill_rect),a
    ld a,#C3
    ld (text_print),a
    ld hl,record_text
    ld (text_print+1),hl
    ld a,41
    ld (plat_piece_page1),a
    ld a,73
    ld (plat_piece_page2),a
    ; Distinct synthetic RGBs detect wrong set offsets even when artwork
    ; happens to use the same palette. The on-disk assets remain untouched.
    ld hl,colours
    ld de,menu_piece_rgb
    ld bc,36
    ldir
    ld hl,plat_palette_rgb
    ld (hl),#A7
    ld de,plat_palette_rgb+1
    ld bc,47
    ldir
    ld hl,(#FA03) ; initialize California
    call invoke
    ld hl,plat_palette_rgb
    ld b,12
    call expect_sentinel
    ld hl,plat_palette_rgb+24
    ld b,24
    call expect_sentinel
    xor a
    ld (expected),a
    ld hl,300
    ld (remaining),hl
loop:
    ld a,(expected)
    ld hl,#B8D7
    cp (hl)
    ld a,1
    call t_expect_z
    ld a,(expected)
    add a,a
    add a,a
    ld e,a
    ld d,0
    ld hl,locations
    add hl,de
    ld de,#B8D8
    ld b,4
check_state:
    ld a,(de)
    cp (hl)
    ld a,2
    call t_expect_z
    inc hl
    inc de
    djnz check_state
    ; Theme entry must preserve all four piece colours and the index.
    ld hl,#B34F
    ld (hl),4
    ld hl,(#FA05)
    call invoke
    ld a,(expected)
    ld hl,colours
    or a
    jr z,compare
    ld b,a
stride:
    ld de,12
    add hl,de
    djnz stride
compare:
    push hl
    call plat_video_init
    pop hl
    ld de,plat_palette_rgb+12
    ld b,12
colour_loop:
    ld a,(de)
    cp (hl)
    ld a,3
    call t_expect_z
    inc de
    inc hl
    djnz colour_loop
    ld hl,(#FA07)
    call invoke
    ld a,(expected)
    inc a
    cp 3
    jr c,store
    xor a
store:
    ld (expected),a
    ld hl,(remaining)
    dec hl
    ld (remaining),hl
    ld a,h
    or l
    jr nz,loop
    xor a
    ld (text_count),a
    ld hl,#B34F
    ld (hl),6
    ld hl,(#FA01)
    call invoke
    ld a,(text_count)
    cp 7
    ld a,4
    call t_expect_z
    ld hl,(last_x)
    ld de,292
    or a
    sbc hl,de
    ld a,5
    call t_expect_nc
    call t_end
    halt
invoke:
    ld de,#B34F
    push hl
    ex de,hl
    ret
record_text:
    ld (last_x),ix
    ld a,(text_count)
    inc a
    ld (text_count),a
    ; text_print must read WIN2-staged labels while WIN3 is mapped to VRAM.
    ld a,d
    cp #B8
    ld a,6
    call t_expect_z
    ret
expected: db 0
remaining: dw 0
text_count: db 0
last_x: dw 0
locations: db 41,0,73,24,41,24,73,36,73,0,73,48
skip_rgb:
    inc hl
    inc hl
    inc hl
    ret
expect_sentinel:
    ld a,(hl)
    cp #A7
    ld a,7
    call t_expect_z
    inc hl
    djnz expect_sentinel
    ret
colours:
    db 1,2,3,4,5,6,7,8,9,10,11,12
    db 21,22,23,24,25,26,27,28,29,30,31,32
    db 41,42,43,44,45,46,47,48,49,50,51,52
    ds #4000-$,0
    incbin "resident.bin"
    ds #FA00-$,0
    incbin "overlay_menu.bin"
