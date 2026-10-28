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
    ld bc,4
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
    ld a,(background)
    cp 2
    jr z,flash
    ld a,(#B8D8)
    ld hl,got_page
    cp (hl)
    ld a,1
    call t_expect_z
    ld a,(piece)
    add a,a
    ld hl,background
    add a,(hl)
    ld hl,#B8D9
    add a,(hl)
    jr slot
flash:
    ld a,(#B8DA)
    ld hl,got_page
    cp (hl)
    ld a,2
    call t_expect_z
    ld a,(piece)
    ld hl,#B8DB
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
locations: db 41,0,73,24,41,24,73,36,73,0,73,48
    ds #C000-$,0
    incbin "cold_win3_page.bin"
