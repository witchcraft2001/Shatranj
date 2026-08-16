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

; Reads the asset pages' physical numbers from HDR (0 pages -> #FF, the
; "unavailable" marker render_core.asm/render.c check before drawing any
; tile). Called once from C's main(). Piece pages 1/2 need >=3 asset pages
; total (page 0 is font/UI); scene_s4.asm's scene_init established this
; same >=3 gate and #FF-when-unavailable convention for the piece pages
; before it was deleted (plan D4) -- centralised here instead of repeated
; per render_core.asm call, since it is boot-time HDR state, not per-draw
; state. ovl_win3_page (S5 substep 3b: RULES/BOARD overlay blobs, tools/
; make_sprinter_overlay_page.py) is the fourth asset page, needing >=4
; total, same #FF-when-unavailable convention. cold_win3_page (S7 step 4:
; the whole of render_core.asm/render_core_cold.asm, tools/make_sprinter_
; cold_page.py, reached through tools/gen_sprinter_cold_thunks.py's WIN1
; stubs) is the fifth, needing >=5, same convention again. ovl_win3_page2
; (S8 step 8b: the NET overlay's own second WIN3 page, tools/make_sprinter_
; overlay_page.py's LAYOUT2) is the SIXTH asset page, needing >=6 -- added
; last in the --assets order specifically so it never shifts any of the
; first five pages' own indices. Clobbers AF.
bench_init:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGES_OFFSET)
        or      a
        jr      nz,.have
        ld      a,#FF
        ld      (bench_asset_page),a
        ld      (piece_page1),a
        ld      (piece_page2),a
        ld      (ovl_win3_page),a
        ld      (cold_win3_page),a
        ld      (ovl_win3_page2),a
        ret
.have:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET)
        ld      (bench_asset_page),a
        ld      (text_font_page),a

        ld      a,(HDR_ADDR+HDR_ASSET_PAGES_OFFSET)
        cp      3
        jr      nc,.have_pieces
        ld      a,#FF
        ld      (piece_page1),a
        ld      (piece_page2),a
        ld      (ovl_win3_page),a
        ld      (cold_win3_page),a
        ld      (ovl_win3_page2),a
        ret
.have_pieces:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+1)
        ld      (piece_page1),a
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+2)
        ld      (piece_page2),a

        ld      a,(HDR_ADDR+HDR_ASSET_PAGES_OFFSET)
        cp      4
        jr      nc,.have_ovl_win3_page
        ld      a,#FF
        ld      (ovl_win3_page),a
        ld      (cold_win3_page),a
        ld      (ovl_win3_page2),a
        ret
.have_ovl_win3_page:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+3)
        ld      (ovl_win3_page),a

        ld      a,(HDR_ADDR+HDR_ASSET_PAGES_OFFSET)
        cp      5
        jr      nc,.have_cold_win3_page
        ld      a,#FF
        ld      (cold_win3_page),a
        ld      (ovl_win3_page2),a
        ret
.have_cold_win3_page:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+4)
        ld      (cold_win3_page),a

        ld      a,(HDR_ADDR+HDR_ASSET_PAGES_OFFSET)
        cp      6
        jr      nc,.have_ovl_win3_page2
        ld      a,#FF
        ld      (ovl_win3_page2),a
        ret
.have_ovl_win3_page2:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+5)
        ld      (ovl_win3_page2),a
        ret
bench_asset_page: DB #FF
piece_page1: DB #FF
piece_page2: DB #FF
ovl_win3_page: DB #FF
cold_win3_page: DB #FF
ovl_win3_page2: DB #FF

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
FLIP_RING_MAX EQU 16

flip_arg_x: DW 0
flip_arg_y: DB 0
flip_arg_w: DW 0
flip_arg_h: DB 0

; Appends one ring entry from (flip_arg_x/y/w/h). Ring full -> dirty_all
; instead (a superset of any rect it would have held, so nothing is lost,
; only coalesced). Clobbers AF, DE, HL.
flip_log_rect:
        ld      a,(flip_ring_count)
        cp      FLIP_RING_MAX
        jr      nc,.overflow
        ld      l,a
        ld      h,0
        add     hl,hl                   ; *2
        ld      d,h
        ld      e,l
        add     hl,hl                   ; *4
        add     hl,de                   ; *6 (entry size)
        ld      de,flip_ring
        add     hl,de
        ld      de,(flip_arg_x)
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      a,(flip_arg_y)
        ld      (hl),a
        inc     hl
        ld      de,(flip_arg_w)
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      a,(flip_arg_h)
        ld      (hl),a
        ld      a,(flip_ring_count)
        inc     a
        ld      (flip_ring_count),a
        ret
.overflow:
        jp      flip_mark_dirty_all

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
; Plain per-row LDIR, not the accelerator: front_base/back_base differ by
; exactly 320 bytes (VRAM_BUF1-VRAM_BUF0), the row width itself, so both
; buffers' bytes for one PORT_Y-selected row coexist in the SAME mapped
; WIN3 window -- an ordinary CPU copy, no accelerator trigger needed. This
; deliberately does NOT attempt an accelerator-based whole-buffer copy
; (gfx_blit_rows) for the dirty_all case either: VRAM-to-VRAM through the
; accelerator is a genuinely new use of the hardware no reference
; implementation available to this port has ever exercised (every existing
; ACC_COPY_* use here sources from WIN0/RAM, never from VRAM itself), so
; this sticks to the proven-shape plain LDIR uniformly rather than carry
; that unproven assumption into the very first flip checkpoint. A later
; pass can revisit this once MAME/hardware time budget is measured
; (docs/sprinter-render-budget.md).
;
; Duplicate/overlapping ring entries are harmless (the copy is idempotent).
; Each rectangle's copy runs under one DI span covering every row (S5-
; finish plan D11 audit defect #2: no EI gap inside a rectangle, matching
; every other VRAM primitive's own "whole call under DI" discipline).
; Clobbers AF, BC, DE, HL.
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
        ldir
        ld      hl,.row
        inc     (hl)
        ld      hl,.rows_left
        dec     (hl)
        jr      z,.copy_done

        ; Keyboard rescue between rows (~0.3ms of DI each). See
        ; irq_yield_vram just above: a dirty_all sync is 320x256 bytes
        ; of LDIR, ~80ms with interrupts off, and DSS's keyboard FIFO is
        ; three bytes deep before its overrun handler starts discarding
        ; scancodes. Every register this loop needs is re-read from memory
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

flip_ring:       DS FLIP_RING_MAX*6, 0
flip_ring_count: DB 0
flip_dirty_all:  DB 0

        ENDIF
