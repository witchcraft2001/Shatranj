; Execute the shipping renderer's slot resolver for all 12 pieces and
; all three backgrounds, with each of the three selected-set parameters.
    device noslot64k
    org 0
    jp start
    ds #100-$,0
    include "harness.inc"
    include "coldrender_test_defs.inc"
start:
    ld sp,#7000
    call t_begin
    ld hl,locations
    ld (record),hl
    ld a,3
    ld (sets_left),a
set_loop:
    ld hl,(record)
    ld de,#B8D8
    ld bc,24
    ldir
    ld (record),hl
    xor a
    ld (piece),a
piece_loop:
    xor a
    ld (background),a
bg_loop:
    ld a,(background)
    ld b,a
    ld a,(piece)
    call piece_slot_and_page
    ld (got_slot),a
    ld a,e
    ld (got_page),a
    ld a,(piece)
    add a,a
    ld l,a
    ld h,0
    ld de,#B8D8
    add hl,de
    ld a,(hl)
    ld de,got_page
    ex de,hl
    cp (hl)
    ld a,1
    call t_expect_z
    ex de,hl
    inc hl
    ld a,(background)
    add a,a
    add a,(hl)
slot:
    ld hl,got_slot
    cp (hl)
    ld a,3
    call t_expect_z
    ld hl,background
    inc (hl)
    ld a,(hl)
    cp 3
    jr nz,bg_loop
    ld hl,piece
    inc (hl)
    ld a,(hl)
    cp 12
    jr nz,piece_loop
    ld hl,sets_left
    dec (hl)
    jr nz,set_loop
    call t_end
    halt
record: dw 0
sets_left: db 0
piece: db 0
background: db 0
got_slot: db 0
got_page: db 0
locations:
    db 41,0,41,6,41,12,41,18,41,24,41,30,41,36,41,42,41,48,41,54,73,0,73,6
    db 73,12,73,18,73,24,73,30,73,36,73,42,73,48,73,54,99,0,99,6,99,12,99,18
    db 99,24,99,30,99,36,99,42,99,48,99,54,105,0,105,6,105,12,105,18,105,24,105,30
    ds #C000-$,0
    incbin "cold_win3_page.bin"
