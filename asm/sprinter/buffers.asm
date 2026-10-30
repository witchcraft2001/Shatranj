; Production asset-page/VRAM-buffer bookkeeping (port.md section 3.10/S5,
; plan D4): the one-time setup pieces of the S2 stand's bench_s2.asm, minus
; every benchmark/probe routine (those measured render costs on the stand
; and are not part of the resident; the numbers they produced are recorded
; in docs/sprinter-render-budget.md). INCLUDEd once from
; platform_primitives.asm, after hdr.inc.

        IFNDEF SPRINTER_BUFFERS_INC
        DEFINE SPRINTER_BUFFERS_INC

        INCLUDE "dss.inc"
        INCLUDE "hdr.inc"
        INCLUDE "accel.inc"    ; acc_park_y (S5-finish plan D11: flip_sync's
                                ; .copy_rect parks PORT_Y like every other
                                ; VRAM primitive, though it never arms the
                                ; accelerator itself -- see that routine)
        ; bench_init below reads HDR_ADDR+HDR_*_OFFSET -- hdr.inc only
        ; defines the *_OFFSET constants, HDR_ADDR itself is the generated
        ; fixed_layout.inc (im2_s1.asm already includes it directly for
        ; the same reason: a file must not depend on whatever included it
        ; having pulled this in first, the same standalone-assembly
        ; concern that made z80 unit tests need it explicitly here too).
        INCLUDE "fixed_layout.inc"

; Resolve the existing asset cells and the second rendering code page from
; HDR once. Missing indices receive FF. The table preserves all old page
; indices; cells are contiguous in the same order as .indices.
bench_init:
        ld      hl,.indices
        ld      de,bench_asset_page
        ld      b,11
.next:
        ld      a,(hl)
        inc     hl
        push    hl
        ld      c,a
        ld      a,(HDR_ADDR+HDR_ASSET_PAGES_OFFSET)
        cp      c
        ld      a,#FF
        jr      z,.store
        jr      c,.store
        ld      l,c
        ld      h,0
        push    de
        ld      de,HDR_ADDR+HDR_ASSET_PAGE0_OFFSET
        add     hl,de
        pop     de
        ld      a,(hl)
.store:
        ld      (de),a
        inc     de
        pop     hl
        djnz    .next
        ld      a,(bench_asset_page)
        ld      (text_font_page),a
        ret
.indices: DB 0,1,2,3,4,5,6,7,8,9,16
bench_asset_page: DB #FF
piece_page1: DB #FF
piece_page2: DB #FF
ovl_win3_page: DB #FF
cold_win3_page: DB #FF
ovl_win3_page2: DB #FF
; Four consecutive bytes: bench_init LDIRs the HDR block straight in, and
; the About overlay indexes them as about_page0[n]. Keep them adjacent.
about_page0: DB #FF
about_page1: DB #FF
about_page2: DB #FF
about_page3: DB #FF
cold_win3_page2: DB #FF

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
; Statically initialised to the bit0=0 default (S5-finish plan D11 audit
; defect #1), not DW 0: render_cursor_marker() runs at boot, before the
; main loop's first frame_wait(), and the migrated render_core.asm cursor
; chain now paints through (back_base) alone -- a zero here would draw
; into address 0 instead of failing loudly. main() still calls
; resolve_buffers() right after video_init() (the values below are only a
; safety net, not a substitute for reading the real RGMOD state).
front_base: DW #c000
back_base:  DW #c140

; --- buffer flip: dirty-rect ring + sync (S5-finish plan D11) -------------
;
; render_core.asm no longer paints every square/frame/timer line into both
; VRAM buffers -- the migrated routines paint only (back_base), and rely on
; the actual flip (im2_s1.asm's im2_frame_core, port write) plus this ring
; to keep the now-hidden buffer in sync afterward. The five VRAM-writing
; primitives below (gfx_fill_rect, gfx_hline, gfx_draw_tile, gfx_blit_rows,
; text_print) each log the rectangle they just painted; gfx_clear_buffer
; marks the whole buffer dirty directly instead (a strict superset of
; anything a ring slot could name). frame_wait calls flip_sync once a
; requested flip is confirmed.
;
; x is a 16-bit byte-column offset, not a plain byte: BOARD_X_BYTE/
; PANEL_X-driven draws live past column 255 (the same reason gfx_core.asm's
; tile_x_byte/tile_x_hi is a word, not a byte -- see that file's own S4
; comment). y/h are bytes (0-255 rows is the whole buffer height already).
FLIP_RING_MAX EQU 8

flip_arg_x: DW 0
flip_arg_y: DB 0
flip_arg_w: DW 0
flip_arg_h: DB 0

; The merge policy lives in the additional WIN3 rendering page. Arguments
; and ring storage remain always mapped; BC is preserved for existing loops.
flip_log_rect:
        ld      a,(flip_log_suspended)
        or      a
        ret     nz
        ld      a,(flip_dirty_all)
        or      a
        ret     nz
        push    bc
        ld      hl,#C000
        call    render_aux_call
        pop     bc
        ret

; Register-argument helper boundary. WIN3 is saved on the stack, so nesting
; restores the actual caller's page. No EI here: a caller may own WIN0.
; Helpers use fixed parameter cells and preserve IX/IY. AF is preserved.
render_aux_call:
        push    af
        ld      a,i
        push    af
        di
        in      a,(WIN3_PORT)
        push    af
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+16)
        out     (WIN3_PORT),a
        call    .jump
        di                              ; a helper may admit interrupts
        pop     af
        out     (WIN3_PORT),a
        pop     af
        jp      po,.disabled
        ei
.disabled:
        pop     af
        ret
.jump:  jp      (hl)

flip_log_suspended: DB 0
board_background_done EQU LOWRAM_RENDER_PARAMS_ADDR
cell_piece EQU LOWRAM_RENDER_PARAMS_ADDR+1
cell_background EQU LOWRAM_RENDER_PARAMS_ADDR+2
text_attr_index EQU LOWRAM_RENDER_PARAMS_ADDR+3
text_glyph_page EQU LOWRAM_RENDER_PARAMS_ADDR+4
text_char EQU LOWRAM_RENDER_PARAMS_ADDR+13
text_glyph_offset EQU LOWRAM_RENDER_PARAMS_ADDR+14
        ASSERT LOWRAM_RENDER_PARAMS_SIZE >= 16

; Marks the whole buffer pair dirty. Clobbers AF.
flip_mark_dirty_all:
        ld      a,1
        ld      (flip_dirty_all),a
        ret

; Drops every logged rect and the dirty_all flag, with no copy. Call once
; at boot (buffers.asm's own front/back_base start out identical -- DSS/
; video_init paint nothing before main() runs) and at the end of
; flip_sync, the only two places pending state is legitimately discarded
; -- everywhere else that logs a rect wants it kept until a sync actually
; happens. Clobbers AF.
flip_ring_reset:
        xor     a
        ld      (flip_ring_count),a
        ld      (flip_dirty_all),a
        ret

; --- interrupt yield inside a long VRAM section ----------------------------

; Admits exactly ONE pending interrupt from the middle of a DI-held VRAM
; loop, then puts WIN3 back on the VRAM alias. Callers that also hold a
; remapped WIN0 cannot use this at all -- text640.asm's text_print spells
; the same sequence out inline around win0_restore/win0_map_di, since R1
; allows nothing else to write WIN0_PORT. Clobbers AF.
;
; Why this exists at all: the DSS keyboard is a Z80 SIO channel with a
; THREE-byte receive FIFO (KEYINTER.ASM's KEYBOARD_INIT programs WR4 for an
; x1 clock, so bytes arrive at the PS/2 clock rate, roughly 0.7-1ms each).
; A fourth byte arriving before the ISR has drained the FIFO does not queue
; -- DSS's own overrun path (KEYINTER.ASM's KBD_Receiver_Overrun) empties
; the FIFO, throws those scancodes away and resets KEYCTRL/KEY_FLG. So any
; DI span longer than about two milliseconds silently eats keypresses, with
; nothing on either side able to report it. Two spans in this port are that
; long: text_print holds DI across a whole string (a chat line is 2-3ms,
; and the chat line is repainted on every keystroke), and buffers.asm's
; flip_sync holds it across a whole rectangle (a dirty_all sync is 320x256
; bytes of LDIR, ~80ms). Both now call this between units of work. Reported
; as chat swallowing characters and lost cursor/SPACE presses, second MAME
; round, 2026-08-16.
;
; PORT_Y is parked first for the usual R3/R10 reason (no VRAM row selected
; across an EI); callers re-select their row on the next iteration. DSS's
; #0038 handler saves and restores AF/AF'/BC/DE/HL and the alternate set
; plus IX/IY (DSS-MAIN.ASM's INTx38_Handler), so callers keep their live
; registers across this call apart from AF.
irq_yield_vram:
        acc_park_y
        ei
        nop                             ; the Z80 accepts an interrupt only
                                         ; AFTER the instruction following EI
        di
        ld      a,VRAM_ALIAS_OPAQUE     ; unconditional: DSS is documented to
        out     (WIN3_PORT),a           ; remap page 3 without restoring it
        ret

; Copies front_base -> back_base for every logged rect, or the whole
; buffer if dirty_all, so the buffer that just went into hiding behind a
; confirmed flip matches what is now on screen again. Call only after
; resolve_buffers has been refreshed for the buffers' NEW roles (front_base
; is the copy SOURCE here) -- frame_wait's own sequencing already does
; this (resolve_buffers immediately before flip_sync).
;
; Same-row VRAM mirror copies follow gfx640 copy_direct_chunk. Blocks
; never exceed 256 bytes; both buffer directions share PORT_Y. Each row
; yields with the accelerator off and PORT_Y parked.
flip_sync:
        ld      a,(flip_dirty_all)
        or      a
        jr      nz,.sync_all
        ld      a,(flip_ring_count)
        or      a
        jr      z,.reset                ; nothing pending
        ld      (.remaining),a
        ld      hl,flip_ring
        ld      (.entry),hl
.rect_loop:
        ld      hl,(.entry)
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (.x),de
        ld      a,(hl)
        inc     hl
        ld      (.y),a
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (.w),de
        ld      a,(hl)
        inc     hl
        ld      (.h),a
        ld      (.entry),hl

        call    .copy_rect

        ld      hl,.remaining
        dec     (hl)
        jr      nz,.rect_loop
        jr      .reset
.sync_all:
        ld      de,0
        ld      (.x),de
        xor     a
        ld      (.y),a
        ld      de,320
        ld      (.w),de
        xor     a
        ld      (.h),a          ; 0 -> 256 rows (whole buffer)
        call    .copy_rect
        jr      .reset
.reset:
        jp      flip_ring_reset

; Copies the rectangle in .x/.y/.w/.h from front_base to back_base. .h=0
; means 256 rows (matches the accelerator's own "0 means 256" convention
; used throughout this port): the row loop below runs the body once before
; testing for zero, so an initial 0 still executes exactly 256 times.
; Caller must hold DI (this port's convention throughout gfx_core.asm) --
; actually opens its own DI/EI here, like every other VRAM primitive, so
; it is safe to CALL back-to-back. Clobbers AF, BC, DE, HL.
.copy_rect:
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a
        ld      a,(.h)
        ld      (.rows_left),a
        ld      a,(.y)
        ld      (.row),a
        jr      .copy_row
.copy_chunk:
        ld      (.copy_size+1),a
        ACC_SET_SIZE
.copy_size:
        ld      a,0
        ACC_COPY_H
        ld      a,(hl)
        ld      (de),a
        ACC_OFF
        ret
.copy_row:
        ld      a,(.row)
        out     (PORT_Y),a
        ld      hl,(front_base)
        ld      de,(.x)
        add     hl,de
        push    hl
        ld      hl,(back_base)
        add     hl,de
        ex      de,hl
        pop     hl
        ld      bc,(.w)
        ld      a,b
        or      a
        jr      z,.short_row
        xor     a                       ; 256-byte first block
        call    .copy_chunk
        ld      a,c
        or      a
        jr      z,.row_done
        push    bc
        ld      bc,256
        add     hl,bc
        ex      de,hl
        add     hl,bc
        ex      de,hl
        pop     bc
.short_row:
        ld      a,c
        call    .copy_chunk
.row_done:
        ld      hl,.row
        inc     (hl)
        ld      hl,.rows_left
        dec     (hl)
        jr      z,.copy_done

        ; Keyboard rescue between rows (at most two hardware bursts).
        ; Every register this loop needs is re-read from memory
        ; at .copy_row, so only AF is at risk here. Safe against a mid-copy
        ; flip: frame_wait only calls flip_sync once the ISR has already
        ; consumed flip_request, so the interrupt admitted here has no
        ; pending flip left to act on.
        call    irq_yield_vram
        jr      .copy_row

.copy_done:
        acc_park_y
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.x:          DW 0
.y:          DB 0
.w:          DW 0
.h:          DB 0
.saved_win3: DB 0
.rows_left:  DB 0
.row:        DB 0
.remaining:  DB 0
.entry:      DW 0

flip_ring EQU LOWRAM_FLIP_RING_ADDR
        ASSERT LOWRAM_FLIP_RING_SIZE >= FLIP_RING_MAX*6
flip_ring_count: DB 0
flip_dirty_all:  DB 0

        ENDIF
