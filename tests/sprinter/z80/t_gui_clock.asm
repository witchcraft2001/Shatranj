; z80 unit test for gui.c's 1 Hz tick, run against the bytes that ship.
;
; WHY THIS EXISTS. spectrum_gui_tick (src/spectrum/ui/gui.c) counts its OWN
; invocations -- 50 calls == one second -- and that single counter,
; clock_frames, drives THREE things: the GAME timer, the TURN timer, and the
; wall clock's seconds. spectrum_gui_set_clock resets it, to re-phase the
; sub-second boundary onto the time just set.
;
; That reset is right where the call comes from a rare, authoritative MQTT
; SYNC_TIME message (ZX/Next). It is wrong on Sprinter, whose frame loop
; pushes a LOCAL RTC into the same entry point once a second: the reset then
; lands roughly as often as the boundary it is resetting, and since this
; port's loop can advance two frames per pass, the two cadences lock in
; phase and clock_frames never reaches 50 at all -- the GAME and TURN timers
; stop dead while every other part of the UI keeps running. gui.c therefore
; skips the reset under NETCHESSZX_SPRINTER, and this test is what holds
; that branch in place.
;
; The timers on this port have already been wrong twice from couplings that
; no gate could see (docs/sprinter-testnotes/S9.md: the half-speed tick, then
; the deleted RTC push), and both were reported from MAME by a human rather
; than by anything in the build. A source-shape gate now covers the frame
; loop (tools/check_transport_contract.py); this covers the half that lives
; in compiled code, the way this port settles arguments about compiled code
; -- by running the shipped bytes (t_menu_flip.asm's banner has the lesson).
;
; WHAT IT DOES. Loads the real WIN1 resident at #4000 and the real WIN3 cold
; page at #C000 (gui.c lives on the cold page), then drives the shipped
; spectrum_gui_game_timer_start / spectrum_gui_tick / spectrum_gui_set_clock
; through the generated cold-call thunks and reads the rendered GAME/TURN
; text back out of its low-RAM save cell -- the same bytes the renderer
; would paint. 50 ticks must advance TURN by one second, with or without a
; wall-clock push landing in the middle of them.
;
; WHAT IT CANNOT COVER: that the text then reaches real pixels (MAME/hardware
; only, the caveat t_draw_tile.asm and t_hint_blit.asm carry), and the RTC
; itself -- rtc_sample RSTs into DSS, which no test outside MAME can call.
;
; The harness's own status cells (#E000-#E003) land inside the cold page
; image, in session_sprinter.c's _net_handle_mqtt_event -- four bytes of code
; this test never calls. Same trade t_menu_flip.asm and t_hint_blit.asm make.

        device  noslot64k
        org     0
        jp      start
        ds      #0100-$,0

        include "harness.inc"
        include "fixed_layout.inc"
        include "resident_test_defs.inc"
        include "platform_test_defs.inc"
        include "coldrender_test_defs.inc"

; Any value but #FF: the cold-call thunks treat #FF as "no cold page
; published yet" and turn every dispatch into a silent no-op, which is the
; state a freshly INCBINed resident image is in (t_menu_flip.asm's own note).
TEST_COLD_PAGE EQU #20

TEST_SP   EQU #3F00

; Offsets into the 24-byte GAME/TURN line gui.c stages at
; LOWRAM_GAME_TIMER_SAVE_ADDR: "GAME:00h00m TURN:00m00s".
;             0    5      11    17
TURN_SEC_LO EQU 21              ; units digit of the TURN seconds
TURN_SEC_HI EQU 20

start:
        ld      sp,TEST_SP
        call    t_begin

        ld      a,TEST_COLD_PAGE
        ld      (plat_cold_win3_page),a

        ; Every painter gui.c's clock/timer/notice paths can reach, stubbed
        ; to a RET. They write VRAM through WIN3, which under ticks means
        ; they write straight into #C000 -- where this flat image keeps the
        ; cold page itself. Nothing here is about pixels; the rendered TEXT
        ; is read from low RAM instead, which is what they would have
        ; painted from.
        ld      a,#C9                   ; RET
        ld      (_spectrum_render_game_timer_char),a
        ld      (_spectrum_render_game_timer_clear),a
        ld      (_spectrum_render_clock),a
        ld      (_spectrum_render_notice),a

        ; One determinate path through gui.c: no modal screen owns the
        ; display (about_visible would suppress the repaint outright) and
        ; the menu is closed (menu_visible takes the other timer branch).
        xor     a
        ld      (_about_visible),a
        ld      (_menu_visible),a

        ; --- 1. A started game timer stages "GAME:...TURN:00m00s".
        call    res_spectrum_gui_game_timer_start
        ld      a,(LOWRAM_GAME_TIMER_SAVE_ADDR+TURN_SEC_LO)
        cp      '0'
        ld      a,1
        call    t_expect_z

        ; --- 2. 49 ticks are NOT a second. Pins the cadence itself: an
        ; off-by-one here would make every assertion below meaningless.
        ld      b,49
        call    tick_b
        ld      a,(LOWRAM_GAME_TIMER_SAVE_ADDR+TURN_SEC_LO)
        cp      '0'
        ld      a,2
        call    t_expect_z

        ; --- 3. The 50th is.
        ld      b,1
        call    tick_b
        ld      a,(LOWRAM_GAME_TIMER_SAVE_ADDR+TURN_SEC_LO)
        cp      '1'
        ld      a,3
        call    t_expect_z

        ; --- 4. THE REGRESSION. Same 50 ticks, but with a wall-clock push
        ; halfway through -- exactly what main.c's frame loop does once a
        ; second. With gui.c's clock_frames reset left unguarded, that push
        ; zeroes the sub-second counter 25 ticks in, the remaining 25 never
        ; reach 50, and TURN stays at one second forever.
        ld      b,25
        call    tick_b
        ld      hl,12                   ; hour
        push    hl
        ld      hl,34                   ; minute
        push    hl
        ld      hl,56                   ; second
        push    hl
        call    res_spectrum_gui_set_clock
        pop     de
        pop     de
        pop     de
        ld      b,25
        call    tick_b
        ld      a,(LOWRAM_GAME_TIMER_SAVE_ADDR+TURN_SEC_LO)
        cp      '2'
        ld      a,4
        call    t_expect_z

        ; --- 5. ...and the push was real, not swallowed by a stub: the wall
        ; clock's own save cell now holds "12:34 " where it held "--:--"
        ; before spectrum_gui_set_clock was ever called.
        ld      a,(LOWRAM_CLOCK_SAVE_ADDR+0)
        cp      '1'
        ld      a,5
        call    t_expect_z
        ld      a,(LOWRAM_CLOCK_SAVE_ADDR+4)
        cp      '4'
        ld      a,6
        call    t_expect_z

        ; --- 6. Two more pushes inside one second, at 20 and 40 ticks in.
        ; A single surviving push could be luck of the phase; repeated ones
        ; are the real shape of the frame loop, and they must not shift the
        ; boundary at all.
        ld      b,20
        call    tick_b
        call    push_clock
        ld      b,20
        call    tick_b
        call    push_clock
        ld      b,10
        call    tick_b
        ld      a,(LOWRAM_GAME_TIMER_SAVE_ADDR+TURN_SEC_LO)
        cp      '3'
        ld      a,7
        call    t_expect_z

        ; --- 7. And the tens digit is still '0' -- i.e. the seconds
        ; advanced by ones, rather than the line being rewritten with
        ; something that merely happens to end in '3'.
        ld      a,(LOWRAM_GAME_TIMER_SAVE_ADDR+TURN_SEC_HI)
        cp      '0'
        ld      a,8
        call    t_expect_z

        call    t_end
        halt

; B ticks through the shipped cold-call thunk. B survives because the thunk
; and gui.c are compiled code that may clobber anything.
tick_b:
        ld      a,b
        or      a
        ret     z
.loop:  push    bc
        call    res_spectrum_gui_tick
        pop     bc
        djnz    .loop
        ret

push_clock:
        ld      hl,12
        push    hl
        ld      hl,34
        push    hl
        ld      hl,56
        push    hl
        call    res_spectrum_gui_set_clock
        pop     de
        pop     de
        pop     de
        ret

; The real WIN1 resident (#4000-#BFFF: the cold-call thunks and the low-RAM
; save cells) and the real WIN3 cold page (#C000-#FFFF: the jp-table, gui.c
; and render_core.asm). Padded with "ds", not "org": --raw writes a flat
; file from address 0 and an "org" jump would leave the gap unwritten
; (t_menu_flip.asm/t_hint_blit.asm pad the same way for the same reason).
        ds      #4000-$,0
        incbin  "resident.bin"
        ; The spliced resident is exactly 32768 bytes (#4000-#BFFF), so the
        ; cold page follows immediately at #C000 -- asserted rather than
        ; padded, since a zero-length "ds" draws a sjasmplus shortblock
        ; warning (t_menu_flip.asm's own note).
        ASSERT  $ == #C000
        incbin  "cold_win3_page.bin"
