; Proportional text (port.md section 5/S2, section 3.3). Ported from
; sources/libs/afnt640/afnt640.asm (extern/sprinter-libs pin): the
; accelerated per-column XOR-compositing render loop
; (text_out_640_rows_general/text_out_640_rows_black) and its colour-cache
; builder (prepare_print_colors/fill_colour_buffer_640) are kept
; byte-for-byte -- they are proven-on-hardware accelerator sequences this
; port has no way to re-derive or improve on with confidence (the donor's
; own comment: "without this pair every glyph becomes a solid bar"). Only
; the surrounding setup is rewritten:
;
;   - The donor multiplexes one shared CPU window between the font and
;     video pages (its own historical single-window budget) and remaps
;     per character when they collide. This port has two free windows and
;     fixes the font source in WIN0 (win0_map_di, R1) and VRAM in WIN3 for
;     the whole call -- they never collide, so the remap dance is gone.
;   - The donor's raw `LD L,L`-style accelerator opcodes are written here
;     via the ACC_* macros from accel.inc (byte-identical encoding) so
;     tools/check_sprinter_accel.py's R3 gate can see them.
;   - text_print adds the clipping the donor deliberately has none of
;     (its own README says so): reject odd X or Y>248 outright; a
;     pre-scan stops staging characters before any whose bytes would
;     cross the 320-byte row edge (no wraparound) or past
;     TEXT_STAGE_MAX characters (a hard cap on how long this call holds
;     DI -- port.md "Риски").
;
; Note on what a z80 unit test can check here: the render loop reads the
; font mask into A, then does `EXX / LD A,(y_pos) / ... / AND (HL)` -- on
; real hardware the ACC_COPY_H bracket makes the accelerator substitute its
; own latched mask byte into that AND/XOR (the "solid bar" comment above);
; under z88dk-ticks, which has no accelerator model, the same instructions
; run as plain Z80 and so compute y_pos AND foreground_buffer_byte instead
; -- not the documented formula. So the pixel VALUES this loop writes are
; only meaningful on MAME/hardware (same footing as accel_smoke); what a
; z80 test CAN verify is everything CPU-driven: the pre-scan's width-table
; lookups and clipping decisions, and the per-column destination address
; stepping (a genuine INC BC). tests/sprinter/z80/t_text_clip.asm checks
; addresses touched vs. left at a sentinel, not composited values.
;
; Everything below is local to text_print (dot-prefixed labels): the
; ported donor routines are internal helpers here, not part of this port's
; public surface, and keeping them in one local scope avoids sjasmplus
; local-label leakage across what would otherwise be several unrelated
; global labels in a single file.
;
; Font layout (extern/sprinter-libs/afnt640/font.bin, 6888 bytes): 256
; packed-column-width bytes at FONT_BASE+0, 256 low then 256 high raster-
; offset bytes at FONT_BASE+256/+512, then variable-size column-major
; 8-row rasters (one byte per scanline per packed byte-column) starting
; further in the file, addressed via FONT_BASE + the offset table's value.
; 8 rows/glyph fixes the Y validation bound above.
;
; Position-independent code and data: INCLUDEd once from resident_s1.asm's
; flexible code area.

        IFNDEF SPRINTER_TEXT640_INC
        DEFINE SPRINTER_TEXT640_INC

        INCLUDE "dss.inc"
        INCLUDE "win0.inc"
        INCLUDE "accel.inc"
        ; LOWRAM_TEXT_STAGE_ADDR (.stage's home, see below). INCLUDEd here
        ; rather than relied on from platform_primitives.asm: a file must
        ; not depend on whatever included it having pulled the anchors in
        ; first -- buffers.asm's own comment on the same INCLUDE, and the
        ; reason the z80 unit tests can assemble this file standalone.
        INCLUDE "fixed_layout.inc"

; The font page is normally WIN0-resident at address 0 (win0_map_di maps
; WIN0's base to #0000, so table offsets are direct addresses). A z80 unit
; test that cannot rely on a real WIN0 remap defines S2_TEST_FONT_BASE to
; relocate a synthetic fixture instead, without conflicting with `org 0`'s
; own code (the same S1_TEST_HOOK precedent used by t_frame_wait.asm).
        IFDEF S2_TEST_FONT_BASE
FONT_BASE EQU S2_TEST_FONT_BASE
        ELSE
FONT_BASE EQU 0
        ENDIF

TEXT_STAGE_MAX EQU 64           ; hard length cap: bounds how long this
                                 ; call can hold DI (port.md "Риски")
TEXT_STAGE EQU LOWRAM_TEXT_STAGE_ADDR

; Set once by the caller (from the asset page's physical number published
; in HDR, HDR_ASSET_PAGE0_OFFSET) before any text_print call.
text_font_page: DB 0

; DE=text (ASCIIZ, resident RAM -- never the WIN0/WIN3 windows), IX=x
; (pixel, even), C=y (pixel row, 0..248), A=colour (bg<<4|fg), HL=dest_base
; (#C000 buf0 or #C140 buf1). Silently does not draw if X is odd or
; Y>248 (leaves no room for the 8-row glyph). Clobbers AF, BC, DE, HL, IX.
text_print:
        ld      (.color),a
        ld      (.dest_base),hl
        ld      (.text_in),de
        ld      a,ixl
        rrca
        ret     c                       ; odd X: reject
        ld      a,c
        cp      249
        ret     nc                      ; Y > 248: reject
        ld      (.y),a
        push    ix
        pop     hl
        srl     h
        rr      l
        ld      (.start_col),hl

        ; Saved unconditionally (not just on the path that remaps WIN3 to
        ; VRAM below) so .close's restore is correct even when nothing
        ; ends up staged and WIN3 is never touched.
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a

        ld      a,(text_font_page)
        win0_map_di

        ; Helper bodies (.prepare_print_colors/.fill_colour_buffer_640,
        ; both accelerator-free, and the two accelerated row renderers)
        ; are placed here, between this win0_map_di and the win0_restore
        ; far below, purely so tools/check_sprinter_accel.py's linear
        ; source scan (it does not follow CALL/JP) sees the renderers'
        ; ACC_* macros as inside DI -- see the matching comment in
        ; gfx_core.asm. They are call/jp targets only; this jp skips
        ; their definitions during normal top-to-bottom execution (jp,
        ; not jr: the skipped block is too big for an 8-bit displacement).
        jp      .prescan

; --- colour cache (afnt640.asm prepare_print_colors/fill_colour_buffer_640,
; ported unchanged) -----------------------------------------------------

; B=colour (bg<<4|fg). Skips the rebuild if B matches the last colour this
; call site prepared. Clobbers AF, BC, HL (and the alternate set).
.prepare_print_colors:
        ld      a,(color_valid)
        or      a
        jr      z,.ppc_rebuild
        ld      a,b
.ppc_prev:
        cp      0
        ret     z
.ppc_rebuild:
        ld      a,1
        ld      (color_valid),a
        ld      a,b
        ld      (.ppc_prev+1),a
        and     #0F
        ld      c,a
        rlca
        rlca
        rlca
        rlca
        or      c
        ld      (fg_pattern),a
        ld      a,b
        and     #F0
        ld      c,a
        rrca
        rrca
        rrca
        rrca
        or      c
        ld      (bg_pattern),a
        ld      c,a
        ld      a,(fg_pattern)
        xor     c                       ; foreground XOR background
        exx
        ld      hl,foreground_buffer
        call    .fill_colour_buffer_640
        ld      a,(bg_pattern)
        ld      hl,background_buffer
        call    .fill_colour_buffer_640
        exx
        ret

; Active in the alternate register set. Fill eight bytes at HL with A.
.fill_colour_buffer_640:
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        ret

; --- accelerated per-column renderer (afnt640.asm text_out_640_rows_*,
; ported unchanged apart from raw opcodes -> ACC_* macros) -----------------
;
; Entered only via the self-modified dispatch jump in .char below. Main
; BC=staged string pointer, HL/DE=current glyph raster pointer/8 (column
; stride); alternate BC'=destination column address (constant), HL'/DE'=
; foreground_buffer/background_buffer pointers (constant). B=remaining
; byte-columns for the current glyph (DJNZ). Composites
; background XOR (mask AND (foreground XOR background)); the black-
; background path omits the XOR pass since it is identically zero.
.rows_general:
        ACC_COPY_H
        ld      a,(hl)
        ACC_OFF
        exx
        ld      a,(.y)
        out     (PORT_Y),a
        ACC_COPY_H
        and     (hl)
        ACC_OFF
        ex      de,hl
        ACC_COPY_H
        xor     (hl)
        ACC_COPY_V
        ld      (bc),a
        ACC_OFF
        ex      de,hl
        inc     bc
        exx
        add     hl,de
        djnz    .rows_general
        jp      .char_done

.rows_black:
        ACC_COPY_H
        ld      a,(hl)
        ACC_OFF
        exx
        ld      a,(.y)
        out     (PORT_Y),a
        ACC_COPY_H
        and     (hl)
        ACC_COPY_V
        ld      (bc),a
        ACC_OFF
        inc     bc
        exx
        add     hl,de
        djnz    .rows_black

.char_done:
        pop     bc

        ; Keyboard rescue: one interrupt admitted per glyph. gfx_core.asm's
        ; irq_yield_vram (buffers.asm) carries the whole explanation (DSS's 3-byte
        ; keyboard FIFO versus this routine's string-long DI span, which is
        ; what made the chat line swallow characters while being typed
        ; into). Placed HERE because this is the one point in the render
        ; loop where the accelerator is off, the alternate register set is
        ; not live, and only BC -- the staged-string pointer, which the
        ; interrupt path preserves -- has to survive. WIN0 currently holds
        ; the font page and the interrupt path ends in `jp #0038`, so it
        ; goes back to the caller's page across the yield and returns to
        ; the font afterwards. The accelerator's block size is latched once
        ; for the whole string and no interrupt handler touches it.
        acc_park_y                      ; no VRAM row selected across an EI
        win0_restore                    ; WIN0 back to the caller's page, EI
        ld      a,(text_font_page)      ; the interrupt lands after THIS
        win0_map_di                     ; DI again, WIN0 back to the font
        ld      a,VRAM_ALIAS_OPAQUE     ; DSS is documented to remap page 3
        out     (WIN3_PORT),a           ; without restoring it

        ld      a,(bc)
        inc     bc
        or      a
        jp      nz,.char                ; jp: .char is out of jr's range
        jp      .close                  ; .close (win0_restore) is placed at
                                         ; the very end of this scope, after
                                         ; every accelerator-using line below
                                         ; (.prescan's render setup included)
                                         ; -- see the matching comment there.

; --- setup: pre-scan/stage, then drive the renderer above -----------------

.prescan:
        ld      hl,(.text_in)
        ld      (.stage_in),hl
        ld      hl,TEXT_STAGE
        ld      (.stage_out),hl
        xor     a
        ld      (.staged),a
        ld      hl,(.start_col)
        ld      (.scan_col),hl
.scan_loop:
        ld      hl,(.stage_in)
        ld      a,(hl)
        or      a
        jr      z,.scan_done
        ld      (.char_code),a
        ld      a,(.staged)
        cp      TEXT_STAGE_MAX
        jr      nc,.scan_done

        ld      a,(.char_code)
        ld      l,a
        ld      h,0
        ld      de,FONT_BASE
        add     hl,de
        ld      a,(hl)                  ; width, in packed byte-columns
        ld      (.char_width),a

        ld      hl,(.scan_col)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      de,321
        or      a
        sbc     hl,de
        jr      nc,.scan_done           ; would cross the 320-byte row edge

        ld      hl,(.scan_col)
        ld      a,(.char_width)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      (.scan_col),hl

        ld      hl,(.stage_out)
        ld      a,(.char_code)
        ld      (hl),a
        inc     hl
        ld      (.stage_out),hl

        ld      hl,(.stage_in)
        inc     hl
        ld      (.stage_in),hl

        ld      a,(.staged)
        inc     a
        ld      (.staged),a
        jr      .scan_loop
.scan_done:
        ld      hl,(.stage_out)
        xor     a
        ld      (hl),a                  ; NUL-terminate the staged copy

        ld      a,(.staged)
        or      a
        jp      z,.close                ; nothing fit -> nothing to render

        ; S5-finish plan D11: log the painted rect before rendering (the
        ; cells below don't change during rendering, so the order versus
        ; the render itself doesn't matter, only that .scan_col has
        ; already been finalised by the prescan above). Width is in the
        ; same byte-column units as .start_col -- how many byte-columns
        ; the staged string actually consumed, not a pixel width.
        ld      hl,(.start_col)
        ld      (flip_arg_x),hl
        ld      a,(.y)
        ld      (flip_arg_y),a
        ld      hl,(.scan_col)
        ld      de,(.start_col)
        or      a
        sbc     hl,de
        ld      (flip_arg_w),hl
        ld      a,8                     ; font height, fixed (see the file
        ld      (flip_arg_h),a          ; banner: 8 rows/glyph)
        call    flip_log_rect

        ; --- render the staged string (afnt640.asm text_out_640, from "read_page"
        ; through "text_out_640_exit" above) ------------------------------
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a

        ld      a,(.color)
        ld      b,a
        call    .prepare_print_colors

        ; EXX swaps the WHOLE register file, not just what's named after
        ; it -- a value computed in the main set before EXX is not visible
        ; as the "same" register afterward. So this reads .dest_base/
        ; .start_col fresh (memory, unaffected by EXX) from inside the
        ; alternate context instead of trying to carry a precomputed value
        ; across the swap (matches the donor's own approach: it never
        ; shuttles a register value over an EXX boundary either).
        exx
        ld      hl,(.dest_base)
        ld      de,(.start_col)
        add     hl,de
        ld      b,h
        ld      c,l                     ; BC' = destination column address
        ld      hl,foreground_buffer
        ld      de,background_buffer
        exx

        ld      bc,TEXT_STAGE

        ld      a,(bg_pattern)
        or      a
        ld      hl,.rows_general
        jr      nz,.dispatch_ready
        ld      hl,.rows_black
.dispatch_ready:
        ld      (.dispatch+1),hl

        ; Accelerator block size = 8 (font height), latched once for the
        ; whole string; every COPY below reuses it (matches the donor).
        ACC_SET_SIZE
        ld      a,8
        ACC_OFF
        ld      a,(bc)
        inc     bc
        or      a
        jp      z,.close

.char:
        push    bc
        ld      bc,FONT_BASE
        ld      l,a
        ld      h,0
        add     hl,bc
        ld      b,(hl)
        inc     h
        ld      e,(hl)
        inc     h
        ld      d,(hl)
        ld      hl,FONT_BASE
        add     hl,de
        ld      de,8

.dispatch:
        jp      .rows_general

; Single close/return point for text_print, reached from three places
; above (nothing staged; the render setup's empty-string safety check;
; .char_done once the staged string is exhausted): every accelerator use
; in this scope (.rows_general/.rows_black and the render setup's
; ACC_SET_SIZE) is placed textually BEFORE this point, so
; tools/check_sprinter_accel.py's linear source scan sees the whole span
; from win0_map_di down to here as one DI section (R1/R3). acc_park_y runs
; unconditionally; it is a no-op cost when nothing was actually drawn.
.close:
        ACC_OFF                         ; defensive, matches the donor
        acc_park_y
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        win0_restore
        ret

.color:      DB 0
.dest_base:  DW 0
.text_in:    DW 0
.y:          DB 0
.start_col:  DW 0
.scan_col:   DW 0
.stage_in:   DW 0
.stage_out:  DW 0
.staged:     DB 0
.char_code:  DB 0
.char_width: DB 0
.saved_win3: DB 0
; .stage does NOT live here any more: it is TEXT_STAGE_MAX+1 bytes of pure
; scratch (written by the pre-scan, read by the render loop, dead between
; calls) and it was sitting in the WIN2 code gap, the one pool in this port
; with nothing left to give. It moved to the low-RAM map at S9's keyboard
; fix, exactly the way net_gate.asm's ng_buf_* moved to LOWRAM_NET_GATE at
; S8 step 1 -- see LOWRAM_TEXT_STAGE in src/sprinter/fixed_layout.json.
        ASSERT  LOWRAM_TEXT_STAGE_SIZE >= TEXT_STAGE_MAX+1

; --- module-scope runtime state (small, initialised data) -----------------
color_valid:        DB 0
fg_pattern:         DB 0
bg_pattern:         DB 0
foreground_buffer:  DS 8,0
background_buffer:  DS 8,0

        ENDIF
