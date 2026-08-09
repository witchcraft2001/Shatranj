; Full S1 video stand (port.md section 5/S1 step 6): 16-colour palette in
; both banks (R10), a 16-stripe grid on both VRAM buffers with a marker
; difference between them (proves the flip), and the hotkey probes the
; stage exists to validate: '1' flip, '2' accelerator smoke (FILL_H/
; FILL_V/COPY_H, each CPU-verified), '3' WIN0-under-DI probe, '4' mode
; switch #82->#81->#82 with redraw, 'Q' exit. Replaces resident_s1.asm's
; step-5 fill_screen_demo/main_loop; the fixed-address skeleton is
; unchanged.
;
; Position-independent code and data, INCLUDEd once from resident_s1.asm's
; flexible code area (after im2_s1.asm/font_hex.asm, which it calls into).

        IFNDEF SPRINTER_VIDEO_S1_INC
        DEFINE SPRINTER_VIDEO_S1_INC

        INCLUDE "dss.inc"
        INCLUDE "win0.inc"
        INCLUDE "accel.inc"

GRID_TOP    EQU 64
GRID_HEIGHT EQU 168
STRIPE_COUNT EQU 16
STRIPE_BYTES EQU 20             ; 320 bytes / 16 stripes = 20 bytes/stripe

; --- palette -----------------------------------------------------------

; 16 RGB8 triples, a conventional EGA-like ramp (index 0 = black is the
; grid/counter background; DSS_VMOD_G640's own colour-16 semantics are
; documented in port.md section 3.5).
palette_rgb:
        DB 0x00,0x00,0x00        ; 0 black
        DB 0x00,0x00,0xAA        ; 1 blue
        DB 0x00,0xAA,0x00        ; 2 green
        DB 0x00,0xAA,0xAA        ; 3 cyan
        DB 0xAA,0x00,0x00        ; 4 red
        DB 0xAA,0x00,0xAA        ; 5 magenta
        DB 0xAA,0x55,0x00        ; 6 brown
        DB 0xAA,0xAA,0xAA        ; 7 light gray
        DB 0x55,0x55,0x55        ; 8 dark gray
        DB 0x55,0x55,0xFF        ; 9 light blue
        DB 0x55,0xFF,0x55        ; 10 light green
        DB 0x55,0xFF,0xFF        ; 11 light cyan
        DB 0xFF,0x55,0x55        ; 12 light red
        DB 0xFF,0x55,0xFF        ; 13 light magenta
        DB 0xFF,0xFF,0x55        ; 14 yellow
        DB 0xFF,0xFF,0xFF        ; 15 white

; Writes all 16 entries to both palette banks (R10: SetVMod for screen 1
; then 0 is the loader's job; the palette itself must still land in both
; banks or one screen shows stale colours). WIN3 already carries VRAM at
; this point in video_init's caller; no DI needed for palette I/O itself
; (WIN3, not WIN0), but the caller's DI/WIN3-mapping wraps this anyway
; alongside the grid draw for a single atomic setup pass.
write_palette:
        ld      hl,palette_rgb
        ld      b,0
.next:  ld      a,b
        out     (PORT_Y),a
        push    bc
        push    hl
        ld      de,#C3E0
        ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     de
        ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     de
        ld      a,(hl)
        ld      (de),a
        inc     de
        xor     a               ; 4th entry byte: the proven palette.inc
        ld      (de),a          ; donor zeroes it unconditionally per bank
        pop     hl
        push    hl
        ld      de,#C3E4
        ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     de
        ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     de
        ld      a,(hl)
        ld      (de),a
        inc     de
        xor     a
        ld      (de),a
        pop     hl
        ld      de,3
        add     hl,de
        pop     bc
        inc     b
        ld      a,b
        cp      STRIPE_COUNT
        jr      c,.next
        ret

; --- grid ----------------------------------------------------------------

; Fill VRAM buffer base DE (#C000 for buf0, #C140 for buf1) with
; STRIPE_COUNT vertical colour stripes across GRID_TOP..GRID_TOP+
; GRID_HEIGHT-1. A=stripe 0 colour override (used to give buf1 a visible
; marker distinct from buf0; pass 0 for "no override", i.e. stripe i uses
; colour i for both). Clobbers AF, BC, DE, HL.
draw_grid:
        ld      (.buf_base),de
        ld      (.stripe0_override),a
        ld      a,GRID_TOP
        ld      (.row),a
.row_loop:
        ld      a,(.row)
        out     (PORT_Y),a
        ld      de,(.buf_base)
        ld      b,0                     ; stripe index
.stripe:
        ld      a,b
        or      a
        jr      nz,.colour_ready
        ld      a,(.stripe0_override)
        or      a
        jr      z,.colour_ready
        dec     a                       ; override is colour+1 (0 = "none")
.colour_ready:
        ld      c,a
        ld      a,c
        rlca
        rlca
        rlca
        rlca
        or      c                       ; both nibbles = colour index
        push    bc
        ld      b,STRIPE_BYTES          ; byte counter in B: the fill byte
                                         ; stays in A for the whole run (a
                                         ; 16-bit HL counter would need an
                                         ; A-clobbering H|L zero test)
.fill:  ld      (de),a
        inc     de
        djnz    .fill
        pop     bc
        inc     b
        ld      a,b
        cp      STRIPE_COUNT
        jr      c,.stripe

        ld      a,(.row)
        inc     a
        ld      (.row),a
        cp      GRID_TOP + GRID_HEIGHT
        jr      c,.row_loop
        ret
.buf_base: DW 0
.stripe0_override: DB 0
.row: DB 0

; --- video_init ------------------------------------------------------------

; Sets up the palette and both VRAM buffers. Call once at boot and again
; after any mode switch (which resets VRAM/palette). Clobbers AF,BC,DE,HL.
video_init:
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,#50
        out     (WIN3_PORT),a

        call    write_palette
        ld      de,#C000
        xor     a
        call    draw_grid
        ld      de,#C140
        ld      a,16                    ; buf1 marker: stripe 0 forced white
        call    draw_grid

        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.saved_win3: DB 0

; --- decimal digit rendering (RTC display) --------------------------------

; A=value 0..99, IX=pixel X (even, start column) on entry, C=pixel Y (top
; row). Draws 2 decimal glyphs, advancing the cursor by 2*GLYPH_WIDTH.
;
; Mirrors font_hex.asm's draw_hex16: draw_glyph clobbers IX internally (its
; own font-table pointer) and advances its own C by GLYPH_WIDTH per row, so
; neither the running X cursor nor Y can be carried in a register across
; the call -- both are stashed in memory and reloaded fresh before every
; glyph. Clobbers AF, BC, DE, HL, IX.
draw_decimal_byte:
        push    ix
        pop     hl
        ld      (.x),hl
        ld      b,a
        ld      a,c
        ld      (.y),a
        ld      a,b
        ld      b,0
.tens:  cp      10
        jr      c,.units
        sub     10
        inc     b
        jr      .tens
.units: ld      (.units_digit),a
        ld      a,b
        call    .digit
        ld      a,(.units_digit)
        call    .digit
        ret
.digit:
        push    af
        ld      hl,(.x)
        ld      d,h
        ld      e,l
        ld      a,(.y)
        ld      c,a
        pop     af
        call    draw_glyph
        ld      hl,(.x)
        ld      bc,GLYPH_WIDTH
        add     hl,bc
        ld      (.x),hl
        ret
.x: DW 0
.y: DB 0
.units_digit: DB 0

; --- RTC -------------------------------------------------------------------

; Samples DSS SysTime into rtc_valid/rtc_hour/rtc_minute/rtc_second.
; Gated on rtc_present (BIOS CMOS_TEST at crt0): DSS SysTime itself never
; reports a missing clock -- its .NOCMOS path returns compile-time
; defaults with CF=0 (Estex-DSS Time.asm:97-107) -- so without the gate a
; clockless machine would show the defaults as real time. The CF check is
; kept as a defensive guard only. SysTime returns H=hour, L=minute,
; B=second, binary (Time.asm:1-12, values pass through BCD2HEX).
;
; Must be called from an EI context with canonical windows -- it RSTs into
; DSS, which must not happen while WIN3 is remapped to VRAM under DI.
; main_loop runs this right before entering its DI/WIN3 draw section;
; draw_rtc below then renders the stored sample with no DSS traffic of
; its own. Clobbers AF, BC, DE, HL.
rtc_sample:
        ld      a,(rtc_present)
        or      a
        jr      z,.none
        ld      c,DSS_SYSTIME
        rst     RST_DSS
        jr      c,.none
        ld      a,h                     ; hour
        ld      (rtc_hour),a
        ld      a,l                     ; minute
        ld      (rtc_minute),a
        ld      a,b                     ; second
        ld      (rtc_second),a
        ld      a,1
        ld      (rtc_valid),a
        ret
.none:  xor     a
        ld      (rtc_valid),a
        ret

rtc_present: DB 0               ; set once by crt0 from BIOS CMOS_TEST
rtc_valid:  DB 0
rtc_hour:   DB 0
rtc_minute: DB 0
rtc_second: DB 0

; Draws "HH MM SS" (space-separated decimal pairs) at pixel (X,Y) from the
; last rtc_sample, or three dash pairs if it reported no CMOS. IX=X (even)
; on entry, C=Y. Caller must already have WIN3 mapped to VRAM (matches
; draw_grid's contract). Clobbers AF, BC, DE, HL, IX.
draw_rtc:
        push    ix
        pop     hl
        ld      (.x),hl
        ld      a,c
        ld      (.y),a
        ld      a,(rtc_valid)
        or      a
        jr      z,.no_rtc
        ld      a,(rtc_hour)
        call    .field
        ld      a,(rtc_minute)
        call    .field
        ld      a,(rtc_second)
        call    .field
        ret
.no_rtc:
        call    .dashes
        call    .dashes
        call    .dashes
        ret
.field:
        push    af
        ld      hl,(.x)
        push    hl
        pop     ix
        ld      a,(.y)
        ld      c,a
        pop     af
        call    draw_decimal_byte
        ld      hl,(.x)
        ld      bc,GLYPH_WIDTH * 3      ; 2 digits + 1 space column
        add     hl,bc
        ld      (.x),hl
        ret
.dashes:
        ld      hl,(.x)
        push    hl
        pop     ix
        ld      a,(.y)
        ld      c,a
        ld      a,GLYPH_DASH
        call    draw_glyph
        ld      hl,(.x)
        ld      bc,GLYPH_WIDTH
        add     hl,bc
        ld      (.x),hl
        push    hl
        pop     ix
        ld      a,(.y)
        ld      c,a
        ld      a,GLYPH_DASH
        call    draw_glyph
        ld      hl,(.x)
        ld      bc,GLYPH_WIDTH * 2
        add     hl,bc
        ld      (.x),hl
        ret
.x: DW 0
.y: DB 0

; --- hotkey probes ---------------------------------------------------------

; Accelerator smoke test (R3): FILL_H, FILL_V, COPY_H against a small
; scratch VRAM region (row 240, columns 0..7 and 8..15), each verified by
; a CPU-side readback afterward. Draws GLYPH_P at (16,232) on a full pass,
; GLYPH_F at the first mismatch. Sequences are adapted from sources/libs/
; gfx640/gfx640.asm's hfill_chunk/vfill_chunk/copy_direct -- the only
; proven-on-hardware reference for this calling convention available to
; this port. MAME's accelerator emulation is not confirmed (port.md
; "Риски"); this result is authoritative only on real hardware.
; Clobbers AF, BC, DE, HL.
accel_smoke:
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,#50
        out     (WIN3_PORT),a

        ; FILL_H: 8 bytes at row 240, columns 0..7, value #37.
        ld      a,240
        out     (PORT_Y),a
        ld      hl,#C000
        ACC_SET_SIZE
        ld      a,8                     ; immediate sampled by SET_SIZE
        ACC_FILL_H
        ld      a,#37
        ld      (hl),a
        ACC_OFF
        acc_park_y
        ld      a,240
        out     (PORT_Y),a
        ld      hl,#C000
        ld      b,8
.fillh_check:
        ld      a,(hl)
        cp      #37
        jr      nz,.fail
        inc     hl
        djnz    .fillh_check

        ; FILL_V: 8 rows starting at row 200, column 0, value #48.
        ld      a,200
        out     (PORT_Y),a
        ld      hl,#C000
        ld      e,#48                   ; fill value kept in E: a second
                                         ; LD A,n here would be re-sampled
        ACC_SET_SIZE
        ld      a,8                     ; immediate sampled by SET_SIZE
        ACC_OFF                         ; donor idiom: close the size-arm
                                         ; before a fresh trigger
        ACC_FILL_V
        ld      (hl),e
        ACC_OFF
        acc_park_y
        ld      b,8
        ld      e,200                   ; row cursor in E: the readback CP
                                         ; flags must survive to the JR
.fillv_check:
        ld      a,e
        out     (PORT_Y),a
        ld      hl,#C000
        ld      a,(hl)
        cp      #48
        jr      nz,.fail
        inc     e
        djnz    .fillv_check

        ; COPY_H: 8 bytes at row 240 cols 0..7 -> row 240 cols 8..15.
        ld      a,240
        out     (PORT_Y),a
        ld      hl,#C000
        ld      de,#C008
        ACC_SET_SIZE                    ; LD D,D: D keeps #C0
        ld      a,8                     ; immediate sampled by SET_SIZE
        ACC_COPY_H                      ; LD L,L: L keeps its value too
        ld      a,(hl)
        ld      (de),a
        ACC_OFF
        acc_park_y
        ld      a,240
        out     (PORT_Y),a
        ld      hl,#C000
        ld      de,#C008
        ld      b,8
.copy_check:
        ld      a,(de)
        cp      (hl)
        jr      nz,.fail
        inc     hl
        inc     de
        djnz    .copy_check

        ld      a,GLYPH_P
        jr      .report
.fail:  ld      a,GLYPH_F
.report:
        ld      ix,16
        ld      c,232
        call    draw_glyph
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.saved_win3: DB 0

; WIN0-under-DI probe (R1): maps WIN0 to the SAME physical page currently
; in WIN1 (the resident's own WIN1 half never moves once the trampoline
; runs) and confirms the HDR magic "SHS1" at #0000 reads back identically
; to HDR at #4000 -- the same physical bytes seen through two different
; windows at once. Then restores WIN0 and confirms DSS is still alive via
; a non-blocking ScanKey. Draws GLYPH_P/GLYPH_F at (16,232), overwriting
; whatever accel_smoke last drew there. Clobbers AF, BC, DE, HL.
;
; The comparison loop sets a flag instead of branching around win0_restore:
; a single, unconditional restore call site is both better hygiene and
; what tools/check_sprinter_win0.py's pairing check (R1) expects -- it
; scans source text linearly and cannot see that only one of two branches
; runs, so two textually-sequential win0_restore calls on different paths
; would read as an unmatched close.
win0_probe:
        in      a,(WIN1_PORT)
        win0_map_di
        ld      hl,0
        ld      de,HDR
        ld      b,4
        xor     a
        ld      (.mismatch),a
.cmp:   ld      a,(de)
        cp      (hl)
        jr      z,.next
        ld      a,1
        ld      (.mismatch),a
.next:  inc     de
        inc     hl
        djnz    .cmp
        win0_restore
        ld      c,DSS_SCANKEY
        rst     RST_DSS
        ld      a,(.mismatch)
        or      a
        ld      a,GLYPH_P
        jr      z,.report
        ld      a,GLYPH_F
.report:
        push    af
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,#50
        out     (WIN3_PORT),a
        pop     af
        ld      ix,16
        ld      c,232
        call    draw_glyph
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.saved_win3: DB 0
.mismatch: DB 0

; Mode-switch probe (R10, future About-screen mechanic): #82 -> #81 -> #82
; with palette/grid redrawn afterward, since a mode switch destroys VRAM
; and the palette. Clobbers AF, BC, DE, HL.
mode_switch_probe:
        di
        ld      b,1
        ld      a,DSS_VMOD_G320
        call    svmod_safe              ; WIN2-half wrapper: SetVMod clobbers
                                         ; the WIN1 mapping and this code IS
                                         ; WIN1-half (see resident_s1.asm)
        ld      b,0
        ld      a,DSS_VMOD_G320
        call    svmod_safe
        ei
        ; A brief, deliberately approximate pause so the mode change is
        ; visible to a human tester -- exact duration depends on CPU speed
        ; (turbo/accelerator settings do not affect this loop, only the
        ; VRAM accelerator opcodes), which is not critical here.
        ld      bc,50000
.spin:  dec     bc
        ld      a,b
        or      c
        jr      nz,.spin
        di
        ld      b,1
        ld      a,DSS_VMOD_G640
        call    svmod_safe
        ld      b,0
        ld      a,DSS_VMOD_G640
        call    svmod_safe
        ei
        jp      video_init

        ENDIF
