; z80 unit test for the FLIP menu action, run against the bytes that ship.
;
; WHY THIS EXISTS. menu_flip_board (asm/sprinter/zcc/render_shim.asm) is
; hand-written asm that calls a COMPILED C function with an argument:
; spectrum_gui_set_board_view(uint8_t). Its first version passed that
; argument in register L, on the strength of a comment claiming the
; function was __z88dk_fastcall. It never was on this target -- gui.h tags
; it NETCHESSZX_FASTCALL, and that macro expands to __z88dk_fastcall only
; under NETCHESSZX_SDCC_IY (the ZX/Next SDCC build), to NOTHING under this
; port's sccz80. The callee therefore read its argument off the stack
; (`ld hl,2 / add hl,sp / ld l,(hl)`, straight out of the shipped cold
; page) and got whatever the cold-call thunk happened to leave there, so
; the board-flip flag was set from garbage and the FLIP menu item did
; nothing visible. Reported from MAME, human tester, 2026-08-18.
;
; Nothing caught it: the C compiler never sees this call (it is asm), the
; layering/ABI gates check symbol presence and overlay entry shapes, not
; register-vs-stack conventions, and no test drove the action end to end.
; Hence this one, built the way this port has learned to settle arguments
; about asm -- run the shipped bytes rather than re-read them (see
; t_hint_blit.asm's own banner for the three MAME rounds that lesson cost).
;
; WHAT IT DOES. Loads the real WIN1 resident at #4000 and the real WIN3
; cold page at #C000, then CALLs menu_flip_board at the address
; resident_c.map reports and checks the shared flip cell actually toggles
; 0 -> 1 -> 0. Everything in between is the shipping implementation: the
; generated cold-call thunks, the cold page's own jp-table, and gui.c's
; compiled spectrum_gui_is_board_flipped / spectrum_gui_set_board_view.
; Only the repaint tail is stubbed (see below) -- it would paint into
; #C000, which in this flat test image is where the cold page itself
; lives.
;
; The flip flag is not a C static but a fixed low-RAM cell
; (LOWRAM_RENDER_SHARED, #B400) precisely because it crosses this
; WIN1/cold-page link boundary -- gui.c's own comment explains that -- so
; reading it back here is reading exactly what the renderer would read.
;
; WHAT IT CANNOT COVER: that the repaint then puts flipped pixels on a real
; screen (unverifiable outside MAME/hardware, the same caveat t_draw_tile.
; asm and t_hint_blit.asm carry). It covers which value reaches the callee,
; which is where this failure actually lived.
;
; The harness's own status cells (#E000-#E003) land inside the cold page
; image, in the middle of _net_handle_mqtt_event -- corrupting four bytes
; of code this test never calls. Same trade t_hint_blit.asm already makes;
; the flip path is #C000-#C0C0 (jp-table) plus #C97F-#C9C8 (the three gui.c
; routines), nowhere near it.

        device  noslot64k
        org     0
        jp      start
        ds      #0100-$,0

        include "harness.inc"
        include "fixed_layout.inc"
        include "resident_test_defs.inc"
        include "platform_test_defs.inc"

; Any value but #FF. The cold-call thunks treat #FF as "no cold page
; published yet" and turn every dispatch into a silent no-op (cold_thunks'
; own cold_no_page guard, matching the overlay loader) -- which is the
; state a freshly INCBINed resident image is in, since only bench_init
; fills this cell from HDR at boot. Without this the test would pass
; through the thunk and never reach gui.c at all; the page number itself
; is irrelevant here, the OUT goes nowhere under ticks and the cold page is
; already resident at #C000 in this flat image.
TEST_COLD_PAGE EQU #20

; Below the resident image (#4000+), so neither the stack nor the capture
; buffer can land in code under test.
TEST_SP   EQU #3F00
CAP       EQU #3E00

start:
        ld      sp,TEST_SP
        call    t_begin

        ; menu_flip_board ends with `jp saveload_full_redraw` -- five
        ; cold-page repaint calls that would write into #C000 (VRAM_BUF0 on
        ; real hardware; the cold page itself in this flat image). Stub it
        ; to a RET: this test is about which value reaches the flag, not
        ; about painting.
        ld      a,#C9                   ; RET
        ld      (res_saveload_full_redraw),a

        ld      a,TEST_COLD_PAGE
        ld      (plat_cold_win3_page),a

        ; --- 1. From "not flipped", one FLIP must set the flag.
        xor     a
        ld      (LOWRAM_RENDER_SHARED_ADDR),a
        call    res_menu_flip_board
        ld      a,(LOWRAM_RENDER_SHARED_ADDR)
        ld      (CAP+0),a
        cp      1
        ld      a,1
        call    t_expect_z

        ; --- 2. THE REGRESSION. A second FLIP must clear it again. This is
        ; the assertion the shipped bug failed: with the argument passed in
        ; L and nothing pushed, the callee read a stack byte instead, so
        ; the flag stopped tracking the toggle.
        call    res_menu_flip_board
        ld      a,(LOWRAM_RENDER_SHARED_ADDR)
        ld      (CAP+1),a
        or      a
        ld      a,2
        call    t_expect_z

        ; --- 3. And a third must set it once more -- proving it toggles
        ; rather than merely landing on 0 by luck.
        call    res_menu_flip_board
        ld      a,(LOWRAM_RENDER_SHARED_ADDR)
        ld      (CAP+2),a
        cp      1
        ld      a,3
        call    t_expect_z

        ; --- 4. The flag must be exactly 0 or 1, never a raw stack byte:
        ; spectrum_gui_set_board_view normalises its argument
        ; (`flipped = local_black != 0`), so anything else here means the
        ; value never went through that normalisation at all.
        ld      a,(CAP+0)
        cp      2
        ld      a,4
        call    t_expect_c              ; < 2
        ld      a,(CAP+1)
        cp      2
        ld      a,5
        call    t_expect_c
        ld      a,(CAP+2)
        cp      2
        ld      a,6
        call    t_expect_c

        call    t_end
        halt

; The real WIN1 resident (#4000-#BFFF: menu_flip_board, the cold-call
; thunks, and the #B400 flip cell) and the real WIN3 cold page (#C000-
; #FFFF: the jp-table and gui.c). Padded with "ds", not "org": --raw writes
; a flat file from address 0 and an "org" jump would leave the gap
; unwritten (t_hint_blit.asm/t_net_frame_blob.asm pad the same way for the
; same reason).
        ds      #4000-$,0
        incbin  "resident.bin"
        ; The spliced resident is exactly 32768 bytes (#4000-#BFFF), so the
        ; cold page follows immediately at #C000. Asserted rather than
        ; padded with another "ds": a ds of zero length draws a sjasmplus
        ; shortblock warning, and this port has already shipped one bug
        ; hidden behind an ignored assembler warning (S9's boot banner).
        ASSERT  $ == #C000
        incbin  "cold_win3_page.bin"
