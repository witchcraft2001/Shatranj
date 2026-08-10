; z80 unit test for asm/sprinter/scene_s4.asm's pure-arithmetic routines:
; scene_piece_code_at (start-position table decode), scene_cell_bg (square
; parity), scene_piece_slot_and_page (piece-tile slot/page arithmetic),
; scene_theme_record_ptr (theme blob indexing), and MUL_CELL_TABLE (the
; board's byte-column/pixel-row lookup, shared by cell fills and coordinate
; glyphs).
;
; scene_s4.asm's remaining routines (scene_toggle/scene_init/scene_draw_*/
; scene_theme_next/scene_set_next) are drawing orchestration calling into
; gfx_core.asm/text640.asm/video_s1.asm/bench_s2.asm -- not included here
; (t_bench_poll.asm's precedent: provide minimal stubs for the handful of
; external symbols scene_s4.asm's file-scope code references, rather than
; pulling in the whole render/text/video chain a test of pure arithmetic
; does not need). The theme/set hotkey state machine's wraparound (a
; trivial 5-line inc/cp/wrap, low bug risk) is exercised live instead, by
; the tester-notes MAME protocol cycling 'T' 6x and 'S' 4x past both
; wraparound points -- arguably a stronger check for a state machine than
; a unit test double could give, since it also proves the redraw actually
; happens.
;
; The scene_start_position fixture below is NOT a copy of the real table
; but the exact literal from scene_s4.asm -- authored by hand-deriving
; each byte from the piece-code scheme (1=wK..6=wP, 7=bK..12=bP) while
; writing this test, which is how an earlier placeholder version of the
; real table (wrong nibbles throughout) got caught before ever reaching
; MAME.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

; --- minimal external-symbol stubs (scene_s4.asm alone is under test) -----
; BOARD_X_BYTE/CELL_W_BYTES are normally bench_s2.asm EQUs (BOARD_X/2,
; BOARD_CELL_W/2); this test does not include bench_s2.asm, so it defines
; matching values itself.
BOARD_X_BYTE EQU 8
CELL_W_BYTES EQU 24

gfx_clear_buffer: ret
gfx_fill_rect: ret
gfx_draw_tile: ret
text_print: ret
write_palette_entry: ret
resolve_buffers: ret
video_init: ret
front_base: DW 0
back_base: DW 0
bench_asset_page: DB 0
tile_dest_base: DW 0
tile_x_byte: DB 0
tile_x_hi: DB 0
tile_y: DB 0
tile_src_page: DB 0
tile_src_slot: DB 0
tile_stride: DB 0
tile_width: DB 0
tile_rows: DB 0
tile_alias: DB 0

start:
        ld      sp,#e800
        call    t_begin

        ; --- scene_piece_code_at: start-position decode ------------------

        ld      b,0                     ; row 0 = rank 8
        ld      c,0                     ; col 0 = file a
        call    scene_piece_code_at
        cp      9                       ; a8 = bR
        ld      a,1
        call    t_expect_z

        ld      b,0
        ld      c,4                     ; e8
        call    scene_piece_code_at
        cp      7                       ; e8 = bK
        ld      a,2
        call    t_expect_z

        ld      b,4                     ; row 4 = rank 4
        ld      c,4                     ; e4
        call    scene_piece_code_at
        or      a
        ld      a,3                     ; e4 = empty (code 0)
        call    t_expect_z

        ld      b,7                     ; row 7 = rank 1
        ld      c,0                     ; a1
        call    scene_piece_code_at
        cp      3                       ; a1 = wR
        ld      a,4
        call    t_expect_z

        ld      b,7
        ld      c,7                     ; h1
        call    scene_piece_code_at
        cp      3                       ; h1 = wR
        ld      a,5
        call    t_expect_z

        ; --- scene_cell_bg: square parity (2=light, 3=dark) --------------
        ; Row 0 is rank 8, col 0 is file a. An inverted parity would still
        ; draw a plausible chequerboard, just the wrong way round, and
        ; would silently move the demo markers onto same-coloured squares
        ; -- so the named corners and both marker squares are pinned here.

        ld      b,0                     ; a8
        ld      c,0
        call    scene_cell_bg
        cp      2                       ; light
        ld      a,20
        call    t_expect_z

        ld      b,7                     ; a1
        ld      c,0
        call    scene_cell_bg
        cp      3                       ; dark
        ld      a,21
        call    t_expect_z

        ld      b,7                     ; h1
        ld      c,7
        call    scene_cell_bg
        cp      2                       ; light
        ld      a,22
        call    t_expect_z

        ld      b,4                     ; e4 -- the dot marker's square
        ld      c,4
        call    scene_cell_bg
        cp      2                       ; light
        ld      a,23
        call    t_expect_z

        ld      b,3                     ; e5 -- the ring marker's square
        ld      c,4
        call    scene_cell_bg
        cp      3                       ; dark: the two markers must sit on
        ld      a,24                    ; DIFFERENT backgrounds, which is the
        call    t_expect_z              ; whole point of the #FF-key demo

        ; --- scene_piece_slot_and_page: corner slot arithmetic -----------

        ld      a,7                     ; scene_piece_page1 marker
        ld      (scene_piece_page1),a
        ld      a,9                     ; scene_piece_page2 marker
        ld      (scene_piece_page2),a

        xor     a                       ; scene_set_idx = 0 (california)
        ld      (scene_set_idx),a
        xor     a                       ; piece_index 0 (wK), bg_offset 0
        ld      b,0
        call    scene_piece_slot_and_page
        or      a
        ld      a,6                     ; slot 0
        call    t_expect_z
        ld      a,e
        cp      7                       ; page = scene_piece_page1
        ld      a,7
        call    t_expect_z

        ld      a,1                     ; scene_set_idx = 1 (mpchess)
        ld      (scene_set_idx),a
        ld      a,11                    ; piece_index 11 (bP), bg_offset 1
        ld      b,1
        call    scene_piece_slot_and_page
        cp      47                      ; slot 24 + 11*2 + 1 = 47
        ld      a,8
        call    t_expect_z
        ld      a,e
        cp      7                       ; page = scene_piece_page1 still
        ld      a,9
        call    t_expect_z

        ld      a,2                     ; scene_set_idx = 2 (totoy)
        ld      (scene_set_idx),a
        xor     a                       ; piece_index 0, bg_offset 0
        ld      b,0
        call    scene_piece_slot_and_page
        or      a
        ld      a,10                    ; slot 0
        call    t_expect_z
        ld      a,e
        cp      9                       ; page = scene_piece_page2
        ld      a,11
        call    t_expect_z

        ; --- MUL_CELL_TABLE: both ends of the byte-column/pixel-row map --

        ld      a,(MUL_CELL_TABLE)
        or      a
        ld      a,12                    ; col/row 0 -> offset 0
        call    t_expect_z

        ld      a,(MUL_CELL_TABLE+7)
        cp      168
        ld      a,13                    ; col/row 7 -> offset 168
        call    t_expect_z

        ; --- scene_theme_record_ptr: fixture blob indexing ----------------

        ld      hl,theme_fixture
        ld      de,scene_theme_buf
        ld      bc,theme_fixture_end-theme_fixture
        ldir

        xor     a                       ; scene_theme_idx = 0
        ld      (scene_theme_idx),a
        call    scene_theme_record_ptr
        ld      a,(hl)
        cp      'T'                     ; theme 0's name starts "T0"
        ld      a,14
        call    t_expect_z
        inc     hl
        ld      a,(hl)
        cp      '0'
        ld      a,15
        call    t_expect_z

        ld      a,1                     ; scene_theme_idx = 1
        ld      (scene_theme_idx),a
        call    scene_theme_record_ptr
        ld      a,(hl)
        cp      'T'
        ld      a,16
        call    t_expect_z
        inc     hl
        ld      a,(hl)
        cp      '1'
        ld      a,17
        call    t_expect_z
        ; first entry of theme 1: index=2, R=0x11 (8 bytes past the name)
        ld      bc,7
        add     hl,bc
        ld      a,(hl)
        cp      2
        ld      a,18
        call    t_expect_z
        inc     hl
        ld      a,(hl)
        cp      #11
        ld      a,19
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

; format=1, theme_count=3, entries_per_theme=2, reserved=0, then per theme:
; name[8] + 2x(index,R,G,B). Stride = 8+2*4 = 16 bytes/theme.
theme_fixture:
        DB 1,3,2,0
        DB "T0",0,0,0,0,0,0
        DB 2,#10,#20,#30
        DB 3,#40,#50,#60
        DB "T1",0,0,0,0,0,0
        DB 2,#11,#21,#31
        DB 3,#41,#51,#61
        DB "T2",0,0,0,0,0,0
        DB 2,#12,#22,#32
        DB 3,#42,#52,#62
theme_fixture_end:

        include "scene_s4.asm"
