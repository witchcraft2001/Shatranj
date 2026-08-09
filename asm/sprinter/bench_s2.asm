; S2 bench screen (port.md section 5/S2): hotkey '5' benchmarks a full
; board redraw (64 cells: fill_rect + draw_tile, plus one wide draw_tile),
; hotkey '6' benchmarks repeated text_print calls and demonstrates right-
; edge clipping and both tile strides. Both read the asset page's physical
; number from HDR (published by preload_loader.asm, manifest v2) and draw
; a fallback marker glyph instead of benchmarking if none is present.
; Each bench runs for a fixed BENCH_WINDOW_SECONDS window measured off the
; CMOS clock and reports how many iterations fitted in it, plus -- as a
; cross-check only -- what the 50 Hz frame flag counted over the same
; window (bench_window_begin explains why the flag cannot be the clock).
; Both render as hex16 via font_hex.asm's draw_hex16, to be read off screen
; and recorded in docs/sprinter-render-budget.md by a human tester
; (CLAUDE.md rule 6 -- this port never claims a budget number itself).
;
; Position-independent code and data: INCLUDEd once from resident_s1.asm's
; flexible code area, after gfx_core.asm/text640.asm (which it calls into).

        IFNDEF SPRINTER_BENCH_S2_INC
        DEFINE SPRINTER_BENCH_S2_INC

        INCLUDE "dss.inc"
        INCLUDE "fixed_layout.inc"      ; HDR_ADDR (constants only, safe here)
        INCLUDE "hdr.inc"
        INCLUDE "render_layout.inc"

BOARD_X_BYTE  EQU BOARD_X/2
CELL_W_BYTES  EQU BOARD_CELL_W/2

; Asset page slot layout: must match tools/make_sprinter_assets_page.py
; (no generated bridge for these -- same convention as the manifest
; offsets shared by hand between manifest.inc and make_sprinter_exe.py).
TILE_A_SLOT    EQU 28
TILE_KEY_SLOT  EQU 30
TILE_WIDE_SLOT EQU 32

; Measurement window, in whole RTC seconds. Both benches run "as many
; iterations as fit in this window" rather than "this many iterations,
; timed" -- see bench_window_begin for why the 50 Hz frame flag cannot be
; the clock here.
BENCH_WINDOW_SECONDS EQU 4

; Text lines are cheap enough that one DSS SysTime call per line would
; dominate the measurement, so the window is checked once per batch of
; this many lines. The board bench checks after every redraw.
BENCH_TEXT_BATCH  EQU 64

; Demo tiles sit clear of the S1 stand's own live overlay (tick counter at
; pixel (16,16), RTC at (16,32), redrawn every frame into buffer 0): a tile
; at x=16 gets half-overprinted by the counter within one frame of being
; drawn, which reads as a corrupt raster rather than as overlap.
DEMO_TILE_X      EQU 216
DEMO_WIDE_TILE_X EQU 264
; Second #FF-key tile, drawn over a colour patch instead of over black --
; the only placement in which the hardware key's effect is visible at all
; (see bench_text's comment at the draw site).
DEMO_KEY_FILL_X  EQU 312

; --- one-time setup ---------------------------------------------------

; Reads the asset page's physical number from HDR (0 pages -> #FF, the
; "unavailable" marker both bench routines check). Called once from crt0.
; Clobbers AF.
bench_init:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGES_OFFSET)
        or      a
        jr      nz,.have
        ld      a,#FF
        ld      (bench_asset_page),a
        ret
.have:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET)
        ld      (bench_asset_page),a
        ld      (text_font_page),a
        ret
bench_asset_page: DB #FF

; Reads RGMOD once and stores both buffer bases: front = currently
; displayed, back = the other. Clobbers AF, HL.
resolve_buffers:
        ld      hl,#c000
        ld      (front_base),hl
        ld      hl,#c140
        ld      (back_base),hl
        in      a,(PORT_RGMOD)
        and     1
        ret     z               ; bit0=0 -> buf0 displayed (already set)
        ld      hl,#c140
        ld      (front_base),hl
        ld      hl,#c000
        ld      (back_base),hl
        ret
front_base: DW 0
back_base:  DW 0

; --- elapsed-frame counter --------------------------------------------
;
; resident_s1.asm's tick_count is NOT usable as a bench clock: the IM2 stub
; only latches frame_flag, and it is main_loop that turns each flag into a
; tick_count increment -- and main_loop does not run while a bench does, so
; tick_count would be frozen for the whole measurement and every result
; would read 0000. A bench therefore counts frames itself.
;
; bench_poll consumes one pending frame_flag and adds one frame to
; bench_frames. It must be called with interrupts enabled and often enough
; that no two frame ticks fall between two calls: the flag latches, it does
; not count, so two ticks spanned by one poll interval read as one. The
; calls below sit one per board cell and one per text line -- far finer
; than the ~20 ms tick.
;
; This counter is NOT the bench clock -- measurement on real hardware
; showed it undercounts by a large and variable amount under bench load
; (see bench_window_begin). It is kept and displayed alongside the real
; result precisely so that undercount stays visible rather than silently
; shaping a budget number. Clobbers AF, HL.
bench_frames: DW 0

; Clears the counter and any stale flag. Clobbers AF, HL.
bench_frames_reset:
        di
        xor     a
        ld      (frame_flag),a
        ld      hl,0
        ld      (bench_frames),hl
        ei
        ret

; Read-and-clear runs under DI so a tick landing between the two cannot be
; dropped. Clobbers AF, HL.
bench_poll:
        di
        ld      a,(frame_flag)
        or      a
        jr      z,.idle
        xor     a
        ld      (frame_flag),a
        ei
        ld      hl,(bench_frames)
        inc     hl
        ld      (bench_frames),hl
        ret
.idle:  ei
        ret

; --- measurement window (RTC-based) ------------------------------------
;
; The frame counter above is kept, but only as a cross-check: it turned out
; NOT to be a usable clock for a bench. A bench holds DI almost
; continuously (text_print keeps it for a whole string), and under that
; load the 50 Hz tick is not reliably observed -- three runs of the
; identical 50-redraw board loop reported 0x15, 0x0F and 0x08 frames, and
; the text loop reported 0x0000 whether it ran 100 or 1000 lines. Whatever
; the mechanism (a tick arriving inside a long DI span, or the IM2 stub
; classifying it as a keyboard interrupt because SIO RR0 bit 0 is set by
; then -- resident_s1.asm's im2_stub), the flag undercounts by a variable
; amount, so a number derived from it cannot support a budget claim.
;
; DSS SysTime is immune to all of that: it reads the CMOS clock, not an
; interrupt this code might miss. It costs a DSS RST, so it is sampled
; between iterations (never inside one -- R1/R3: no RST while WIN0/WIN3 are
; remapped under DI) and its 1-second resolution is turned into precision
; by measuring "how many iterations fit in BENCH_WINDOW_SECONDS" instead of
; "how long N iterations took".
;
; Aligns to the next whole second and arms the window. CF=1 (and no window
; armed) if the machine has no CMOS clock, which rtc_sample reports via
; rtc_valid. Clobbers AF, BC, DE, HL.
bench_window_begin:
        ld      a,(rtc_present)
        or      a
        scf
        ret     z
        call    rtc_sample
        ld      a,(rtc_valid)
        or      a
        scf
        ret     z
        ld      a,(rtc_second)
        ld      (bench_last_second),a
        ; Start on a second boundary, so the window really is
        ; BENCH_WINDOW_SECONDS long and not that minus a random fraction
        ; of the first second.
.align:
        call    rtc_sample
        ld      a,(rtc_second)
        ld      hl,bench_last_second
        cp      (hl)
        jr      z,.align
        ld      (bench_last_second),a
        ld      a,BENCH_WINDOW_SECONDS
        ld      (bench_seconds_left),a
        or      a                       ; CF=0: window armed
        ret

; Samples the clock and retires one second from the window each time it
; changes. Returns Z when the window has closed. Clobbers AF, BC, DE, HL.
bench_window_expired:
        call    rtc_sample
        ld      a,(rtc_second)
        ld      hl,bench_last_second
        cp      (hl)
        jr      z,.running
        ld      (hl),a
        ld      hl,bench_seconds_left
        dec     (hl)
.running:
        ld      a,(bench_seconds_left)
        or      a
        ret
bench_last_second:  DB 0
bench_seconds_left: DB 0

; Draws GLYPH_C at (16,232) into the displayed buffer: "no CMOS clock, the
; bench cannot time itself". Clobbers AF, BC, DE, HL, IX.
draw_no_clock_marker:
        ld      hl,(front_base)
        ld      (glyph_dest_base),hl
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a
        ld      ix,16
        ld      c,232
        ld      a,GLYPH_C
        call    draw_glyph
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        jp      restore_glyph_base
.saved_win3: DB 0

; Draws GLYPH_F at (16,232) into the currently displayed buffer -- shown
; instead of a benchmark when no asset page is available. Clobbers AF, BC,
; DE, HL, IX.
draw_no_assets_marker:
        call    resolve_buffers
        ld      hl,(front_base)
        ld      (glyph_dest_base),hl
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a
        ld      ix,16
        ld      c,232
        ld      a,GLYPH_F
        call    draw_glyph
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        jp      restore_glyph_base
.saved_win3: DB 0

; IX=x, C=y, DE=value, HL=destination buffer base (#C000/#C140): draws a
; hex16 result via font_hex.asm's draw_hex16, handling its own DI/WIN3
; setup. The base is explicit because a bench may have flipped buffers
; since it started, and draw_glyph's default targets buffer 0 -- a result
; written into the buffer that is no longer displayed is invisible.
; Clobbers AF, BC, DE, HL, IX.
draw_bench_result:
        ld      (glyph_dest_base),hl
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a
        call    draw_hex16
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        jp      restore_glyph_base
.saved_win3: DB 0

; Puts draw_glyph back on buffer 0, the S1 stand's own target, so main_loop
; keeps drawing its tick/RTC line where it always has. Clobbers HL.
restore_glyph_base:
        ld      hl,#C000
        ld      (glyph_dest_base),hl
        ret

; --- hotkey '7': CPU clock probe --------------------------------------

; Counts how many fixed-cost units fit in the same BENCH_WINDOW_SECONDS
; window and reports it as hex16 at (16,244). Without this the render
; numbers cannot be interpreted at all: Sprinter runs the Z80 at either
; 7 MHz or 21 MHz (turbo, CMOS register #1B bit 0 at boot / the machine's
; own hotkey -- sprinter_ai_doc manual 09_advanced/02_turbo.md), the Z80
; has no register reporting which, and a 3x clock difference moves every
; ms/operation figure by 3x. This port deliberately does NOT switch turbo
; itself -- CPU speed is the machine's policy, not an application's -- it
; only measures what it was given, so the budget table can say which
; machine state a number belongs to.
;
; One unit is 256 DJNZ iterations = 256*13 - 5 = 3323 T-states, so
;   effective MHz ~= count * 3323 / (BENCH_WINDOW_SECONDS * 1e6)
; Expected: ~0x20E0 (8416) at 7 MHz, ~0x62B0 (25248) at 21 MHz. Memory
; wait states differ between the two modes, so treat this as "which of the
; two", not as a calibrated frequency counter.
CPU_PROBE_BATCH EQU 64

bench_cpu_probe:
        call    resolve_buffers
        ld      hl,0
        ld      (.count),hl
        call    bench_window_begin
        jp      c,draw_no_clock_marker
.batch:
        ld      a,CPU_PROBE_BATCH
        ld      (.batch_left),a
.unit:
        ld      b,0                     ; 0 -> 256 iterations
.spin:  djnz    .spin
        ld      hl,.batch_left
        dec     (hl)
        jr      nz,.unit
        ld      hl,(.count)
        ld      de,CPU_PROBE_BATCH
        add     hl,de
        jr      c,.done                 ; 16-bit count would wrap
        ld      (.count),hl
        call    bench_window_expired
        jr      nz,.batch
.done:
        ld      de,(.count)
        ld      ix,16
        ld      c,INPUT_Y
        ld      hl,(front_base)
        call    draw_bench_result
        ret
.count:      DW 0
.batch_left: DB 0

; --- hotkey '8': accelerator block-size sweep -------------------------

; Fills the SAME area (PROBE_W bytes x PROBE_H rows, the board rectangle)
; three ways, one BENCH_WINDOW_SECONDS window each, and reports how many
; full fills each way completed:
;
;   1. one PROBE_W-byte accelerator operation per row   (PROBE_H ops)
;   2. PROBE_W/PROBE_CHUNK small operations per row     (8x as many ops)
;   3. plain CPU stores, no accelerator at all          (no ops)
;
; Same bytes, same rows, same PORT_Y traffic; only the block size and the
; mechanism differ, so the three counts isolate exactly one variable.
;
; This exists because the S2 budget numbers turned out to be dominated by
; the accelerator's fixed per-operation cost, not by bytes moved.
; HW_NOTES.md section 4 quotes 256 bytes in ~37 us (0.145 us/byte); a
; 2026-08-09 MAME run of this port's 16-24-byte operations measured
; 1.43 us/byte. Every reference implementation sizes its blocks far larger
; (flappybird 138-byte rows, flexnavigator's window-height vertical copies,
; spevosdk's 160-byte screen fills) and spevosdk drops the accelerator
; entirely for 4-byte tile rows in favour of unrolled LDI. Reading:
;
;   count1 >> count2  -> block size is the whole story; the primitives must
;                        issue fewer, larger operations.
;   count2 ~ count3   -> at that block size the accelerator buys nothing and
;                        a CPU path is the right fallback below a threshold.
;   all three equal   -> the machine under test is not accelerating at all
;                        (suspect the emulator, then re-run on hardware).
PROBE_W     EQU 192             ; bytes per row (384 px, the board width)
PROBE_H     EQU 192             ; rows (the board height)
PROBE_CHUNK EQU 24              ; small-block size = one board cell's width

probe_base:      DW 0
probe_fill_byte: DB 0

bench_accel_probe:
        call    resolve_buffers
        ld      hl,(back_base)          ; hidden buffer: no strobing
        ld      (probe_base),hl
        ld      a,#22                   ; colour 2, packed
        ld      (probe_fill_byte),a

        xor     a
        call    .run_window
        jp      c,draw_no_clock_marker
        ld      ix,88
        call    .show

        ld      a,1
        call    .run_window
        jp      c,draw_no_clock_marker
        ld      ix,144
        call    .show

        ld      a,2
        call    .run_window
        jp      c,draw_no_clock_marker
        ld      ix,200
        call    .show
        ret

; A=mode. Runs one window, leaving the fill count in .count. CF=1 if the
; machine has no clock to measure against.
.run_window:
        ld      (.mode),a
        ld      hl,0
        ld      (.count),hl
        call    bench_window_begin
        ret     c
.loop:
        ld      a,(.mode)
        call    probe_fill_area
        ld      hl,(.count)
        inc     hl
        ld      (.count),hl
        call    bench_window_expired
        jr      nz,.loop
        or      a                       ; CF=0
        ret
.show:
        ld      de,(.count)
        ld      c,INPUT_Y
        ld      hl,(front_base)
        jp      draw_bench_result
.mode:  DB 0
.count: DW 0

; A=mode (0 = one PROBE_W-byte accelerator operation per row, 1 =
; PROBE_W/PROBE_CHUNK small ones, 2 = CPU stores). Fills the probe area
; from probe_base with probe_fill_byte. Clobbers AF, BC, DE, HL.
probe_fill_area:
        ld      (.mode),a

        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a

        ; .afill sits inside this DI span for the same linear-scan reason
        ; as gfx_core.asm's own helpers.
        jr      .begin
; HL=row address, A=block size. One horizontal accelerator fill.
.afill:
        ld      (.size+1),a
        ld      a,(probe_fill_byte)
        ld      e,a
        ACC_SET_SIZE
.size:  ld      a,0
        ACC_FILL_H
        ld      a,e
        ld      (hl),a
        ACC_OFF
        ret
.begin:
        ld      a,BOARD_Y
        ld      (.row),a
        ld      a,PROBE_H
        ld      (.rows_left),a
.row_loop:
        ld      a,(.row)
        out     (PORT_Y),a
        ld      hl,(probe_base)
        ld      de,BOARD_X_BYTE
        add     hl,de
        ld      a,(.mode)
        or      a
        jr      z,.big
        dec     a
        jr      z,.small

        ld      a,(probe_fill_byte)
        ld      e,a
        ld      b,PROBE_W
.cpu:   ld      (hl),e
        inc     hl
        djnz    .cpu
        jr      .next_row
.big:
        ld      a,PROBE_W
        call    .afill
        jr      .next_row
.small:
        ld      b,PROBE_W/PROBE_CHUNK
.small_loop:
        push    bc
        push    hl
        ld      a,PROBE_CHUNK
        call    .afill
        pop     hl
        ld      de,PROBE_CHUNK
        add     hl,de
        pop     bc
        djnz    .small_loop
.next_row:
        ld      hl,.row
        inc     (hl)
        ld      hl,.rows_left
        dec     (hl)
        jr      nz,.row_loop

        acc_park_y
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.mode:       DB 0
.row:        DB 0
.rows_left:  DB 0
.saved_win3: DB 0

; --- hotkey '5': full board redraw -----------------------------------

; 64 cells (fill_rect 48x24 checkerboard + draw_tile 32x16) plus one
; draw_tile 40x20 = one redraw, repeated into the back buffer for
; BENCH_WINDOW_SECONDS. Two hex16 results land in the STATUS band, clear of
; the board: the redraw COUNT at (16,232) -- the authoritative number,
; ms/redraw = BENCH_WINDOW_SECONDS*1000 / count -- and the frame counter's
; own reading at (72,232), kept only so the tester can see how badly the
; 50 Hz flag undercounts under this load (bench_window_begin).
;
; Flips once at the end so the result is visible (the redraw loop never
; flips, so per-iteration cost is not diluted by the flip) -- and the
; results then go into the buffer that flip just brought to the front, not
; into buffer 0.
bench_board:
        ld      a,(bench_asset_page)
        cp      #FF
        jp      z,draw_no_assets_marker

        call    resolve_buffers
        ; Clear first, outside the timed loop: without it the board is
        ; composited over whatever the S1 stand left in this buffer (its
        ; 16-stripe grid), and "the checkerboard is clean" stops being a
        ; checkable statement. Clearing is setup, not part of a redraw --
        ; the real UI repaints the board over itself -- so it stays out of
        ; the measurement.
        xor     a                       ; colour 0 = black
        ld      hl,(back_base)
        call    gfx_clear_buffer

        call    bench_frames_reset
        ld      hl,0
        ld      (.count),hl
        call    bench_window_begin
        jp      c,draw_no_clock_marker
.iter:
        call    .draw_board_once
        ld      hl,(.count)
        inc     hl
        ld      (.count),hl
        call    bench_window_expired
        jr      nz,.iter

        call    gfx_swap_buffers

        ld      de,(.count)
        ld      ix,16
        ld      c,232
        ld      hl,(back_base)          ; the flip just made this the front
        call    draw_bench_result
        ld      de,(bench_frames)
        ld      ix,72
        ld      c,232
        ld      hl,(back_base)
        call    draw_bench_result
        ret
.count: DW 0

; Draws the 64-cell board once into back_base, plus one 40x20 tile.
; Clobbers AF, BC, DE, HL, IX.
.draw_board_once:
        xor     a
        ld      (.row),a
.row_loop:
        xor     a
        ld      (.col),a
.col_loop:
        ld      a,(.row)
        ld      b,a
        ld      a,(.col)
        add     a,b
        and     1
        add     a,2                     ; checkerboard: colour 2 or 3

        push    af
        ld      a,(.col)
        ld      b,CELL_W_BYTES
        call    .mul_b                  ; A = col * CELL_W_BYTES
        add     a,BOARD_X_BYTE
        ld      (.x_byte),a
        ld      a,(.row)
        ld      b,BOARD_CELL_H
        call    .mul_b                  ; A = row * BOARD_CELL_H
        add     a,BOARD_Y
        ld      (.y),a
        pop     af

        push    af                      ; colour, restored just before the call
        ld      a,(.x_byte)
        ld      b,a
        ld      a,(.y)
        ld      c,a
        ld      d,CELL_W_BYTES
        ld      e,BOARD_CELL_H
        ld      hl,(back_base)
        pop     af
        call    gfx_fill_rect

        ld      a,(bench_asset_page)
        ld      (tile_src_page),a
        ld      a,TILE_A_SLOT
        ld      (tile_src_slot),a
        ld      a,16
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      a,16
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_OPAQUE
        ld      (tile_alias),a
        ld      hl,(back_base)
        ld      (tile_dest_base),hl
        ld      a,(.x_byte)
        ld      (tile_x_byte),a
        ld      a,(.y)
        ld      (tile_y),a
        call    gfx_draw_tile
        call    bench_poll              ; one poll per cell (see bench_poll)

        ld      hl,.col
        inc     (hl)
        ld      a,(hl)
        cp      BOARD_COLS
        jp      c,.col_loop

        ld      hl,.row
        inc     (hl)
        ld      a,(hl)
        cp      BOARD_ROWS
        jp      c,.row_loop

        ; One 40x20 tile (TILE_WIDE_SLOT, stride 20), proving the second
        ; parametric stride in the same pass. Placed in the MENU band and
        ; to the right of the board's own column: 20 rows do not fit the
        ; 12-row MOVE band, and starting it there would have run 8 rows
        ; into the board's top-left cell, muddying P3's "checkerboard is
        ; clean" visual check.
        ld      a,(bench_asset_page)
        ld      (tile_src_page),a
        ld      a,TILE_WIDE_SLOT
        ld      (tile_src_slot),a
        ld      a,20
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      a,20
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_OPAQUE
        ld      (tile_alias),a
        ld      hl,(back_base)
        ld      (tile_dest_base),hl
        ld      a,DEMO_TILE_X/2
        ld      (tile_x_byte),a
        ld      a,MENU_Y
        ld      (tile_y),a
        call    gfx_draw_tile
        call    bench_poll
        ret
.row: DB 0
.col: DB 0
.x_byte: DB 0
.y: DB 0

; A = A * B by repeated addition (A is always a small loop index here --
; col/row 0..7 -- and B a byte constant, so the product comfortably fits a
; byte: max 7*24=168). Clobbers B, C.
.mul_b:
        or      a
        jr      z,.mul_zero             ; A already 0
        ld      c,a                     ; C = remaining iterations
        xor     a                       ; A = accumulator
.mul_loop:
        add     a,b
        dec     c
        jr      nz,.mul_loop
.mul_zero:
        ret

; --- hotkey '9': board redraw, full-width strip strategy ----------------

; The same visible result as hotkey '5' -- an 8x8 checkerboard filling the
; board rectangle -- drawn the way the measurement says it has to be drawn:
; two 192-byte rows are composed once in RAM, then each 24-row band is one
; gfx_blit_rows call with stride 0, so the whole board is 192 accelerator
; operations of 192 bytes instead of 2 560 operations of 16-24 bytes.
;
; This is the bench that answers the S2 DoD ("full board redraw <= 1
; frame"). Hotkey '5' is kept beside it as the per-cell baseline: the pair
; is the evidence for the strategy, not the strategy itself. Pieces are not
; composed in here -- doing that for real is the UI stage's job and needs a
; staging buffer sized for a whole band; what this proves is that the
; board-sized byte movement fits the budget once the operations are large.
;
; Count renders at (256,244); ms per redraw = BENCH_WINDOW_SECONDS*1000 /
; count, same conversion as every other bench here.
BOARD_STRIP_W EQU 192           ; bytes = 8 cells * CELL_W_BYTES (384 px)

bench_board_strip:
        call    resolve_buffers
        xor     a
        ld      hl,(back_base)
        call    gfx_clear_buffer
        call    .compose

        ld      hl,0
        ld      (.count),hl
        call    bench_window_begin
        jp      c,draw_no_clock_marker
.iter:
        call    .draw_once
        ld      hl,(.count)
        inc     hl
        ld      (.count),hl
        call    bench_window_expired
        jr      nz,.iter

        call    gfx_swap_buffers
        ld      de,(.count)
        ld      ix,256
        ld      c,INPUT_Y
        ld      hl,(back_base)          ; the flip just made this the front
        call    draw_bench_result
        ret
.count: DW 0

; Builds the two band rows: .row_a starts on colour 2, .row_b on colour 3.
; Clobbers AF, BC, DE, HL.
.compose:
        ld      hl,.row_a
        ld      a,#22
        ld      c,#33
        call    .compose_one
        ld      hl,.row_b
        ld      a,#33
        ld      c,#22
        ; fall through
; HL=destination row, A=first cell colour byte, C=second. The two colours
; live in memory, not in registers: the cell loop has to PUSH BC to protect
; its counter from the inner byte loop, and a POP would then undo any swap
; done in C -- which is exactly the bug the first version of this shipped
; with (every cell after the first came out the same colour).
.compose_one:
        ld      (.c0),a
        ld      a,c
        ld      (.c1),a
        ld      b,BOARD_COLS
.cell:
        push    bc
        ld      a,(.c0)
        ld      b,CELL_W_BYTES
.cell_byte:
        ld      (hl),a
        inc     hl
        djnz    .cell_byte
        ld      a,(.c0)                 ; swap the two cell colours
        ld      d,a
        ld      a,(.c1)
        ld      (.c0),a
        ld      a,d
        ld      (.c1),a
        pop     bc
        djnz    .cell
        ret
.c0: DB 0
.c1: DB 0

; One full board: 8 bands, each one gfx_blit_rows of BOARD_CELL_H rows.
; Clobbers AF, BC, DE, HL.
.draw_once:
        ld      a,BOARD_X_BYTE
        ld      (tile_x_byte),a
        ld      a,BOARD_STRIP_W
        ld      (tile_width),a
        xor     a
        ld      (tile_stride),a         ; 0 = repeat the composed row
        ld      (.parity),a
        ld      a,BOARD_CELL_H
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_OPAQUE
        ld      (tile_alias),a
        ld      hl,(back_base)
        ld      (tile_dest_base),hl
        ld      a,BOARD_Y
        ld      (.y),a
        ld      b,BOARD_ROWS
.band:
        push    bc
        ld      a,(.y)
        ld      (tile_y),a
        ld      a,(.parity)
        or      a
        ld      hl,.row_a
        jr      z,.have_row
        ld      hl,.row_b
.have_row:
        call    gfx_blit_rows
        ld      a,(.parity)
        xor     1
        ld      (.parity),a
        ld      a,(.y)
        add     a,BOARD_CELL_H
        ld      (.y),a
        pop     bc
        djnz    .band
        ret
.y:      DB 0
.parity: DB 0
.row_a:  DS BOARD_STRIP_W,0
.row_b:  DS BOARD_STRIP_W,0

; --- hotkey '6': text bench + clip/tile-stride demo --------------------

bench_text_str: DB "Shatranj Sprinter S2 render bench line",0
bench_clip_str: DB "this line runs past the right edge!!!!",0

; As many text_print calls as fit in BENCH_WINDOW_SECONDS, at a fixed spot
; (front buffer, so the results are visible without a flip). Two hex16
; results, mirroring bench_board's pair: the line COUNT at (200,232) --
; authoritative, ms/line = BENCH_WINDOW_SECONDS*1000 / count -- and the
; frame counter's reading at (256,232) for comparison. Then a one-off clip
; demo (a string placed to cross the 320-byte row edge) and one draw_tile
; per stride, to visually confirm the hardware-key alias and the 40x20
; stride.
;
; bench_text_str is 38 characters = 95 byte-columns in this font, and
; PANEL_X/2 = 204, so 204+95 = 299 <= 320: the whole line is rendered, not
; silently clipped. Both the string and its position are fixed in code
; precisely so the number stays reproducible across runs.
bench_text:
        ld      a,(bench_asset_page)
        cp      #FF
        jp      z,draw_no_assets_marker

        call    resolve_buffers
        xor     a                       ; same reasoning as bench_board
        ld      hl,(front_base)
        call    gfx_clear_buffer

        call    bench_frames_reset
        ld      hl,0
        ld      (.count),hl
        call    bench_window_begin
        jp      c,draw_no_clock_marker
.batch:
        ld      a,BENCH_TEXT_BATCH
        ld      (.batch_left),a
.line:
        ld      de,bench_text_str
        ld      ix,PANEL_X
        ld      c,PANEL_MOVES_Y
        ld      a,1                     ; bg=0, fg=1 (white on black)
        ld      hl,(front_base)
        call    text_print
        call    bench_poll              ; one poll per line (see bench_poll)
        ld      hl,.batch_left
        dec     (hl)
        jr      nz,.line
        ld      hl,(.count)
        ld      de,BENCH_TEXT_BATCH
        add     hl,de
        jr      c,.done                 ; 16-bit count would wrap: stop here
        ld      (.count),hl
        call    bench_window_expired
        jr      nz,.batch
.done:
        ld      de,(.count)
        ld      ix,200
        ld      c,232
        ld      hl,(front_base)
        call    draw_bench_result
        ld      de,(bench_frames)
        ld      ix,256
        ld      c,232
        ld      hl,(front_base)
        call    draw_bench_result

        ; Clip demo: placed to cross the 320-byte row edge on purpose.
        ld      de,bench_clip_str
        ld      ix,560
        ld      c,INPUT_Y
        ld      a,1
        ld      hl,(front_base)
        call    text_print

        ; Both tile strides, drawn once for visual confirmation.
        ;
        ; The #FF-key tile is drawn TWICE, and the pair is the whole point:
        ; a hardware-skipped #FF byte and an opaque black byte are the same
        ; pixel, so a key tile drawn only onto the cleared (black) buffer
        ; looks identical whether the #58 alias works or not. The
        ; 2026-08-09 hardware run proved exactly nothing about the key for
        ; that reason (docs/sprinter-testnotes/S2.md P4). The second copy
        ; goes over a solid colour patch, where a working key shows the
        ; patch through the #FF fields and a broken one punches a black
        ; rectangle -- two outcomes that actually differ on screen.
        ld      a,(bench_asset_page)
        ld      (tile_src_page),a
        ld      a,TILE_KEY_SLOT
        ld      (tile_src_slot),a
        ld      a,16
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      a,16
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_KEY
        ld      (tile_alias),a
        ld      hl,(front_base)
        ld      (tile_dest_base),hl
        ld      a,DEMO_TILE_X/2
        ld      (tile_x_byte),a
        ld      a,MENU_Y
        ld      (tile_y),a
        call    gfx_draw_tile

        ; Copy 2: colour patch first, key tile over it.
        ld      a,4                     ; patch colour, distinct from the
        ld      b,DEMO_KEY_FILL_X/2     ; tile's own palette entries
        ld      c,MENU_Y
        ld      d,16                    ; 32 pixels wide
        ld      e,16                    ; 16 rows: exactly the tile
        ld      hl,(front_base)
        call    gfx_fill_rect

        ld      a,(bench_asset_page)
        ld      (tile_src_page),a
        ld      a,TILE_KEY_SLOT
        ld      (tile_src_slot),a
        ld      a,16
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      a,16
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_KEY
        ld      (tile_alias),a
        ld      hl,(front_base)
        ld      (tile_dest_base),hl
        ld      a,DEMO_KEY_FILL_X/2
        ld      (tile_x_byte),a
        ld      a,MENU_Y
        ld      (tile_y),a
        call    gfx_draw_tile

        ld      a,(bench_asset_page)
        ld      (tile_src_page),a
        ld      a,TILE_WIDE_SLOT
        ld      (tile_src_slot),a
        ld      a,20
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      a,20
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_OPAQUE
        ld      (tile_alias),a
        ld      hl,(front_base)
        ld      (tile_dest_base),hl
        ld      a,DEMO_WIDE_TILE_X/2
        ld      (tile_x_byte),a
        ld      a,MENU_Y
        ld      (tile_y),a
        call    gfx_draw_tile
        ret
.count:      DW 0
.batch_left: DB 0

        ENDIF
