    EXTERN LOWRAM_PIECE_STATE_ADDR, LOWRAM_TEXT_STAGE_ADDR
; S14 MENU_CONFIG: no nested overlay dispatch. Context byte 0 is the
; focus/theme parameter. Piece state lives in WIN2 across video_init.
SECTION code_user
EXTERN gfx_fill_rect, text_print, back_base
EXTERN piece_page1, piece_page2, palette_rgb, palette_apply_from
EXTERN MENU_Y, PANEL_X
    defb 4
    defw menu_render, pieces_init, theme_apply, pieces_next
menu_render:
    ld a,(hl)
    jp render_menu_tabs
pieces_init:
    xor a
    jp pieces_select
pieces_next:
    ld a,(LOWRAM_PIECE_STATE_ADDR)
    inc a
pieces_select:
@mod:
    cp PIECE_LOCATION_COUNT
    jr c,@valid
    sub PIECE_LOCATION_COUNT
    jr @mod
@valid:
    ld (LOWRAM_PIECE_STATE_ADDR),a
    push af
    add a,a
    add a,a
    ld e,a
    ld d,0
    ld hl,piece_set_locations
    add hl,de
    ld de,LOWRAM_PIECE_STATE_ADDR+1
    ld b,2
@pair:
    ld a,(hl)
    inc hl
    cp 1
    ld a,(piece_page1)
    jr z,@page
    ld a,(piece_page2)
@page:
    ld (de),a
    inc de
    ld a,(hl)
    inc hl
    ld (de),a
    inc de
    djnz @pair
    pop af
    ld hl,piece_set_rgb
    or a
    jr z,@rgb
    ld b,a
@stride:
    ld de,12
    add hl,de
    djnz @stride
@rgb:
    ld de,palette_rgb+12
    ld bc,12
    ldir
    ld hl,palette_rgb
    jp palette_apply_from
theme_apply:
    ld a,(hl)
@mod:
    cp THEME_COUNT
    jr c,@valid
    sub THEME_COUNT
    jr @mod
@valid:
    ld hl,theme_squares_rgb
    or a
    jr z,@rgb
    ld b,a
@stride:
    ld de,6
    add hl,de
    djnz @stride
@rgb:
    ld de,palette_rgb+6
    ld bc,6
    ldir
    ld hl,palette_rgb
    jp palette_apply_from
INCLUDE "theme_squares.inc"
INCLUDE "piece_set_palettes.inc"
INCLUDE "piece_locations.inc"
ASSERT PIECE_LOCATION_COUNT = PIECE_SET_COUNT
MENU_COLOR EQU $01             ; bg=0 (screen bg), fg=1 (text) -- unfocused
MENU_COLOR_FOCUS EQU $10       ; bg=1 (highlight fill), fg=0 -- focused text
MENU_TAB_COUNT EQU 7
MENU_LABEL_X EQU 8
MENU_LABEL_Y EQU MENU_Y+2      ; vertically centre an 8px glyph in the
                                ; 12px-tall MENU band
MENU_TAB_PITCH EQU 48          ; px, even; widest label (THEME, 32px) plus
                                ; box padding fits with room to spare
MENU_BOX_X_PAD EQU 4           ; px, box left edge relative to the label's
                                ; own X
MENU_BOX_W EQU 40               ; px; MENU_BOX_W_BYTES is gfx_fill_rect's
                                 ; D (width in bytes, 2px/byte)
MENU_BOX_W_BYTES EQU MENU_BOX_W/2
MENU_H EQU 12                   ; same 12px rhythm as every other row band
                                 ; (MOVE_ROW_H, STATUS_H...)
MENU_ROW_CLEAR_W_BYTES EQU PANEL_X/2   ; clears only the tab area, leaves
                                         ; TURN_LABEL (PANEL_X+) untouched

menu_tab_x_table:
    defw MENU_LABEL_X+0*MENU_TAB_PITCH
    defw MENU_LABEL_X+1*MENU_TAB_PITCH
    defw MENU_LABEL_X+2*MENU_TAB_PITCH
    defw MENU_LABEL_X+3*MENU_TAB_PITCH
    defw MENU_LABEL_X+4*MENU_TAB_PITCH
    defw MENU_LABEL_X+5*MENU_TAB_PITCH
    defw MENU_LABEL_X+6*MENU_TAB_PITCH

; Per-tab absolute text X (S5-finish plan F2, the cosmetic fix fix #3's own
; MAME confirmation deferred): box_left(tab) + a centring offset, so the
; label sits centred in its MENU_BOX_W-wide highlight box instead of pinned
; to the box's left edge like fix #3 shipped it -- short labels (FILE/FLIP,
; 20px) had a lot of empty space on the box's right, long ones (THEME,
; 32px) almost none, confirmed by the human tester in MAME and tracked as
; non-blocking. Offset is (MENU_BOX_W-label_width) truncated to the nearest
; EVEN number via (/4)*2, not the exact /2 centre, because text_print's IX
; must be even (2px/byte packed columns, see text640.asm's own banner) --
; box_left is always even (MENU_LABEL_X/MENU_TAB_PITCH/MENU_BOX_X_PAD all
; even) so an even offset is what keeps the sum even. Label widths are the
; same font.bin packed-column-width readout fix #3 already used: FILE=20,
; DISCC=26, RESET=30, FLIP=20, THEME=32, ABOUT=30px.
menu_label_x_table:
    defw MENU_LABEL_X+0*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-20)/4)*2 ; FILE
    defw MENU_LABEL_X+1*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-26)/4)*2 ; DISCC
    defw MENU_LABEL_X+2*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-30)/4)*2 ; RESET
    defw MENU_LABEL_X+3*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-20)/4)*2 ; FLIP
    defw MENU_LABEL_X+4*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-32)/4)*2 ; THEME
    defw MENU_LABEL_X+5*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-32)/4)*2 ; PIECES

    defw MENU_LABEL_X+6*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-30)/4)*2

menu_tab_names:
    defw @file_msg, @discc_msg, @rest_msg, @flip_msg, @theme_msg, @pieces_msg, @about_msg
@file_msg: defb "FILE",0
@discc_msg: defb "DISCC",0
@rest_msg: defb "RESET",0
@flip_msg: defb "FLIP",0
@theme_msg: defb "THEME",0
@pieces_msg: defb "PIECES",0
@about_msg: defb "ABOUT",0

; A=focus index in (0-6 highlighted; MENU_TAB_COUNT or higher = none, i.e.
; closed). Clears the tab row's own background, then paints all seven
; labels; whichever index matches A gets a highlight box (gfx_fill_rect)
; painted behind it first and MENU_COLOR_FOCUS ink instead of MENU_COLOR.
; Single-pass (back_base only) -- reachable live every open/close/
; navigate. Clobbers everything.
render_menu_tabs:
    ld (@focus),a
    ld hl,(back_base)
    ld (@dest_base),hl

    xor a
    ld b,0
    ld c,MENU_Y
    ld d,MENU_ROW_CLEAR_W_BYTES
    ld e,MENU_H
    ld hl,(@dest_base)
    call gfx_fill_rect

    xor a
    ld (@i),a
@loop:
    ld a,(@i)
    ld hl,menu_tab_x_table
    add a,a
    ld e,a
    ld d,0
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (@x),de

    ld a,(@i)
    ld hl,menu_label_x_table
    add a,a
    ld e,a
    ld d,0
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (@text_x),de

    ld a,(@i)
    add a,a
    ld hl,menu_tab_names
    ld e,a
    ld d,0
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (@label),de

    ld a,(@i)
    ld hl,@focus
    cp (hl)
    ld a,MENU_COLOR
    jr nz,@color_set
    call @paint_box
    ld a,MENU_COLOR_FOCUS
@color_set:
    ld (@color),a

    ld hl,(@label)
    ld de,LOWRAM_TEXT_STAGE_ADDR
@copy:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    or a
    jr nz,@copy
    ld de,LOWRAM_TEXT_STAGE_ADDR
    ld ix,(@text_x)
    ld c,MENU_LABEL_Y
    ld a,(@color)
    ld hl,(@dest_base)
    call text_print

    ld a,(@i)
    inc a
    ld (@i),a
    cp MENU_TAB_COUNT
    jr nz,@loop
    ret

; Local helper, called (not jumped) from the loop above so it returns
; into it. Paints the MENU_COLOR_FOCUS highlight box behind (@i)'s tab.
; Clobbers everything.
@paint_box:
    ld hl,(@x)
    ld de,MENU_BOX_X_PAD
    or a
    sbc hl,de
    srl h
    rr l
    ld a,l                        ; px -> byte offset
    ld b,a
    ld c,MENU_Y
    ld d,MENU_BOX_W_BYTES
    ld e,MENU_H
    ld a,1                       ; palette index 1, matches MENU_COLOR_
                                  ; FOCUS's bg nibble above
    ld hl,(@dest_base)
    call gfx_fill_rect
    ret

@focus: defb 0
@i: defb 0
@x: defw 0
@text_x: defw 0
@color: defb 0
@label: dw 0
@dest_base: dw 0

