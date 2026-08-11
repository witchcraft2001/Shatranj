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

; Reads the asset pages' physical numbers from HDR (0 pages -> #FF, the
; "unavailable" marker render_core.asm/render.c check before drawing any
; tile). Called once from C's main(). Piece pages 1/2 need >=3 asset pages
; total (page 0 is font/UI); scene_s4.asm's scene_init established this
; same >=3 gate and #FF-when-unavailable convention for the piece pages
; before it was deleted (plan D4) -- centralised here instead of repeated
; per render_core.asm call, since it is boot-time HDR state, not per-draw
; state. Clobbers AF.
bench_init:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGES_OFFSET)
        or      a
        jr      nz,.have
        ld      a,#FF
        ld      (bench_asset_page),a
        ld      (piece_page1),a
        ld      (piece_page2),a
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
        ret
.have_pieces:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+1)
        ld      (piece_page1),a
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+2)
        ld      (piece_page2),a
        ret
bench_asset_page: DB #FF
piece_page1: DB #FF
piece_page2: DB #FF

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

        ENDIF
