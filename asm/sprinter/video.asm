; Production video primitives (port.md section 3.10/S5, plan D4): the
; palette and RTC-sampling pieces of the S1 stand's video_s1.asm, minus
; everything that only ever painted the stand's own debug grid (draw_grid,
; the hotkey probes, draw_decimal_byte/draw_rtc -- those depended on
; font_hex.asm's glyph renderer, deleted in the same pass; the HUD clock
; is rendered by C via text_print instead, from the rtc_* fields this file
; still owns). INCLUDEd once from platform_primitives.asm.

        IFNDEF SPRINTER_VIDEO_INC
        DEFINE SPRINTER_VIDEO_INC

        INCLUDE "dss.inc"
        INCLUDE "fixed_layout.inc"

STRIPE_COUNT EQU 16             ; palette entry count, not a stand artifact

; --- palette -----------------------------------------------------------

; 16 RGB8 triples, generated from assets/sprinter/palette.json (S4, port.md
; section 3.5): 0 bg, 1 text, 2/3 board square (theme surface), 4-7 piece
; body/outline, 8-13 HUD, 14 accent, 15 a plain colour.
        INCLUDE "palette_base.inc"

; Writes one palette entry (A=index 0..15, HL->3 RGB8 bytes) to both
; palette banks -- render.c repaints just the theme-surface indices (2/3)
; on a theme switch without re-touching the other 14. Caller must already
; have WIN3 mapped to VRAM. Clobbers AF, DE, HL (HL left one past the 3
; source bytes, matching write_palette's own advance).
write_palette_entry:
        out     (PORT_Y),a
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
        ret

; Writes all 16 entries to both palette banks (R10: SetVMod for screen 1
; then 0 is the loader's job; the palette itself must still land in both
; banks or one screen shows stale colours). Clobbers AF, BC, DE, HL.
write_palette:
        ld      hl,palette_rgb
        ld      b,0
.next:  ld      a,b
        call    write_palette_entry
        inc     b
        ld      a,b
        cp      STRIPE_COUNT
        jr      c,.next
        ret

; Sets up the palette in both VRAM buffers. Call once at boot (from C's
; main()) and again after any mode switch (which resets the palette).
; Unlike the S1 stand's video_init, does NOT touch VRAM contents -- the
; stand's debug grid is gone; the real board/panel painting is C's job.
; Clobbers AF,BC,DE,HL.
video_init:
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,#50
        out     (WIN3_PORT),a

        call    write_palette

        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.saved_win3: DB 0

; C-callable (single uint8_t arg at SP+2): z88dk's -clib=default convention
; (Small-C-derived, the only one available for +pps) promotes every scalar
; argument to a full 16-bit stack slot regardless of C type -- see
; overlay_loader_sprinter.asm's file banner for the verified detail and the
; bug that shipped from assuming otherwise. A single-argument call is the
; one case where that still lands the real value at a plain SP+2: there is
; no earlier argument's padding byte in the way.
;
; Repaints the background palette entry (index 0) with the existing
; hud_success/hud_error theme colours instead of new RGB bytes, so a human
; watching MAME sees an immediate, unambiguous
; result without this port inventing its own colour meaning. S5 substep 2
; diagnostic only (main.c's one real ovl_exec(14u,...) call) -- substep 3's
; render.c replaces this with real board/panel painting via text_print/
; gfx_draw_tile, not this palette trick. Reuses video_init's own WIN3
; save/map(#50)/restore dance verbatim: write_palette_entry itself assumes
; WIN3 is already VRAM-mapped by the caller. Clobbers AF,BC,DE,HL.
ovl_test_signal:
        ld      hl,2
        add     hl,sp
        ld      a,(hl)
        or      a
        ld      hl,palette_rgb + 11*3   ; hud_error (red) -- pass=0
        jr      z,.picked
        ld      hl,palette_rgb + 12*3   ; hud_success (green) -- pass<>0
.picked:
        push    hl
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,#50
        out     (WIN3_PORT),a
        pop     hl
        xor     a                       ; palette index 0 = background
        call    write_palette_entry
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.saved_win3: DB 0

; No arguments. Restores palette index 0 to its real "bg" colour
; (`palette_rgb`'s own entry 0, RGB `#000000` per assets/sprinter/
; palette.json), undoing ovl_test_signal's diagnostic green/red overwrite.
; Called once from C's main() after substep 3's real board/label painting
; has stood in as visible proof the CONTROL/render pipeline runs (P0-P3,
; docs/sprinter-testnotes/S5.md) -- from that point on, ovl_test_signal's
; own job is done, and the resident's steady-state screen should look like
; the real game (black background), not stay parked on the diagnostic
; tint forever, which is what the P0-P3 MAME runs actually saw before this
; existed. Same WIN3 save/map(#50)/restore dance as ovl_test_signal and
; video_init. Clobbers AF,BC,DE,HL.
clear_bg_signal:
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,#50
        out     (WIN3_PORT),a
        xor     a                       ; palette index 0 = background
        ld      hl,palette_rgb
        call    write_palette_entry
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.saved_win3: DB 0

; --- RTC -------------------------------------------------------------------

; rtc_present is NOT file-local storage: trampoline.asm (a separate
; sjasmplus --raw job, assembled before this file's code ever runs) writes
; it once at boot from BIOS_CMOS_TEST, so it lives at the fixed address
; src/sprinter/fixed_layout.json anchors (RTC_PRESENT_ADDR) instead of a
; DB this file would own. The alias keeps rtc_sample's own source
; unchanged and lets it show up under this name in platform_primitives.sym
; for tools/gen_sprinter_platform_defs.py, same as every other primitive.
rtc_present EQU RTC_PRESENT_ADDR

; Samples DSS SysTime into rtc_valid/rtc_hour/rtc_minute/rtc_second.
; Gated on rtc_present: DSS SysTime itself never reports a missing clock --
; its .NOCMOS path returns compile-time defaults with CF=0 (Estex-DSS
; Time.asm:97-107) -- so without the gate a clockless machine would show
; the defaults as real time. The CF check is kept as a defensive guard
; only. SysTime returns H=hour, L=minute, B=second, binary.
;
; Must be called from an EI context with canonical windows -- it RSTs into
; DSS, which must not happen while WIN3 is remapped to VRAM under DI.
; Clobbers AF, BC, DE, HL.
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

rtc_valid:  DB 0
rtc_hour:   DB 0
rtc_minute: DB 0
rtc_second: DB 0

        ENDIF
