; Render core primitives (port.md section 5/S2, section 3.3): fill/clear a
; VRAM buffer and blit a WIN0-resident tile, all accelerated. Ported from
; sources/libs/gfx640/gfx640.asm (extern/sprinter-libs pin), adapted to a
; register/named-cell ABI instead of the donor's structure-passing DLL ABI,
; and to this port's fixed windows: VRAM is always WIN3 (mapped/unmapped by
; each primitive itself), a tile/font source page is always WIN0 (mapped via
; win0_map_di, R1).
;
; Each primitive is self-contained: DI -> map WIN3 (and WIN0 for draw_tile)
; -> accelerated draw -> park PORT_Y=#C0 -> restore windows -> EI (R3), so
; primitives are safe to call back-to-back without any caller-side DI/window
; bookkeeping. Accelerator ops use only the ACC_* macros from accel.inc
; (R3's enforced surface); IX/IY are not used and are left untouched.
;
; Position-independent code and data: INCLUDEd once from resident_s1.asm's
; flexible code area.

        IFNDEF SPRINTER_GFX_CORE_INC
        DEFINE SPRINTER_GFX_CORE_INC

        INCLUDE "dss.inc"
        INCLUDE "win0.inc"
        INCLUDE "accel.inc"

; --- buffer flip -----------------------------------------------------------

; Toggles the displayed VRAM buffer (RGMOD bit 0). No DI needed: a single
; port write. Clobbers AF.
gfx_swap_buffers:
        in      a,(PORT_RGMOD)
        xor     1
        out     (PORT_RGMOD),a
        ret

; --- clear -------------------------------------------------------------

; Fills a whole 256-row VRAM buffer with 320 vertical accelerator bursts of
; 256 rows each (ported from gfx640.asm's clear_mapped).
;
; A=color(0-15), HL=dest_base (#C000 buf0 or #C140 buf1). Clobbers
; AF, BC, DE, HL.
gfx_clear_buffer:
        ld      b,a
        rlca
        rlca
        rlca
        rlca
        or      b
        ld      (.fill_byte),a

        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a

        xor     a
        out     (PORT_Y),a
        ld      a,(.fill_byte)
        ld      e,a
        ACC_SET_SIZE
        ld      a,0                     ; immediate operand; 0 means 256 rows
        ACC_OFF
        ld      bc,320
.col:   ACC_FILL_V
        ld      (hl),e
        ACC_OFF
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.col

        acc_park_y
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.fill_byte:  DB 0
.saved_win3: DB 0

; --- fill_rect / hline -------------------------------------------------

; Fills a byte-aligned rectangle, choosing the orientation that issues the
; FEWER, LARGER accelerator operations: a horizontal pass costs h ops of w
; bytes, a vertical pass w ops of h bytes, so the long side becomes the
; block size and the short side the operation count. This is gfx640.asm's
; own "choose the cheaper orientation" branch, which an earlier version of
; this port dropped as "buys nothing here" -- wrongly: the accelerator's
; cost is dominated by a large fixed per-operation overhead, not by the
; bytes moved (HW_NOTES.md section 4: 256 bytes in ~37 us = 0.145 us/byte,
; while a 2026-08-09 MAME run of 16-24-byte operations measured 1.43
; us/byte -- ten times worse). Every reference implementation available to
; this port works the same way: flappybird blits 138-byte rows,
; flexnavigator's fnwin.z80 sizes its vertical copy to the whole window
; height, and spevosdk's lib_tiles.asm does not use the accelerator at all
; for 4-byte tile rows -- it uses unrolled LDI there.
;
; A=color(0-15), B=x_byte(0-255, byte offset into the VRAM row),
; C=y(0-255, top row), D=w_bytes(1-255), E=h(1-255), HL=dest_base (#C000
; buf0 or #C140 buf1). Clobbers AF, BC, DE, HL.
gfx_fill_rect:
        ld      (.dest_base),hl
        push    af
        ld      a,b
        ld      (.x_byte),a
        ld      a,c
        ld      (.y),a
        ld      a,d
        ld      (.w),a
        ld      a,e
        ld      (.h),a
        pop     af
        ld      b,a
        rlca
        rlca
        rlca
        rlca
        or      b
        ld      (.fill_byte),a

        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a

        ; .vfill is CALLed from the column loop below; its body is placed
        ; here, textually between this di and the ei that closes it, purely
        ; so tools/check_sprinter_accel.py's linear source scan (it does not
        ; follow CALL/RET) sees the accelerator sequence as inside DI -- a
        ; subroutine positioned after the function's own ret/ei, the usual
        ; place, would read as "outside DI" even though it only ever runs
        ; while this DI section holds. Position is call-target-only; CALL
        ; resolves regardless of where a label sits in the file.
        jr      .strategy
; HL=column address, A=start row, C=len (0=256). Fills with .fill_byte via
; one vertical accelerator burst (ported from gfx640.asm's vfill_chunk).
; Caller must hold DI with WIN3 already mapped to VRAM. Self-modifies its
; own SET_SIZE immediate operand (the accelerator samples the LD A,n
; immediately after ACC_SET_SIZE). Clobbers AF, DE.
.vfill:
        ld      (.vfill_y),a
        ld      a,c
        ld      (.vfill_size+1),a
        ld      a,(.vfill_y)
        out     (PORT_Y),a
        ld      a,(.fill_byte)
        ld      e,a
        ACC_SET_SIZE
.vfill_size:
        ld      a,0
        ACC_OFF
        ACC_FILL_V
        ld      (hl),e
        ACC_OFF
        ret
.vfill_y:    DB 0
; HL=row address, A=len (0=256). Fills with .fill_byte via one horizontal
; accelerator burst; the caller has already selected the row with PORT_Y.
; Same bracket shape as gfx_hline's .hfill (ported from gfx640.asm's
; hfill_chunk, which deliberately has no ACC_OFF between the SET_SIZE
; immediate and the FILL_H arm). Clobbers AF, DE.
.hfill:
        ld      (.hfill_size+1),a
        ld      a,(.fill_byte)
        ld      e,a
        ACC_SET_SIZE
.hfill_size:
        ld      a,0
        ACC_FILL_H
        ld      a,e
        ld      (hl),a
        ACC_OFF
        ret
.strategy:
        ; Fewer operations wins: horizontal costs h of them, vertical w.
        ld      a,(.h)
        ld      b,a
        ld      a,(.w)
        cp      b
        jr      c,.col_setup            ; w < h -> vertical (w operations)
        jr      .row_setup              ; else horizontal (h operations)
.col_setup:
        ld      hl,(.dest_base)
        ld      a,(.x_byte)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      (.col_addr),hl
        ld      a,(.w)
        ld      (.op_count),a
.col_loop:
        ld      hl,(.col_addr)
        ld      a,(.h)
        ld      c,a                     ; C = len for .vfill (0 = 256)
        ld      a,(.y)                  ; A = start row for .vfill
        call    .vfill
        ld      hl,(.col_addr)
        inc     hl
        ld      (.col_addr),hl
        ld      hl,.op_count
        dec     (hl)
        jr      nz,.col_loop
        jr      .done
.row_setup:
        ld      a,(.y)
        ld      (.row),a
        ld      a,(.h)
        ld      (.op_count),a
.row_loop:
        ld      a,(.row)
        out     (PORT_Y),a
        ld      hl,(.dest_base)
        ld      a,(.x_byte)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(.w)
        call    .hfill
        ld      hl,.row
        inc     (hl)
        ld      hl,.op_count
        dec     (hl)
        jr      nz,.row_loop
.done:
        acc_park_y
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.dest_base:  DW 0
.x_byte:     DB 0
.y:          DB 0
.w:          DB 0
.h:          DB 0
.fill_byte:  DB 0
.col_addr:   DW 0
.op_count:   DB 0
.row:        DB 0
.saved_win3: DB 0

; Fills a single VRAM row segment with a horizontal accelerator fill (chunks
; of up to 160 bytes, matching gfx640.asm's hfill_chunk convention: a row
; wider than 160 bytes is split into a 160-byte chunk plus the remainder).
;
; A=color(0-15), B=x_byte(0-255), C=y(0-255), D=w_bytes(1-255),
; HL=dest_base (#C000/#C140). Clobbers AF, BC, DE, HL.
gfx_hline:
        ld      (.dest_base),hl
        push    af
        ld      a,b
        ld      (.x_byte),a
        ld      a,c
        ld      (.y),a
        ld      a,d
        ld      (.w),a
        pop     af
        ld      b,a
        rlca
        rlca
        rlca
        rlca
        or      b
        ld      (.fill_byte),a

        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a

        ; .hfill's body sits here (see the matching comment in gfx_fill_rect
        ; above) so the linear R3 source scan sees it inside this DI span.
        jr      .row_setup
; HL=address, A=count (0=256). Fills with .fill_byte via one horizontal
; accelerator burst (ported from gfx640.asm's hfill_chunk -- note there is
; deliberately no ACC_OFF between the SET_SIZE immediate and the FILL_H arm
; here, unlike .vfill above: the two donor routines use different proven
; bracket shapes and this port keeps each exactly as measured on hardware).
; Clobbers AF.
.hfill:
        ld      (.hfill_size+1),a
        ld      a,(.fill_byte)
        ld      c,a
        ACC_SET_SIZE
.hfill_size:
        ld      a,0
        ACC_FILL_H
        ld      a,c
        ld      (hl),a
        ACC_OFF
        ret
.row_setup:
        ld      a,(.y)
        out     (PORT_Y),a
        ld      hl,(.dest_base)
        ld      a,(.x_byte)
        ld      e,a
        ld      d,0
        add     hl,de

        ld      a,(.w)
        cp      161
        jr      c,.short
        ld      a,160
        call    .hfill
        ld      de,160
        add     hl,de
        ld      a,(.w)
        sub     160
        call    .hfill
        jr      .done
.short:
        ld      a,(.w)
        call    .hfill
.done:
        acc_park_y
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.dest_base:  DW 0
.x_byte:     DB 0
.y:          DB 0
.w:          DB 0
.fill_byte:  DB 0
.saved_win3: DB 0

; --- draw_tile -----------------------------------------------------------

; Parameter cells for gfx_draw_tile (too many values for registers alone --
; the same pattern gfx640.asm itself uses for its prefetched tile state).
; Set every field, then CALL gfx_draw_tile.
tile_dest_base: DW 0    ; #C000 (buf0) or #C140 (buf1)
tile_x_byte:    DB 0    ; destination byte-column offset, low byte
tile_x_hi:      DB 0    ; destination byte-column offset, high byte (S4:
                         ; tile_x_byte alone caps the column at 255, half
                         ; the 320-byte row -- nothing could be drawn in
                         ; the right-hand half of the screen. The S4
                         ; banner's logo lands at byte 230 and would have
                         ; fitted, but the parameter block is now a full
                         ; 16-bit column and t_draw_tile pins the >=256
                         ; case. Callers that predate S4 never write this
                         ; cell and rely on its 0 default; anything that
                         ; sets it must set it on EVERY call, since it is
                         ; sticky module state like the rest of the block.
tile_y:         DB 0    ; destination starting row (0..255, leave room for rows)
tile_src_page:  DB 0    ; WIN0 physical page number of the source asset page
tile_src_slot:  DB 0    ; source slot (slot*256 = byte offset within the page)
tile_stride:    DB 0    ; source bytes per row
tile_width:     DB 0    ; bytes copied per row (accelerator block size)
tile_rows:      DB 0    ; row count
tile_alias:     DB 0    ; VRAM_ALIAS_OPAQUE or VRAM_ALIAS_KEY

; Draws a WIN0-resident tile onto VRAM: one horizontal accelerator copy per
; row (ported from gfx640.asm's draw_tile_sized_target_ready), generalised
; to an arbitrary source stride instead of the donor's fixed 16-byte/32x16
; assumption -- the donor advances its source pointer with an 8-bit
; "add a,16", which overflows past 256 for this port's 40x20 test tile
; (stride 20 x 20 rows = 400); this version advances the full 16-bit HL
; instead (port.md section 5/S2).
;
; Reads every parameter from the tile_* cells above. Maps the source page
; into WIN0 for the whole draw via win0_map_di (R1); the destination column
; address is constant across rows (PORT_Y selects the VRAM row, not the
; byte address), so it is computed once, matching the donor. tile_alias
; selects opaque (VRAM_ALIAS_OPAQUE) or hardware-key transparent
; (VRAM_ALIAS_KEY) writes (port.md section 3.3). Clobbers AF, BC, DE, HL.
gfx_draw_tile:
        ld      a,(tile_width)
        ld      (.copy_size+1),a
        ld      a,(tile_stride)
        ld      (.stride16),a
        xor     a
        ld      (.stride16+1),a         ; zero-extend the byte stride to a word

        ld      a,(tile_src_page)
        win0_map_di

        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,(tile_alias)
        out     (WIN3_PORT),a

        ld      hl,(tile_dest_base)
        ld      a,(tile_x_byte)
        ld      e,a
        ld      a,(tile_x_hi)
        ld      d,a
        add     hl,de
        ex      de,hl                   ; DE = dest column address (constant)

        ld      a,(tile_src_slot)
        ld      h,a
        ld      l,0                     ; HL = WIN0 + slot*256 (source)

        ld      a,(tile_y)
        ld      c,a                     ; C = current row (PORT_Y)
        ld      a,(tile_rows)
        ld      b,a                     ; B = row counter
.row:
        ld      a,c
        out     (PORT_Y),a
        ACC_SET_SIZE
.copy_size:
        ld      a,0
        ACC_COPY_H
        ld      a,(hl)
        ld      (de),a
        ACC_OFF
        push    de
        ld      de,(.stride16)
        add     hl,de
        pop     de
        inc     c
        djnz    .row

        acc_park_y
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        win0_restore
        ret
.stride16:   DW 0
.saved_win3: DB 0

; --- blit_rows ------------------------------------------------------------

; Copies tile_width bytes into each of tile_rows consecutive VRAM rows from
; a source that is ALREADY CPU-addressable (resident RAM, or whatever the
; caller has mapped), advancing the source by tile_stride per row. A stride
; of 0 repeats the same source row, which is how one composed row is
; stretched down a band.
;
; This is gfx_draw_tile's row loop without the WIN0 remap: it cannot source
; from an asset page, and in exchange it is the path for content composed
; in RAM. The point of composing is operation size -- the accelerator's cost
; is dominated by a fixed per-operation overhead (see gfx_fill_rect), so a
; 192-byte row copy moves a board-width strip for roughly what a 24-byte one
; costs. Measured on MAME 2026-08-09: 0.304 us/byte at 192-byte blocks
; against 1.024 us/byte at 24-byte blocks.
;
; HL=source address; tile_dest_base/tile_x_byte/tile_x_hi/tile_y/
; tile_stride/tile_width/tile_rows/tile_alias as for gfx_draw_tile.
; Clobbers AF, BC, DE, HL.
gfx_blit_rows:
        ld      (.src),hl
        ld      a,(tile_width)
        ld      (.copy_size+1),a
        ld      a,(tile_stride)
        ld      (.stride16),a
        xor     a
        ld      (.stride16+1),a

        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,(tile_alias)
        out     (WIN3_PORT),a

        ld      hl,(tile_dest_base)
        ld      a,(tile_x_byte)
        ld      e,a
        ld      a,(tile_x_hi)
        ld      d,a
        add     hl,de
        ex      de,hl                   ; DE = dest column (constant)
        ld      hl,(.src)
        ld      a,(tile_y)
        ld      c,a
        ld      a,(tile_rows)
        ld      b,a
.row:
        ld      a,c
        out     (PORT_Y),a
        ACC_SET_SIZE
.copy_size:
        ld      a,0
        ACC_COPY_H
        ld      a,(hl)
        ld      (de),a
        ACC_OFF
        push    de
        ld      de,(.stride16)
        add     hl,de
        pop     de
        inc     c
        djnz    .row

        acc_park_y
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.src:        DW 0
.stride16:   DW 0
.saved_win3: DB 0

        ENDIF
