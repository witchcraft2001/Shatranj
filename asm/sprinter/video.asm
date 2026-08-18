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

; --- screen fade (S9 follow-up, 2026-08-18) --------------------------------
;
; Every screen switch on this port is a visible rebuild: About covers all
; 640x256, so dismissing it pixel-clears the screen and repaints a dozen
; elements, and a tester watching MAME sees the clear and each repaint land
; (human tester, 2026-08-18). Boot had the same problem in a cruder form --
; the S5 overlay-probe diagnostic flashed the whole background green before
; the real screen appeared.
;
; The fix costs no pixel work at all. This hardware keeps its 16 palette
; entries as 24-bit RGB in VRAM, so scaling all 16 toward black and back is
; a 96-byte rewrite that dims or reveals whatever is already in the
; framebuffer. Fade to black, rebuild the screen unseen, fade back up.
;
; fade_level is the master: 0 = black, FADE_MAX = the table's own colours.
; EVERY palette write goes through it (write_palette_entry below), so a
; repaint that happens mid-fade lands at the current level instead of
; flashing at full brightness -- which is exactly what makes the rebuild
; invisible without any caller having to know a fade is in progress.
FADE_MAX EQU 16

fade_level: DB 0                ; boot starts black; main() fades in once
                                 ; the whole first screen has painted
; The table the live screen's colours come from, so a fade needs no
; argument and no caller has to keep one alive across the ramp. Set by
; palette_apply_from below; palette_rgb until the first call.
pal_src:    DW palette_rgb

; A = one RGB component, scaled to fade_level (A*level/FADE_MAX). Shift-add
; rather than a lookup table: 48 of these run per fade step, all OUTSIDE the
; palette write's DI window, so ~380 T-states apiece costs nothing that
; matters and a 4 KiB table would not fit in this pool anyway.
; Clobbers AF only -- write_palette_entry calls this with its source and
; destination pointers live.
fade_scale:
        push    hl
        push    de
        push    bc
        ld      e,a
        ld      d,0                     ; DE = component
        ld      a,(fade_level)
        ld      c,a                     ; C = level, 0..16 (5 bits)
        ld      hl,0
        ld      b,5
.bit:
        srl     c
        jr      nc,.no_add
        add     hl,de
.no_add:
        ex      de,hl
        add     hl,hl
        ex      de,hl
        djnz    .bit
        ; HL = component*level, at most 4080. Dividing by FADE_MAX (16) is
        ; four right shifts, which is four LEFT shifts and then reading H.
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,h
        pop     bc
        pop     de
        pop     hl
        ret

; Writes one palette entry (A=index 0..15, HL->3 RGB8 bytes) to both
; palette banks, scaled to the current fade level. Caller must already have
; WIN3 mapped to the palette page. Clobbers AF, BC, DE, HL (HL left one past
; the 3 source bytes, matching palette_apply_raw's own advance).
;
; Each component is scaled ONCE and stored to both banks, rather than the
; source being re-read per bank the way this used to do it: the scale is the
; expensive part now, and doing it twice would double the DI window for
; nothing.
write_palette_entry:
        out     (PORT_Y),a
        ld      de,#C3E0
        ld      b,3
.component:
        ld      a,(hl)
        inc     hl
        call    fade_scale
        ld      (de),a                  ; bank 0
        ld      c,a
        ld      a,e
        add     a,4
        ld      e,a
        ld      a,c
        ld      (de),a                  ; bank 1
        ld      a,e
        sub     3                       ; back one bank, on to the next
        ld      e,a                      ; component
        djnz    .component
        xor     a                       ; 4th entry byte: the proven
        ld      (de),a                  ; palette.inc donor zeroes it
        ld      a,e                     ; unconditionally, per bank
        add     a,4
        ld      e,a
        xor     a
        ld      (de),a
        ret

; Sets up the palette in both VRAM buffers. Call once at boot (from C's
; main()) and again after any mode switch (which resets the palette).
; Unlike the S1 stand's video_init, does NOT touch VRAM contents -- the
; stand's debug grid is gone; the real board/panel painting is C's job.
; This is also the RESTORE path the S9 About screen returns through.
; Clobbers AF,BC,DE,HL.
video_init:
        ld      hl,palette_rgb
        ; falls through

; Same, for an arbitrary 16 x 3 RGB8 table (HL). Split out of video_init
; rather than duplicated because the WIN3 save/map(#50)/park/restore dance
; around it is the whole routine, and the S9 About overlay needs exactly
; that dance for its own palette: the overlay itself lives in WIN3 and so
; cannot be mapped while the palette registers are, which is why this has
; to be a resident entry point and not overlay-local code. The table must
; therefore sit somewhere still addressable with VRAM in WIN3 -- the
; About overlay stages its copy into LOWRAM_OVERLAY_SCRATCH (WIN2) first,
; and it must STAY there while that screen is up, since every fade step
; re-reads it from here. Clobbers AF,BC,DE,HL.
palette_apply_from:
        ld      (pal_src),hl
        ; falls through

; No arguments. Re-applies whatever table palette_apply_from last saw, at
; the current fade level -- one fade step. Clobbers AF,BC,DE,HL.
; One interrupt is admitted between entries. Scaling three components costs
; ~1100 T-states, so all sixteen under a single DI span would run about 1.6ms
; -- right at the ~2ms mark where DSS's three-byte keyboard FIFO starts
; dropping scancodes (gfx_core.asm's irq_yield_vram has the full account),
; and this now runs sixteen times per fade instead of once at boot. Splitting
; costs atomicity, which nothing here needs: a fade step moves every entry by
; one sixteenth, and the two entries a theme switch moves are
; indistinguishable a frame apart.
;
; The palette page is re-selected at the top of EVERY entry rather than once
; up front, for the same reason irq_yield_vram re-maps VRAM unconditionally:
; DSS is documented to remap page 3 and not restore it, so nothing mapped
; across an EI can be assumed still mapped after it. The CALLER's WIN3 is
; saved once and restored once, at the ends -- it stays unmapped for the
; whole run, which is safe because nothing that executes in the gaps lives
; there (the IM2 stub and DSS's own handler are both low memory).
palette_refresh:
        ld      hl,(pal_src)
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        xor     a
.next:
        ld      (.index),a
        ld      a,#50
        out     (WIN3_PORT),a
        ld      a,(.index)
        call    write_palette_entry     ; advances HL by 3
        ld      a,#C0                   ; park PORT_Y before any EI (R3/R10:
        out     (PORT_Y),a              ; no VRAM row selected across one)
        ei
        nop                             ; the Z80 accepts an interrupt only
        di                              ; AFTER the instruction following EI
        ld      a,(.index)
        inc     a
        cp      STRIPE_COUNT
        jr      c,.next
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.saved_win3: DB 0
.index:      DB 0

; No arguments, both C-callable. Ramp the whole palette to black / back to
; its own colours, one level per frame -- FADE_MAX frames, about a third of
; a second at 50Hz. Callers put the screen rebuild BETWEEN the two, where
; nothing is visible.
;
; frame_wait (im2_s1.asm) means these must not be called before im2_install:
; it waits on a flag only the IM2 tick sets. Clobbers AF,BC,DE,HL.
;
; The ramp is preceded by one flush frame, and that is not a nicety. Every
; rectangle painted since the last flip is still logged in buffers.asm's dirty
; ring, and the frame_wait that finally clears it pays for the whole
; front->back copy inside flip_sync -- for the dirty_all case (gfx_clear_
; buffer, and any repaint big enough to overflow the 16-slot ring, so: every
; screen a fade exists for) that is 320x256 bytes of LDIR plus a per-row
; interrupt yield, hundreds of milliseconds. Left where it fell, that landed
; on the ramp's FIRST frame_wait, which reads as the fade freezing a couple of
; steps in and then resuming -- reported from MAME as a half-second stall
; around 15-20% of the reveal (human tester, 2026-08-18). Spending it HERE
; costs the same time but puts it before the first palette step, where the
; screen still holds the level it started from: boot and the About rebuild
; both fade IN from black, so there it is a pause on a black screen and
; cannot be seen at all.
;
; Unconditional rather than guarded on flip_ring_count/flip_dirty_all. With
; nothing pending this is one HALT to the next tick -- 20ms on a 320ms ramp,
; against 12 bytes of test-and-branch in the tightest pool in this port. It
; also means no future paint path can acquire a pending state this does not
; know to look at.
fade_out:
        ld      c,0
        jr      fade_to
fade_in:
        ld      c,FADE_MAX
fade_to:
        push    bc                      ; frame_wait's flip_sync clobbers BC
        call    frame_wait
        pop     bc
.ramp:
        ld      a,(fade_level)
        cp      c
        ret     z
        jr      c,.brighter
        dec     a
        jr      .step
.brighter:
        inc     a
.step:
        ld      (fade_level),a
        push    bc
        call    palette_refresh
        call    frame_wait
        pop     bc
        jr      .ramp

; --- board theme (S5-finish, menu THEME action, plan D12) ------------------
;
; ZX's netchesszx_board_theme_apply (asm/spectrum/screen.asm) recolours the
; board by rewriting each square's ATTR byte and repainting -- there is no
; equivalent "attribute" concept on Sprinter's 4bpp linear framebuffer.
; render_core.asm's draw_square_into already paints every square through
; palette indices 2 (light) / 3 (dark) (assets/sprinter/palette.json), so
; recolouring the board here means rewriting those two palette ENTRIES, not
; touching a single framebuffer byte: every square on screen recolours the
; next time the accelerator/CRT reads that palette index, no redraw needed
; at all (port.md's own "Палитра — в VRAM" fact). Cheaper and simpler than
; porting ZX's redraw-based approach, not a missing feature standing in for
; it.
THEME_COUNT EQU 5
theme_squares_rgb:
        ; 0 CLASSIC (palette_base.inc's own boot default -- restoring index
        ; 0 here keeps a full cycle back-to-back with write_palette's own
        ; boot values, so nothing looks "off" landing back on theme 0)
        DB #F0,#D9,#B5          ; light
        DB #B5,#88,#63          ; dark
        ; 1 BLUE
        DB #D9,#E6,#F5
        DB #5A,#78,#B5
        ; 2 GREEN
        DB #E2,#F0,#D9
        DB #6B,#9E,#5A
        ; 3 CYAN
        DB #D9,#F5,#F0
        DB #4A,#A8,#A0
        ; 4 MAGENTA
        DB #F5,#D9,#F0
        DB #A8,#4A,#9E

; C-callable (single uint8_t arg at SP+2 -- z88dk's -clib=default convention
; promotes every scalar argument to a full 16-bit stack slot regardless of C
; type, and a single-argument call is the one case where that still lands the
; real value at a plain SP+2, with no earlier argument's padding byte in the
; way; overlay_loader_sprinter.asm's file banner has the verified detail and
; the bug that shipped from assuming otherwise): theme index, taken mod
; THEME_COUNT so a caller never needs its own range check.
;
; The chosen pair is written INTO palette_rgb's own entries 2/3 and the whole
; table is then re-applied, rather than the two entries being poked straight
; at the palette registers. palette_rgb is what every later palette write
; re-reads -- video_init on an About dismissal, and every fade step -- so a
; theme that lives only in the hardware registers is a theme that reverts the
; next time anything touches the palette. It did: before the fade work
; (2026-08-18) picking a theme and then opening and closing About put the
; board back to CLASSIC. Going through palette_apply_from also means a theme
; switch mid-fade lands at the current level like everything else, and costs
; this routine its own copy of the WIN3 dance. Clobbers AF,BC,DE,HL.
theme_set_squares:
        ld      hl,2
        add     hl,sp
        ld      a,(hl)
.mod:   cp      THEME_COUNT
        jr      c,.have_index
        sub     THEME_COUNT
        jr      .mod
.have_index:
        ; hl = theme_squares_rgb + index*6 (6 bytes/theme: light RGB, dark
        ; RGB) -- THEME_COUNT is small (5), a plain add loop is clearer than
        ; a shift-based multiply for a range this size.
        ld      hl,theme_squares_rgb
        or      a
        jr      z,.at_offset
        ld      b,a
.add6:  ld      de,6
        add     hl,de
        djnz    .add6
.at_offset:
        ld      de,palette_rgb+2*3       ; entries 2/3 = square light/dark
        ld      bc,6
        ldir
        ld      hl,palette_rgb
        jp      palette_apply_from

; --- RTC -------------------------------------------------------------------

; rtc_present is NOT file-local storage: trampoline.asm (a separate
; sjasmplus --raw job, assembled before this file's code ever runs) writes
; it once at boot from BIOS_CMOS_TEST, so it lives at the fixed address
; src/sprinter/fixed_layout.json anchors (RTC_PRESENT_ADDR) instead of a
; DB this file would own. The alias keeps rtc_sample's own source
; unchanged and lets it show up under this name in platform_primitives.sym
; for tools/gen_sprinter_platform_defs.py, same as every other primitive.
rtc_present EQU RTC_PRESENT_ADDR

; Samples DSS SysTime into rtc_valid/rtc_hour/rtc_minute/rtc_second and (S6,
; dss_fileio.asm's FAT-stamp shims) rtc_day/rtc_month/rtc_year.
; Gated on rtc_present: DSS SysTime itself never reports a missing clock --
; its .NOCMOS path returns compile-time defaults with CF=0 (Estex-DSS
; Time.asm:97-107) -- so without the gate a clockless machine would show
; the defaults as real time. The CF check is kept as a defensive guard
; only. SysTime returns D=day, E=month, IX=year (full, e.g. 2024), H=hour,
; L=minute, B=second, all binary (Estex-DSS Time.asm:5-11, verified).
;
; Must be called from an EI context with canonical windows -- it RSTs into
; DSS, which must not happen while WIN3 is remapped to VRAM under DI.
; Clobbers AF, BC, DE, HL, IX.
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
        ld      a,d                     ; day
        ld      (rtc_day),a
        ld      a,e                     ; month
        ld      (rtc_month),a
        ld      (rtc_year),ix
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
rtc_day:    DB 0
rtc_month:  DB 0
rtc_year:   DW 0

        ENDIF
