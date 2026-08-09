; z80 unit test for asm/sprinter/bench_s2.asm's measurement plumbing:
; bench_frames_reset/bench_poll (the S2 bench clock) and the destination-
; buffer handling of draw_bench_result/restore_glyph_base.
;
; Both are pure CPU logic with no accelerator or MMU involvement, so unlike
; the render primitives they are fully verifiable under z88dk-ticks -- and
; both have silent failure modes worth pinning down:
;
;   - bench_poll is what turns the IM2 stub's latched frame_flag into a
;     frame count. resident_s1.asm's tick_count cannot serve here: it is
;     incremented by main_loop, which does not run while a bench does, so
;     a bench built on it reports 0000 every time -- a "measurement" that
;     looks plausible and means nothing.
;   - font_hex.asm's draw_glyph draws into glyph_dest_base, defaulting to
;     buffer 0. bench_board flips buffers before reporting, so a result
;     written to the default lands in the buffer that flip just hid and is
;     invisible on screen -- again silent, and again indistinguishable
;     from "the bench did not run".
;
; The mocked frame_flag below stands in for the real ISR the harness has
; no way to fire, exactly as t_frame_wait.asm's S1_TEST_HOOK does.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

; frame_flag lives in im2_s1.asm and the rtc_* state in video_s1.asm,
; neither of which this test includes (it exercises bench_s2.asm alone,
; and video_s1.asm's rtc_sample RSTs into DSS, which the harness cannot
; service). frame_flag is driven by hand to simulate the IM2 stub latching
; a 50 Hz tick; rtc_sample is a mock that advances the second field once
; every rtc_mock_period calls, so the window logic can be exercised
; deterministically.
frame_flag: DB 0

rtc_present: DB 1
rtc_valid:   DB 1
rtc_second:  DB 0
rtc_mock_period:  DB 1          ; calls per simulated second
rtc_mock_counter: DB 0
rtc_sample:
        ld      hl,rtc_mock_counter
        inc     (hl)
        ld      a,(rtc_mock_period)
        cp      (hl)
        ret     nz
        ld      (hl),0
        ld      hl,rtc_second
        inc     (hl)
        ld      a,(hl)
        cp      60
        ret     c
        ld      (hl),0
        ret

start:
        ld      sp,#e800
        call    t_begin

        ; --- bench_init: no asset page in HDR -> the "unavailable" marker
        ; value, so both benches fall back to draw_no_assets_marker.
        xor     a
        ld      (HDR_ADDR+HDR_ASSET_PAGES_OFFSET),a
        call    bench_init
        ld      a,(bench_asset_page)
        cp      #FF
        ld      a,1
        call    t_expect_z

        ; --- bench_init: one asset page -> its physical number is picked
        ; up for both tiles and the font.
        ld      a,1
        ld      (HDR_ADDR+HDR_ASSET_PAGES_OFFSET),a
        ld      a,#37
        ld      (HDR_ADDR+HDR_ASSET_PAGE0_OFFSET),a
        call    bench_init
        ld      a,(bench_asset_page)
        cp      #37
        ld      a,2
        call    t_expect_z
        ld      a,(text_font_page)
        cp      #37
        ld      a,3
        call    t_expect_z

        ; --- bench_frames_reset clears both the counter and a stale flag.
        ld      a,1
        ld      (frame_flag),a
        ld      hl,#1234
        ld      (bench_frames),hl
        call    bench_frames_reset
        ld      a,(frame_flag)
        or      a
        ld      a,4
        call    t_expect_z
        ld      hl,(bench_frames)
        ld      a,h
        or      l
        ld      a,5
        call    t_expect_z

        ; --- one latched tick counts once, and clears the flag so it is
        ; not counted again.
        ld      a,1
        ld      (frame_flag),a
        call    bench_poll
        ld      hl,(bench_frames)
        ld      de,1
        or      a
        sbc     hl,de
        ld      a,6
        call    t_expect_z
        ld      a,(frame_flag)
        or      a
        ld      a,7
        call    t_expect_z

        ; --- polling with no tick pending must not invent one (this is
        ; what makes the count a frame count and not a call count).
        call    bench_poll
        call    bench_poll
        ld      hl,(bench_frames)
        ld      de,1
        or      a
        sbc     hl,de
        ld      a,8
        call    t_expect_z

        ; --- three more ticks, each latched then polled, accumulate.
        ld      b,3
.tick:  push    bc
        ld      a,1
        ld      (frame_flag),a
        call    bench_poll
        pop     bc
        djnz    .tick
        ld      hl,(bench_frames)
        ld      de,4
        or      a
        sbc     hl,de
        ld      a,9
        call    t_expect_z

        ; --- documented ceiling: the flag latches, it does not count, so
        ; two ticks spanned by a single poll interval read as one. (The
        ; real bench polls once per board cell / text line, far finer than
        ; the ~20 ms tick, which is what keeps this ceiling irrelevant in
        ; practice -- docs/sprinter-render-budget.md.)
        call    bench_frames_reset
        ld      a,1
        ld      (frame_flag),a
        ld      a,1                     ; a second tick, same latch
        ld      (frame_flag),a
        call    bench_poll
        ld      hl,(bench_frames)
        ld      de,1
        or      a
        sbc     hl,de
        ld      a,10
        call    t_expect_z

        ; --- bench_window_begin arms a BENCH_WINDOW_SECONDS window and
        ; bench_window_expired retires exactly one second per observed
        ; change of the clock's second field, never more.
        xor     a
        ld      (rtc_second),a
        ld      (rtc_mock_counter),a
        ld      a,1
        ld      (rtc_present),a
        ld      (rtc_valid),a
        ld      a,3                     ; 3 samples per simulated second
        ld      (rtc_mock_period),a
        call    bench_window_begin
        ld      a,14
        call    t_expect_nc             ; clock present -> window armed
        ld      a,(bench_seconds_left)
        cp      BENCH_WINDOW_SECONDS
        ld      a,15
        call    t_expect_z

        ; Count how many bench_window_expired calls the window survives:
        ; with 3 samples per second it must be 3*BENCH_WINDOW_SECONDS.
        ld      bc,0
.win:   inc     bc
        call    bench_window_expired
        jr      nz,.win
        ld      hl,BENCH_WINDOW_SECONDS*3
        or      a
        sbc     hl,bc
        ld      a,16
        call    t_expect_z

        ; --- no CMOS clock -> CF=1, so a bench shows the "no clock"
        ; marker instead of reporting a number it cannot justify.
        xor     a
        ld      (rtc_present),a
        call    bench_window_begin
        ld      a,17
        call    t_expect_c
        ld      a,1
        ld      (rtc_present),a
        ld      (rtc_valid),a
        xor     a
        ld      (rtc_valid),a
        call    bench_window_begin
        ld      a,18
        call    t_expect_c
        ld      a,1
        ld      (rtc_valid),a

        ; --- draw_bench_result honours the destination buffer it is
        ; given: with buffer 1 selected, buffer 0 must stay untouched.
        ld      hl,#c000
        ld      de,#c001
        ld      bc,#001f
        ld      (hl),#a5
        ldir
        ld      hl,#c140
        ld      de,#c141
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      ix,0
        ld      c,0
        ld      de,#1234                ; the value drawn, irrelevant here
        ld      hl,#c140                ; buffer 1
        call    draw_bench_result

        ld      a,(#c140)
        cp      #a5
        ld      a,11
        call    t_expect_nz
        ld      a,(#c000)               ; buffer 0: must NOT have been drawn
        cp      #a5
        ld      a,12
        call    t_expect_z

        ; --- and it puts draw_glyph back on buffer 0 afterwards, so the
        ; stand's own tick/RTC line keeps landing where it always has.
        ld      hl,(glyph_dest_base)
        ld      de,#c000
        or      a
        sbc     hl,de
        ld      a,13
        call    t_expect_z

        ; --- the strip bench's composed band rows must actually alternate
        ; every CELL_W_BYTES across all BOARD_COLS cells. The first version
        ; kept the second colour in C and pushed BC around the inner byte
        ; loop, so the POP undid every swap and only cell 0 differed --
        ; visible on screen as one narrow column plus a solid band, and
        ; invisible to every other check in this suite.
        call    bench_board_strip.compose

        ld      a,(bench_board_strip.row_a)             ; cell 0
        cp      #22
        ld      a,14
        call    t_expect_z
        ld      a,(bench_board_strip.row_a+CELL_W_BYTES-1)
        cp      #22
        ld      a,15
        call    t_expect_z
        ld      a,(bench_board_strip.row_a+CELL_W_BYTES) ; cell 1
        cp      #33
        ld      a,16
        call    t_expect_z
        ld      a,(bench_board_strip.row_a+2*CELL_W_BYTES) ; cell 2
        cp      #22
        ld      a,17
        call    t_expect_z
        ld      a,(bench_board_strip.row_a+7*CELL_W_BYTES) ; cell 7 (last)
        cp      #33
        ld      a,18
        call    t_expect_z

        ld      a,(bench_board_strip.row_b)             ; opposite parity
        cp      #33
        ld      a,19
        call    t_expect_z
        ld      a,(bench_board_strip.row_b+CELL_W_BYTES)
        cp      #22
        ld      a,20
        call    t_expect_z
        ld      a,(bench_board_strip.row_b+7*CELL_W_BYTES)
        cp      #22
        ld      a,21
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

        include "font_hex.asm"
        include "gfx_core.asm"
        include "text640.asm"
        include "bench_s2.asm"
