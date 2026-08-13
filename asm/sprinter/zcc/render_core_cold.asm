; Cold rendering primitives, split out of render_core.asm (S7 step 4
; byte-budget ladder): the boot-only paints (video_clear_both_buffers,
; render_banner), the FLIP-only one (render_coord_labels) and the whole
; FILEUI screen (spectrum_render_fileui_frame/_ikkle_at/_select, S6 plan
; step 4).
;
; z88dk-z80asm module, linked into the WIN3 cold page (asm/sprinter/zcc/
; cold_page_crt0.asm) together with render_core.asm itself -- the file
; split is kept only because these routines are a genuinely separate
; concern, not because they live anywhere different any more. Read
; render_core.asm's header for the placement rationale and the window
; safety argument; everything there applies verbatim to this file, and
; callers reach these three entry points through the same generated
; eight-byte WIN1 stubs (tools/gen_sprinter_cold_thunks.py).
;
; Local labels use z88dk-z80asm's own "@name" convention, same as
; render_core.asm (see that file's own header on why, not sjasmplus's
; ".name").

    MODULE render_core_cold

    EXTERN gfx_fill_rect
    EXTERN gfx_draw_tile
    EXTERN gfx_clear_buffer
    EXTERN text_print
    EXTERN back_base
    EXTERN tile_dest_base
    EXTERN tile_x_byte
    EXTERN tile_x_hi
    EXTERN tile_y
    EXTERN tile_src_page
    EXTERN tile_src_slot
    EXTERN tile_stride
    EXTERN tile_width
    EXTERN tile_rows
    EXTERN tile_alias
    EXTERN bench_asset_page
    EXTERN BOARD_X
    EXTERN BOARD_Y
    EXTERN BOARD_COLS
    EXTERN BOARD_ROWS
    EXTERN BOARD_CELL_W
    EXTERN BOARD_CELL_H
    EXTERN MOVE_Y
    EXTERN LOWRAM_RENDER_SHARED_ADDR

; dss.inc's own values (port.md section 3.3), same constants render_core.
; asm itself hardcodes (its own header explains why: fixed hardware
; constants, not shared address state).
VRAM_BUF0 EQU $C000
VRAM_BUF1 EQU $C140
VRAM_ALIAS_KEY EQU $58

; gui.c's spectrum_gui_board_flipped, fixed-address on Sprinter (gui.c's
; own comment on this same build-order gap) -- referencing the bridged
; address directly under the original C symbol name so the code below
; (moved verbatim from render_core.asm) needs no further edits.
_spectrum_gui_board_flipped EQU LOWRAM_RENDER_SHARED_ADDR

; Duplicated from render_core.asm (S7 step 4): render_coord_labels is the
; only WIN1 caller, but render_square/render_board_full there also need
; these same tables, so they stay defined there too -- two small constant
; tables (24 bytes total) is cheaper and simpler than a third cross-build
; bridge for read-only data that never changes at runtime.
BOARD_X_BYTE EQU BOARD_X/2
MUL_CELL_TABLE:
    defb 0,24,48,72,96,120,144,168
PIXEL_COL_X_TABLE:
    defw 0,48,96,144,192,240,288,336

    SECTION code_user

; No arguments. Pixel-clears both VRAM buffers to colour 0 (black).
; Boot-only, called once from main() before any other painting. See
; render_core.asm's git history (this function moved from there verbatim,
; S7 step 4) for the original S5-finish plan D11 fix note. Clobbers
; everything.
    PUBLIC video_clear_both_buffers
video_clear_both_buffers:
    PUBLIC _video_clear_both_buffers
    defc _video_clear_both_buffers = video_clear_both_buffers
    xor a
    ld hl,VRAM_BUF0
    call gfx_clear_buffer
    xor a
    ld hl,VRAM_BUF1
    jp gfx_clear_buffer

; --- banner --------------------------------------------------------------
;
; Title text left, the real Sprinter logo (hardware-keyed tile) right-
; aligned. Moved from render_core.asm verbatim (S7 step 4) -- see that
; file's git history for the original S4/scene_s4.asm provenance note.
BANNER_COLOR EQU $01
BANNER_TITLE_X EQU 8
BANNER_TITLE_Y EQU 4
banner_title_msg:
    defb "SHATRANJ",0

LOGO_SLOT EQU 44
LOGO_WIDTH_PX EQU 172
LOGO_HEIGHT_PX EQU 16
LOGO_STRIDE EQU LOGO_WIDTH_PX/2
LOGO_MARGIN_PX EQU 8
LOGO_X_BYTE EQU (640-LOGO_WIDTH_PX-LOGO_MARGIN_PX)/2

; No arguments. Paints the banner title and the right-aligned Sprinter
; logo into both VRAM buffers, boot-time-paint. Skips the logo draw
; (title still paints) if bench_asset_page reads #FF -- no asset page
; published. Clobbers everything.
    PUBLIC render_banner
render_banner:
    PUBLIC _render_banner
    defc _render_banner = render_banner
    ld hl,VRAM_BUF0
    call @paint
    ld hl,VRAM_BUF1
    jp @paint
@paint:
    ld (@dest_base),hl
    ld de,banner_title_msg
    ld ix,BANNER_TITLE_X
    ld c,BANNER_TITLE_Y
    ld a,BANNER_COLOR
    ld hl,(@dest_base)
    call text_print

    ld a,(bench_asset_page)
    cp $FF
    ret z                       ; no asset page published -- skip silently

    ld (tile_src_page),a
    ld a,LOGO_SLOT
    ld (tile_src_slot),a
    ld a,LOGO_STRIDE
    ld (tile_width),a
    ld (tile_stride),a
    ld a,LOGO_HEIGHT_PX
    ld (tile_rows),a
    ld a,VRAM_ALIAS_KEY
    ld (tile_alias),a
    ld hl,(@dest_base)
    ld (tile_dest_base),hl
    ld a,LOGO_X_BYTE
    ld (tile_x_byte),a
    ld a,LOGO_X_BYTE/256
    ld (tile_x_hi),a
    xor a
    ld (tile_y),a
    jp gfx_draw_tile
@dest_base: dw 0

; --- coordinate labels -----------------------------------------------------
;
; Moved from render_core.asm verbatim (S7 step 4) -- see that file's git
; history for the full original design note (text_print's opaque-box
; behaviour, the palette-index-0 boot-flash history, the FLIP-repaint
; requirement). Only live caller left in main.c is the FLIP action
; (menu_flip_board) plus the one boot-time paint -- never per-frame.
COORD_COLOR EQU $01
FILE_LABEL_Y EQU MOVE_Y+2
FILE_LABEL_X_OFFSET EQU 20
RANK_LABEL_X EQU 4
RANK_LABEL_Y_OFFSET EQU 8
FILE_LABEL_CLEAR_W_BYTES EQU 192

    PUBLIC render_coord_labels
render_coord_labels:
    PUBLIC _render_coord_labels
    defc _render_coord_labels = render_coord_labels
    ld a,(_spectrum_gui_board_flipped)
    or a
    ld a,0
    jr z,@flip_stored
    ld a,1
@flip_stored:
    ld (@flip),a

    ld hl,(back_base)
    ld (@dest_base),hl

    xor a
    ld b,BOARD_X_BYTE
    ld c,FILE_LABEL_Y
    ld d,FILE_LABEL_CLEAR_W_BYTES
    ld e,8
    ld hl,(@dest_base)
    call gfx_fill_rect

    xor a
    ld (@i),a
@file_loop:
    ld a,(@i)
    add a,a                    ; word index
    ld hl,PIXEL_COL_X_TABLE
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a                      ; HL = PIXEL_COL_X_TABLE[i]
    ld de,BOARD_X
    add hl,de
    ld de,FILE_LABEL_X_OFFSET
    add hl,de
    push hl
    pop ix                       ; IX = x

    ld a,(@flip)
    or a
    jr nz,@file_flipped
    ld a,(@i)
    add a,'a'
    jr @file_char_done
@file_flipped:
    ld a,'h'
    ld hl,@i
    sub (hl)
@file_char_done:
    ld (@label_buf),a
    xor a
    ld (@label_buf+1),a

    ld de,@label_buf
    ld c,FILE_LABEL_Y
    ld a,COORD_COLOR
    ld hl,(@dest_base)
    call text_print

    ld hl,@i
    inc (hl)
    ld a,(hl)
    cp BOARD_COLS
    jp c,@file_loop

    xor a
    ld (@i),a
@rank_loop:
    ld a,(@i)
    ld hl,MUL_CELL_TABLE
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    add a,BOARD_Y
    add a,RANK_LABEL_Y_OFFSET
    ld c,a

    ld a,(@flip)
    or a
    jr nz,@rank_flipped
    ld a,'8'
    ld hl,@i
    sub (hl)
    jr @rank_char_done
@rank_flipped:
    ld a,'1'
    ld hl,@i
    add a,(hl)
@rank_char_done:
    ld (@label_buf),a
    xor a
    ld (@label_buf+1),a

    ld de,@label_buf
    ld ix,RANK_LABEL_X
    ld a,COORD_COLOR
    ld hl,(@dest_base)
    call text_print

    ld hl,@i
    inc (hl)
    ld a,(hl)
    cp BOARD_ROWS
    jp c,@rank_loop
    ret
@dest_base: dw 0
@flip: defb 0
@i: defb 0
@label_buf: defb 0,0

; --- FILEUI (S6 plan step 4) -------------------------------------------------
;
; The panel is exactly the board's own rectangle (BOARD_X/Y/COLS/ROWS/
; CELL_W/CELL_H, already bridged from render_layout.json's "board" object --
; no new named rect needed) -- "over the board area" literally. fileui_
; ovl.c's own row/col units (FILEUI_ROW_HEADER=5 .. FILEUI_ROW_FOOTER=20,
; FILEUI_COL_ITEM=4 etc., src/spectrum/overlay/fileui_ovl.c) map onto it via
; a 12px row pitch (same rhythm as MOVE_ROW_H/MENU_H elsewhere in
; render_core.asm), origin at FILEUI_CONTENT_Y_BASE (BOARD_Y+2, not BOARD_Y
; itself -- round 2's own fix inset row content 2px off the frame's
; left/right border columns but missed that row 5/header's own band sits
; exactly on the top border's own 2px band too, silently erasing it on
; every RENDER; row 20/footer already cleared the bottom border by 3px so
; that one was never broken -- MAME round 3). Column units are 8px
; character cells, same as text_print everywhere else.
;
; No attribute plane on this hardware (direct 4bpp pixel framebuffer, not
; ZX's separate ink/paper attribute cells -- _spectrum_render_connection's
; own comment on the same limitation, render_core.asm) -- fileui_ovl.c's
; five ZX-style attr byte values (FILEUI_ATTR_HEADER/LEGEND/SAVED/FREE/
; FOOTER) are translated into this port's own bg<<4|fg palette bytes below,
; not reused verbatim. The row-select highlight (spectrum_render_fileui_
; select) cannot be a ZX-style attribute-only inversion for the same
; reason, and it is called without the row's own text (fileui.c's fully-
; resident cursor nav, by design, never reloads the overlay just to move
; the cursor) -- so instead of a filled+inverted box like the menu bar's
; own per-tab highlight (render_menu_tabs, render_core.asm), it draws an
; outline rectangle around (not behind) the row's item-name field, matching
; that same "selection is a rectangle" convention without needing the
; row's text to redraw. See that routine's own header for the round-1/
; round-2 history (a blank marker box, then a ">" glyph, before landing
; here) and for FILEUI_CONTENT_B/_W_BYTES right below, the inset that
; keeps every row's own content clear off the frame's own border pixels.
FILEUI_X EQU BOARD_X
FILEUI_ROW_BASE EQU 5              ; fileui_ovl.c's FILEUI_ROW_HEADER, the
                                     ; smallest row this overlay ever passes
FILEUI_ROW_PITCH EQU 12
FILEUI_ROW_FOOTER EQU 20            ; fileui_ovl.c's own FILEUI_ROW_FOOTER
FILEUI_HEADER_Y_PAD EQU 3           ; px, clear of the top border (S6 MAME
                                     ; round 7 -- see spectrum_render_ikkle_
                                     ; at's own header/footer Y-nudge)
FILEUI_FOOTER_Y_PAD EQU 3           ; px, clear of the bottom border
FILEUI_COL_ITEM EQU 4               ; fileui_ovl.c's own FILEUI_COL_ITEM,
                                     ; the column where each row's item
                                     ; text starts
FILEUI_FRAME_W_BYTES EQU (BOARD_COLS*BOARD_CELL_W)/2
FILEUI_FRAME_H EQU BOARD_ROWS*BOARD_CELL_H

FILEUI_COLOR_NORMAL EQU $01        ; bg=0, fg=1 -- header/saved-game rows
FILEUI_COLOR_DIM EQU $0D           ; bg=0, fg=13 (hud_muted) -- legend/free/footer
FILEUI_ATTR_HEADER EQU $38         ; fileui_ovl.c's own ZX-attr constants,
FILEUI_ATTR_SAVED EQU $05          ; compared against verbatim below (this
                                     ; file never reinterprets their bits,
                                     ; only recognises the whole byte)
; fileui_ovl.c's own FILEUI_COL_HEADER=12 places the header at column 12 of
; the panel's 24-column line width -- roughly right for a fixed 8px/char
; grid, but this port's text is proportional (afnt640's own font.bin) and
; " SAVED GAMES" only comes out 35 byte-columns (70px) wide, so col 12
; (96px in) leaves it noticeably off-centre, closer to the right half than
; centred (tester report, S6 MAME round 4). fileui_ovl.c is shared with
; ZX/Next and its own column math is presumably correct for their fixed-
; width font, so the fix has to live here, not there (same reasoning as
; render_menu_tabs's own per-label centring table, render_core.asm):
; ignore FILEUI_COL_HEADER for this one row and use a hardcoded centred X
; instead, measured directly from font.bin's own packed-column-width table
; (space=2,S=3,A=3,V=3,E=3,D=3,space=2,G=3,A=3,M=4,E=3,S=3 byte-columns =
; 35 = 70px; centred in FILEUI_FRAME_W_BYTES*2=384px panel width:
; (384-70)/2=157, rounded to the nearest even value text_print's IX
; requires).
FILEUI_HEADER_TEXT_X EQU FILEUI_X+156

FILEUI_BORDER_COLOR EQU 1
FILEUI_TOP_B EQU FILEUI_X/2
FILEUI_BOTTOM_Y EQU BOARD_Y+FILEUI_FRAME_H-2
FILEUI_RIGHT_B EQU FILEUI_X/2+FILEUI_FRAME_W_BYTES-1
; Every row's own content clear (spectrum_render_ikkle_at) used to span the
; frame's own left/right 1-byte border columns (FILEUI_TOP_B..FILEUI_
; RIGHT_B) -- since it repaints on every RENDER/list-only refresh at each
; row's own Y band, it wiped the border pixels at every row and left only
; the ~4px inter-row gaps looking solid, i.e. a dashed/"torn" frame (tester
; report, S6 P19 round 1). Content clear is inset by one byte (2px) on each
; side so it never touches the border bytes.
FILEUI_CONTENT_B EQU FILEUI_TOP_B+1
FILEUI_CONTENT_W_BYTES EQU FILEUI_FRAME_W_BYTES-2
; The X inset above didn't cover Y: row 5 (header)'s own Y band starts at
; BOARD_Y+(5-FILEUI_ROW_BASE)*12 = BOARD_Y exactly -- the same 2px band the
; top border occupies -- so header's content clear wiped the ENTIRE top
; border on every RENDER (round 2's own screenshot still showed it missing,
; while bottom border survived: FILEUI_ROW_FOOTER's own band ends 3px
; before FILEUI_BOTTOM_Y, clear of it already). Row content's own Y origin
; is offset 2px below BOARD_Y so no row ever reaches back up into the top
; border's band; used in place of BOARD_Y in both spectrum_render_ikkle_at
; and spectrum_render_fileui_select's row-Y arithmetic (must stay identical
; between the two, same as FILEUI_ROW_FIRST_OFFSET already is).
FILEUI_CONTENT_Y_BASE EQU BOARD_Y+2

; void spectrum_render_fileui_frame(void). Panel background (bg colour)
; plus a 2px border around the board's own rectangle. Single-pass (back_
; base only), event-driven (FILEUI RENDER, mode 0 only -- fileui_ovl.c's
; own list_only check skips this on a list-only refresh). Clobbers
; everything.
    PUBLIC _spectrum_render_fileui_frame
_spectrum_render_fileui_frame:
    ld hl,(back_base)
    ld (@dest_base),hl

    xor a
    ld b,FILEUI_TOP_B
    ld c,BOARD_Y
    ld d,FILEUI_FRAME_W_BYTES
    ld e,FILEUI_FRAME_H
    ld hl,(@dest_base)
    call gfx_fill_rect

    ld a,FILEUI_BORDER_COLOR
    ld b,FILEUI_TOP_B
    ld c,BOARD_Y
    ld d,FILEUI_FRAME_W_BYTES
    ld e,2
    ld hl,(@dest_base)
    call gfx_fill_rect

    ld a,FILEUI_BORDER_COLOR
    ld b,FILEUI_TOP_B
    ld c,FILEUI_BOTTOM_Y
    ld d,FILEUI_FRAME_W_BYTES
    ld e,2
    ld hl,(@dest_base)
    call gfx_fill_rect

    ld a,FILEUI_BORDER_COLOR
    ld b,FILEUI_TOP_B
    ld c,BOARD_Y
    ld d,1
    ld e,FILEUI_FRAME_H
    ld hl,(@dest_base)
    call gfx_fill_rect

    ld a,FILEUI_BORDER_COLOR
    ld b,FILEUI_RIGHT_B
    ld c,BOARD_Y
    ld d,1
    ld e,FILEUI_FRAME_H
    ld hl,(@dest_base)
    jp gfx_fill_rect
@dest_base: dw 0

; void spectrum_render_ikkle_at(const char *spec) __z88dk_fastcall (HL).
; spec[0]=row, spec[1]=col (8px char cells), spec[2]=attr (fileui_ovl.c's
; FILEUI_ATTR_*), spec[3..]=ASCIIZ text -- fileui_ovl.c's own fileui_text()
; builds exactly this layout on the stack.
;
; Clears the row's full panel width before printing regardless of where the
; text itself starts (P18's own 'f'-sliver lesson: text_print's box is only
; as wide as each proportional glyph, so a shrinking line would otherwise
; leave stale pixels behind) -- proportional-font column alignment is
; therefore approximate, not pixel-exact; rows are uniform ("GAMEn"+digits
; or "-FREE-", both fixed-ish width) so this reads fine in practice, tester
; judges. Single-pass (back_base only), event-driven. Clobbers everything.
    PUBLIC _spectrum_render_ikkle_at
_spectrum_render_ikkle_at:
    ld a,(hl)
    ld (@row),a
    inc hl
    ld a,(hl)
    ld (@col),a
    inc hl
    ld a,(hl)
    ld (@attr),a
    inc hl
    ld (@text),hl

    ld hl,(back_base)
    ld (@dest_base),hl

    ld a,(@row)
    sub FILEUI_ROW_BASE
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    ld b,h
    ld c,l
    add hl,hl
    add hl,bc
    ld de,FILEUI_CONTENT_Y_BASE
    add hl,de

; Header/footer sit flush against the frame's own top/bottom border (0px
; gap -- header's Y band starts the row right after the 2px border, footer's
; own band ends exactly on FILEUI_BOTTOM_Y), reading as merged with the
; frame rather than as separate rows (tester report, S6 MAME round 7).
; Nudge just these two rows a few px clear of the border they're each
; adjacent to, folded into this same L-to-@y store (no separate reload --
; every spare byte counts, this image has almost none left); keyed off the
; row number itself, not @attr, since fileui_ovl.c's own FILEUI_ATTR_LEGEND
; and FILEUI_ATTR_FOOTER share the same byte value (0x06) and so cannot
; tell footer apart from legend. Safe: the whole panel background is
; repainted before any row text on a full RENDER, and both rows have
; >10px of empty space on the far side from the border (header before
; row 7/legend, footer after the last of the 10 slot rows), so a small
; shift can't collide with anything else.
    ld a,(@row)
    cp FILEUI_ROW_BASE
    jr nz,@y_check_footer
    ld a,l
    add a,FILEUI_HEADER_Y_PAD
    jr @y_store
@y_check_footer:
    cp FILEUI_ROW_FOOTER
    jr nz,@y_normal
    ld a,l
    sub FILEUI_FOOTER_Y_PAD
    jr @y_store
@y_normal:
    ld a,l
@y_store:
    ld (@y),a

    ld a,(@col)
    add a,a
    add a,a
    add a,a
    add a,FILEUI_X
    ld (@x),a

    ld a,(@attr)
    cp FILEUI_ATTR_HEADER
    jr nz,@x_done
    ld a,FILEUI_HEADER_TEXT_X
    ld (@x),a
@x_done:
    ld a,(@attr)
    cp FILEUI_ATTR_HEADER
    jr z,@normal
    cp FILEUI_ATTR_SAVED
    jr z,@normal
    ld a,FILEUI_COLOR_DIM
    jr @color_done
@normal:
    ld a,FILEUI_COLOR_NORMAL
@color_done:
    ld (@color),a

    ld b,FILEUI_CONTENT_B
    ld a,(@y)
    ld c,a
    ld d,FILEUI_CONTENT_W_BYTES
    ld e,8
    xor a
    ld hl,(@dest_base)
    call gfx_fill_rect

    ld de,(@text)
    ld a,(@x)
    ld ixl,a
    ld ixh,0
    ld a,(@y)
    ld c,a
    ld a,(@color)
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0
@text: dw 0
@row: defb 0
@col: defb 0
@attr: defb 0
@x: defb 0
@y: defb 0
@color: defb 0

; void spectrum_render_fileui_select(uint16_t slot_on) __z88dk_fastcall
; (HL). Low byte = slot (0-9), high byte nonzero = selected (fileui.c's own
; `(1u<<8)|sel` on / plain `prev` off convention). Paints (on) or erases
; (off) a 1px outline rectangle around the row's own full text field
; (FILEUI_COL_ITEM..+17 chars, wide enough for "GAMEnn    DD-MM-YY HH:MM",
; not just the name -- sized against real content in S6 MAME round 7 after
; the original 8-char/name-only width was shown clipping the date/time
; fields, back when only "-FREE-" existed to test the box against) --
; round 1 tried
; first a plain filled box in the row's empty margin (positionally correct,
; but read as a rendering glitch, not a cursor) and then a literal ">"
; glyph (readable on its own, but inconsistent with the rest of this app's
; own UI, where focus/selection is always a rectangle -- render_menu_tabs's
; own per-tab highlight box, the same convention the FILE/DISCC/... menu
; bar already uses). A filled+inverted box like the menu tabs' own is not
; available here without knowing the row's text (fileui.c's cursor nav is
; fully resident and never reloads the overlay just to move the cursor,
; per this section's own header), so this is an outline, not a fill: four
; thin fill_rect strips around (not behind) the name field, inset 2px so
; the border pixels never touch a glyph's own pixels, and vertically inset
; into the row's own 4px inter-row gap (FILEUI_SEL_Y_PAD) so it never
; overlaps the 8px glyph band above or below either. Single-pass (back_base
; only), event-driven (every cursor move while FILEUI is open). Clobbers
; everything.
FILEUI_ROW_FIRST_OFFSET EQU 4          ; FILEUI_ROW_FIRST(9) - FILEUI_ROW_BASE(5)
; 17 chars * 8px covers the full row line's real pixel width (measured from
; extern/sprinter-libs/afnt640/font.bin's own packed-column-width table,
; same method as FILEUI_HEADER_TEXT_X below: "GAME1    13-08-26 " is 50
; byte-columns/100px before the time field even starts, plus "08:22" itself
; at 14 byte-columns/28px, ~128px total -- 17*8=136px leaves a small margin
; without reaching FILEUI_CONTENT_B's own right edge, S6 MAME round 7).
FILEUI_SEL_COLS EQU 17
FILEUI_SEL_X_PAD EQU 2                  ; px, clear of the name field's own
                                          ; glyph pixels on both sides
FILEUI_SEL_X EQU FILEUI_X+FILEUI_COL_ITEM*8-FILEUI_SEL_X_PAD
FILEUI_SEL_B EQU FILEUI_SEL_X/2
FILEUI_SEL_W_BYTES EQU (FILEUI_SEL_COLS*8+2*FILEUI_SEL_X_PAD)/2
FILEUI_SEL_RIGHT_B EQU FILEUI_SEL_B+FILEUI_SEL_W_BYTES-1
FILEUI_SEL_Y_PAD EQU 1                  ; px, sits in the row's own 4px
                                          ; inter-row gap (12px pitch - 8px
                                          ; glyph band), never the glyphs
FILEUI_SEL_H EQU 8+2*FILEUI_SEL_Y_PAD
FILEUI_SEL_COLOR EQU 1

    PUBLIC _spectrum_render_fileui_select
_spectrum_render_fileui_select:
    ld a,h                           ; capture on/off before any HL math
    or a
    ld a,0
    jr z,@have_color
    ld a,FILEUI_SEL_COLOR
@have_color:
    ld (@color),a

    ld a,l                           ; slot (low byte of the original arg)
    add a,FILEUI_ROW_FIRST_OFFSET
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    ld b,h
    ld c,l
    add hl,hl
    add hl,bc
    ld de,FILEUI_CONTENT_Y_BASE
    add hl,de
    ld a,l
    sub FILEUI_SEL_Y_PAD
    ld (@y0),a

    ld hl,(back_base)
    ld (@dest_base),hl

    ; top edge (1px)
    ld b,FILEUI_SEL_B
    ld a,(@y0)
    ld c,a
    ld d,FILEUI_SEL_W_BYTES
    ld e,1
    ld a,(@color)
    ld hl,(@dest_base)
    call gfx_fill_rect

    ; bottom edge (1px)
    ld b,FILEUI_SEL_B
    ld a,(@y0)
    add a,FILEUI_SEL_H-1
    ld c,a
    ld d,FILEUI_SEL_W_BYTES
    ld e,1
    ld a,(@color)
    ld hl,(@dest_base)
    call gfx_fill_rect

    ; left edge (1 byte = 2px, full box height)
    ld b,FILEUI_SEL_B
    ld a,(@y0)
    ld c,a
    ld d,1
    ld e,FILEUI_SEL_H
    ld a,(@color)
    ld hl,(@dest_base)
    call gfx_fill_rect

    ; right edge (1 byte = 2px, full box height)
    ld b,FILEUI_SEL_RIGHT_B
    ld a,(@y0)
    ld c,a
    ld d,1
    ld e,FILEUI_SEL_H
    ld a,(@color)
    ld hl,(@dest_base)
    jp gfx_fill_rect

@dest_base: dw 0
@y0: defb 0
@color: defb 0
