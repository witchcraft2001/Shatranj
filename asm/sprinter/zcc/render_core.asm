; Board rendering core (port.md section 3.10/S5 substep 3, plan D4/D7-ter).
; z88dk-z80asm module, linked alongside the C image (like overlay_loader_
; sprinter.asm) -- assembled together with src/sprinter/*.c by the same
; zcc invocation.
;
; The real (LOWRAM_CHESS_BOARD-driven) counterpart of S4's scene_s4.asm
; demo: the same proven arithmetic (cell_bg, piece_slot_and_page,
; MUL_CELL_TABLE, the +4/+4 piece-centring offsets, the tile_* parameter
; cell contract) recovered from the S2/S4 commits (2bf4680) rather than
; re-derived from scratch, since both were already MAME-measured
; (docs/sprinter-render-budget.md) and hardware-proven there. Differs from
; scene_s4.asm in exactly what plan D4 said it would: reads the real
; starting position from LOWRAM_CHESS_BOARD_ADDR (spectrum/lowram_map.h's
; NETCHESSZX_SPRINTER branch, ASCII-encoded -- uppercase white, lowercase
; black, '.' empty, same convention spectrum/board/board.c uses) instead
; of a hardcoded demo table, and drops S4's theme/piece-set hotkey
; switching (UI-only, not part of the real game) -- this file always
; paints piece set 0 (tools/build_sprinter_piece_tiles.py's slot_base 0).
;
; Deliberately NOT the strip-composited board-redraw strategy bench_s2.asm
; measured at 13.9ms (vs. 74ms per-cell) -- that number was only ever
; proven for a plain checkerboard with no pieces; compositing pieces into
; a RAM row buffer before blitting is new, unproven code this pass does
; not want to carry the same evidentiary burden the SP+2/ovl_ctx bugs
; already cost this session (port.md, docs/sprinter-testnotes/S5.md,
; 2026-08-10). render_board_full below is scene_s4.asm's own per-cell
; loop (scene_draw_board_and_markers, MAME-tested as part of S4's
; sign-off) minus its demo markers, reading real board data. The ~74ms
; that costs is a one-time boot paint, not a per-frame or per-move
; budget -- render_square's single-square repaint (the path any future
; move/highlight update will actually use) is well inside budget per
; docs/sprinter-render-budget.md's own conclusion (only the FULL board
; and FULL text line measured over budget, not single small ops). The
; strip strategy remains available for a later pass if a full-board
; repaint ever needs to happen mid-game (it does not yet -- nothing calls
; render_board_full more than once per boot).
;
; Draws into BOTH VRAM buffers unconditionally (matching video_init's own
; precedent), rather than tracking front/back via resolve_buffers: this is
; a boot-time paint, not a flip-aware per-frame update, and drawing both
; keeps them consistent regardless of which one RGMOD currently displays.
;
; Local labels use z88dk-z80asm's own "@name" convention (scoped to the
; last non-local label), NOT sjasmplus's ".name" -- confirmed 2026-08-10
; after ".name" locals in an earlier draft of this file produced "duplicate
; definition" errors across routines (z88dk-z80asm does not auto-scope a
; leading dot the way sjasmplus does; every gfx_core.asm/video.asm ".name"
; seen elsewhere in this port is from an sjasmplus-assembled file, not this
; one).

    MODULE render_core

    EXTERN gfx_fill_rect
    EXTERN gfx_draw_tile
    EXTERN piece_page1
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
    EXTERN BOARD_X
    EXTERN BOARD_Y
    EXTERN BOARD_COLS
    EXTERN BOARD_ROWS
    EXTERN BOARD_CELL_W
    EXTERN BOARD_CELL_H
    EXTERN LOWRAM_CHESS_BOARD_ADDR
    EXTERN text_print
    EXTERN MOVE_Y
    EXTERN STATUS_Y
    EXTERN BANNER_Y
    EXTERN MENU_Y
    EXTERN INPUT_Y
    EXTERN bench_asset_page
    EXTERN key_code
    EXTERN rtc_sample
    EXTERN rtc_valid
    EXTERN rtc_hour
    EXTERN rtc_minute

; dss.inc's own values (port.md section 3.3), hardcoded here rather than
; bridged through gen_sprinter_platform_defs.py: fixed hardware constants,
; not shared address state -- same reasoning as overlay_loader_
; sprinter.asm's local OVL_ERR_BAD_ENTRY.
VRAM_ALIAS_OPAQUE EQU $50
VRAM_ALIAS_KEY EQU $58        ; skips whole #FF bytes (dss.inc's own value;
                               ; the Sprinter logo tile below is prepared
                               ; hardware-keyed, unlike the piece tiles
                               ; above, which are pre-composited and use
                               ; VRAM_ALIAS_OPAQUE instead)

VRAM_BUF0 EQU $C000
VRAM_BUF1 EQU $C140

BOARD_X_BYTE EQU BOARD_X/2
CELL_W_BYTES EQU BOARD_CELL_W/2

    SECTION data_user

; Ported unchanged from asm/sprinter/scene_s4.asm (S4, commit 2bf4680,
; MAME-proven): both cell dimensions happen to equal 24 in their own units
; (CELL_W_BYTES=24 bytes, BOARD_CELL_H=24 pixels), so one table serves
; both the byte-column (x) and pixel-row (y) domains.
MUL_CELL_TABLE:
    defb 0,24,48,72,96,120,144,168

; Pixel-domain (not the VRAM-byte/row domain MUL_CELL_TABLE above serves)
; column offsets for the coordinate-label file letters: BOARD_CELL_W
; (48px) per column, word-sized because column 7's offset (336) does not
; fit a byte. Each entry is exactly double the matching MUL_CELL_TABLE
; entry (BOARD_CELL_W is twice CELL_W_BYTES) -- written out rather than
; computed at link time since BOARD_CELL_W only resolves to a value after
; this module links against platform_defs.asm (EXTERN, not a compile-time
; constant here), same reasoning as MUL_CELL_TABLE's own hardcoded values.
PIXEL_COL_X_TABLE:
    defw 0,48,96,144,192,240,288,336

; tools/build_sprinter_piece_tiles.py's PIECE_ORDER (wK wQ wR wB wN wP bK
; bQ bR bB bN bP): piece_index 0-5 white, 6-11 black. Matched against the
; board buffer's ASCII letters by char_to_piece_index below.
kind_table:
    defb "KQRBNP"

; Board-cursor state (S5 substep 3, first real key consumer -- see
; board_cursor_move below). Row/col of the highlighted square, 0-7 each
; (row 0 = rank 8, col 0 = file a, matching draw_square_into's own
; convention). e4 is an arbitrary but visually centred boot default;
; nothing else depends on this particular starting square.
cursor_row: defb 4
cursor_col: defb 4

    SECTION code_user

; --- board buffer decode -------------------------------------------------

; A=board cell char ('.','K'..'P','k'..'p'). On a recognised piece letter:
; CF=0, A=piece_index (0-11, PIECE_ORDER above). On '.' or anything else
; (defensive -- an unrecognised letter is treated as empty, not a crash):
; CF=1. Clobbers AF, BC, HL.
char_to_piece_index:
    cp '.'
    jr nz,@maybe_piece
    scf
    ret
@maybe_piece:
    ld c,0                  ; side offset: 0=white
    cp 'a'
    jr c,@have_case
    ld c,6                  ; black
    and $DF                 ; fold lowercase to upper for kind_table
@have_case:
    ld (@target),a
    ld hl,kind_table
    ld b,0
@scan:
    ld a,(@target)
    cp (hl)
    jr z,@found
    inc hl
    inc b
    ld a,b
    cp 6
    jr c,@scan
    scf                     ; unrecognised letter -- treat as empty
    ret
@found:
    ld a,b
    add a,c
    ret
@target: defb 0

; B=row(0-7), C=col(0-7). Returns A=that square's board-colour palette
; index: 2 (light) or 3 (dark). Row 0 = rank 8, col 0 = file a (matches
; spectrum/board/board.c's own chess_board[] indexing), so a8 is light,
; a1 dark, h1 light. Ported unchanged from scene_s4.asm's scene_cell_bg.
; Clobbers AF.
cell_bg:
    ld a,b
    add a,c
    and 1
    add a,2
    ret

; A=piece_index(0-11), B=bg_offset(0=light,1=dark). Returns A=slot,
; E=physical asset page. Always piece set 0 (slot_base 0): unlike
; scene_s4.asm's scene_piece_slot_and_page, there is no hotkey-driven set
; switch here -- PIECE_ORDER packs both colours of one set on one page, so
; every piece_index 0-11 reads piece_page1. Clobbers AF, C.
piece_slot_and_page:
    ld c,a
    ld a,(piece_page1)
    ld e,a
    ld a,c
    add a,a                 ; *2
    add a,b                 ; + bg_offset
    ret

; --- single square --------------------------------------------------------

; B=row(0-7), C=col(0-7), HL=dest_base (VRAM_BUF0/VRAM_BUF1). Repaints
; that square's background, and its piece if occupied, into the given
; VRAM buffer. No-op piece draw (background only) if piece_page1 is #FF
; (fewer than 3 asset pages published -- bench_init's own guard, buffers.
; asm). Clobbers everything.
draw_square_into:
    ld (@dest_base),hl
    ld a,b
    ld (@row),a
    ld a,c
    ld (@col),a

    call cell_bg             ; B/C still hold row/col from the caller
    ld (@bg),a

    ld a,(@col)
    ld hl,MUL_CELL_TABLE
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    add a,BOARD_X_BYTE
    ld (@x_byte),a

    ld a,(@row)
    ld hl,MUL_CELL_TABLE
    ld e,a
    add hl,de
    ld a,(hl)
    add a,BOARD_Y
    ld (@y),a

    ld a,(@x_byte)
    ld b,a
    ld a,(@y)
    ld c,a
    ld d,CELL_W_BYTES
    ld e,BOARD_CELL_H
    ld hl,(@dest_base)
    ld a,(@bg)
    call gfx_fill_rect

    ld a,(@row)
    add a,a
    add a,a
    add a,a                  ; row*8
    ld hl,LOWRAM_CHESS_BOARD_ADDR
    ld e,a
    ld d,0
    add hl,de
    ld a,(@col)
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)                 ; board cell char

    call char_to_piece_index
    ret c                      ; empty square -- background already painted
    ld (@piece_index),a

    ld a,(piece_page1)
    cp $FF
    ret z                      ; no piece pages published -- skip silently

    ld a,(@bg)
    sub 2                       ; 2/3 -> 0/1 bg_offset
    ld b,a
    ld a,(@piece_index)
    call piece_slot_and_page
    ld (tile_src_slot),a
    ld a,e
    ld (tile_src_page),a

    ld hl,(@dest_base)
    ld (tile_dest_base),hl
    ld a,(@x_byte)
    add a,4                    ; centre: (48-32)/2 = 8px = 4 bytes
    ld (tile_x_byte),a
    xor a
    ld (tile_x_hi),a
    ld a,(@y)
    add a,4                    ; centre: (24-16)/2 = 4px
    ld (tile_y),a
    ld a,16
    ld (tile_width),a
    ld (tile_stride),a
    ld (tile_rows),a
    ld a,VRAM_ALIAS_OPAQUE
    ld (tile_alias),a
    jp gfx_draw_tile
@dest_base: dw 0
@row: defb 0
@col: defb 0
@bg: defb 0
@x_byte: defb 0
@y: defb 0
@piece_index: defb 0

; L=square index (row*8+col, 0-63; row 0 = rank 8, col 0 = file a --
; matches spectrum/board/board.c's own chess_board[] indexing). Repaints
; that one square (background + piece) into both VRAM buffers.
;
; C-callable: __z88dk_fastcall's single-argument convention loads the
; whole argument into HL, but only L carries the real value here (H's
; content is not guaranteed by every call site) -- verified 2026-08-10 by
; compiling a probe call with this exact toolchain and reading the
; generated .asm (see overlay_loader_sprinter.asm's file banner for the
; fuller story of why this port no longer trusts an un-probed calling-
; convention assumption). Clobbers everything.
    PUBLIC render_square
render_square:
    PUBLIC _render_square
    defc _render_square = render_square
    ld a,l
    and $3F                    ; defensive: only 0-63 is meaningful
    ld (@index),a
    ld b,a
    srl b
    srl b
    srl b                       ; b = row (0-7)
    ld a,b
    ld (@row),a
    ld a,(@index)
    and 7                        ; col (0-7)
    ld (@col),a

    ld a,(@row)
    ld b,a
    ld a,(@col)
    ld c,a
    ld hl,VRAM_BUF0
    call draw_square_into

    ld a,(@row)
    ld b,a
    ld a,(@col)
    ld c,a
    ld hl,VRAM_BUF1
    jp draw_square_into
@index: defb 0
@row: defb 0
@col: defb 0

; No arguments: repaints every square from LOWRAM_CHESS_BOARD into both
; VRAM buffers (the initial "new game" paint -- see the file banner for
; why this is scene_s4.asm's proven per-cell loop, not the faster but
; unproven-for-pieces strip strategy). Clobbers everything.
    PUBLIC render_board_full
render_board_full:
    PUBLIC _render_board_full
    defc _render_board_full = render_board_full
    ld hl,VRAM_BUF0
    ld (@dest_base),hl
    call @paint
    ld hl,VRAM_BUF1
    ld (@dest_base),hl
    jp @paint
@paint:
    xor a
    ld (@row),a
@row_loop:
    xor a
    ld (@col),a
@col_loop:
    ld a,(@row)
    ld b,a
    ld a,(@col)
    ld c,a
    ld hl,(@dest_base)
    call draw_square_into

    ld hl,@col
    inc (hl)
    ld a,(hl)
    cp BOARD_COLS
    jp c,@col_loop
    ld hl,@row
    inc (hl)
    ld a,(hl)
    cp BOARD_ROWS
    jp c,@row_loop
    ret
@dest_base: dw 0
@row: defb 0
@col: defb 0

; --- coordinate labels -----------------------------------------------------
;
; text_print (text640.asm) has no transparent mode -- it always paints a
; solid box (bg nibble where the glyph mask is 0, fg nibble where it is 1,
; see the routine's own file banner) -- so a small box around each label,
; over whatever background shows through beside the board, is expected
; here, not a bug.
;
; The box colour uses palette index 0 (bg) again, not a fixed opaque grey:
; index 0 is not a constant colour across this call -- ovl_test_signal
; (video.asm) repaints its RGB green/red as the live P0/P1 diagnostic
; signal, so a bg=0 box painted here inherits whatever that signal last
; set (still green/red while this call runs, same as the rest of the
; screen -- see this file's own render_board_full banner and docs/
; sprinter-testnotes/S5.md). The first build of this routine used bg=0 for
; exactly that reason -- reading "still green" as a bug rather than the
; transient boot-flash it actually was, it was switched to hud_muted (13,
; a stable but visibly grey box, not blended into the background) as a
; short-lived fix. Reverted 2026-08-11 now that main.c calls
; clear_bg_signal() (video.asm) right after this routine returns: bg=0
; here paints index 0's CURRENT colour (the diagnostic tint, still
; visible during boot painting -- same as the rest of the screen), and
; once clear_bg_signal repaints index 0 to real black afterward, these
; boxes turn black along with everything else that also used index 0,
; with no separate grey box left behind. This makes render_coord_labels's
; call order relative to clear_bg_signal load-bearing, not incidental --
; must run BEFORE it (main.c already does).
COORD_COLOR EQU $01           ; bg=0 (bg, see above) << 4 | fg=1 (text) --
                               ; palette indices from
                               ; assets/sprinter/palette.json
FILE_LABEL_Y EQU MOVE_Y+2     ; vertically centre an 8px glyph in the
                               ; 12px-tall MOVE band (render_layout.json)
FILE_LABEL_X_OFFSET EQU 20    ; rough horizontal centring within a 48px
                               ; column (BOARD_CELL_W); even, per
                               ; text_print's X-parity contract
RANK_LABEL_X EQU 4            ; left margin between the screen edge and
                               ; BOARD_X (16px wide); even
RANK_LABEL_Y_OFFSET EQU 8     ; vertically centre an 8px glyph in the
                               ; 24px-tall board row (BOARD_CELL_H)

; No arguments. Paints the a-h file letters (MOVE band, above the board)
; and 8-1 rank numbers (left margin beside the board; row 0 = rank 8,
; matching board.c's own indexing -- same convention draw_square_into
; uses) into both VRAM buffers, same boot-time-paint precedent as
; render_board_full (see that routine's own file-banner rationale).
; Clobbers everything.
    PUBLIC render_coord_labels
render_coord_labels:
    PUBLIC _render_coord_labels
    defc _render_coord_labels = render_coord_labels
    ld hl,VRAM_BUF0
    call @paint
    ld hl,VRAM_BUF1
    jp @paint
@paint:
    ld (@dest_base),hl

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

    ld a,(@i)
    add a,'a'
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

    ld a,'8'
    ld hl,@i
    sub (hl)
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
@i: defb 0
@label_buf: defb 0,0

; --- status-bar clock -------------------------------------------------------
;
; A=value (0-99, only 0-59 ever occurs for rtc_minute/rtc_second and 0-23
; for rtc_hour), DE=dest (2 bytes, writes ASCII tens digit then ones
; digit -- no NUL, caller owns the byte after). Clobbers AF, BC, DE.
format2decimal:
    ld b,0
@tens_loop:
    cp 10
    jr c,@tens_done
    sub 10
    inc b
    jr @tens_loop
@tens_done:
    ld c,a
    ld a,b
    add a,'0'
    ld (de),a
    inc de
    ld a,c
    add a,'0'
    ld (de),a
    ret

; Same box-colour reasoning as COORD_COLOR above: bg=0 blends into real
; black once clear_bg_signal (video.asm) runs, so this routine's call site
; in main.c must likewise come BEFORE clear_bg_signal, not after.
STATUS_COLOR EQU $01
; STATUS_CLOCK_W=28 and the 8px right margin are S4's own proven metric
; (scene_s4.asm, commit 2bf4680, MAME-confirmed 2026-08-10) for a 5-glyph
; AFNT string in this band -- "--:--" measured at 3,3,2,3,3 packed byte-
; columns x 2px = 28px; digits use the same glyph-width class, so "HH:MM"
; fits the same box. Recovered from that commit rather than re-guessed
; (S4's file is deleted, plan D4, but still in git history).
STATUS_CLOCK_W EQU 28
STATUS_CLOCK_X EQU 640-8-STATUS_CLOCK_W
STATUS_CLOCK_Y EQU STATUS_Y+2 ; vertically centre an 8px glyph in the
                               ; 12px-tall STATUS band (render_layout.json)

; No arguments. Samples the RTC (rtc_sample, video.asm) and paints
; "HH:MM" at a fixed position on the right of the STATUS band into both
; VRAM buffers, or "--:--" if no RTC is present/valid -- same boot-time-
; paint precedent as render_board_full/render_coord_labels (a live
; per-frame clock needs the frame loop to call something, which nothing
; does yet -- this is one snapshot taken at boot, like everything else
; main() paints). Must run under EI (rtc_sample RSTs into DSS, see its own
; file banner) and before clear_bg_signal, same load-bearing order as
; render_coord_labels. Clobbers everything.
    PUBLIC render_status_clock
render_status_clock:
    PUBLIC _render_status_clock
    defc _render_status_clock = render_status_clock
    call rtc_sample
    ld a,(rtc_valid)
    or a
    jr nz,@have_time

    ld hl,@label_buf
    ld (hl),'-'
    inc hl
    ld (hl),'-'
    inc hl
    ld (hl),':'
    inc hl
    ld (hl),'-'
    inc hl
    ld (hl),'-'
    inc hl
    ld (hl),0
    jr @paint_setup

@have_time:
    ld a,(rtc_hour)
    ld de,@label_buf
    call format2decimal
    ld a,':'
    ld (@label_buf+2),a
    ld a,(rtc_minute)
    ld de,@label_buf+3
    call format2decimal
    xor a
    ld (@label_buf+5),a

@paint_setup:
    ld hl,VRAM_BUF0
    call @paint
    ld hl,VRAM_BUF1
    jp @paint
@paint:
    ld (@dest_base),hl
    ld de,@label_buf
    ld ix,STATUS_CLOCK_X
    ld c,STATUS_CLOCK_Y
    ld a,STATUS_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0
@label_buf: defb 0,0,0,0,0,0

; --- banner --------------------------------------------------------------
;
; Title text left, the real Sprinter logo (hardware-keyed tile) right-
; aligned -- matching S4's own scene_draw_banner exactly (scene_s4.asm,
; commit 2bf4680, deleted by plan D4 but MAME-confirmed 2026-08-10):
; recovered from git history rather than re-derived, same precedent
; render_board_full's own file banner already sets for the board-cell
; arithmetic. Version text is deliberately NOT shown here yet: bridging
; VERSION into this z88dk-z80asm module the way sjasmplus's sprinter_
; version.inc did for scene_s4.asm needs its own increment (CLAUDE.md
; rule 5 -- no invented version literal in the meantime), so the title is
; just the product name for now.
BANNER_COLOR EQU $01           ; bg=0, same blend-to-black convention as
                                ; COORD_COLOR/STATUS_COLOR
BANNER_TITLE_X EQU 8
BANNER_TITLE_Y EQU 4           ; vertically centre an 8px glyph in the
                                ; 16px-tall BANNER band
banner_title_msg:
    defb "SHATRANJ",0

; Sprinter logo (assets/sprinter/logo_sprinter.png via tools/prepare_
; sprinter_logo.py -> tools/build_sprinter_ui_assets.py's slot 44, S4)
; geometry: S4's own proven values (scene_s4.asm's LOGO_* EQUs), written
; out rather than computed from a bridged SCREEN_W, same reasoning as
; MUL_CELL_TABLE's hardcoded values. Hardware-keyed (VRAM_ALIAS_KEY)
; rather than opaque like the piece tiles: the source PNG has real
; transparent margins, not a precomposited background.
LOGO_SLOT EQU 44
LOGO_WIDTH_PX EQU 172
LOGO_HEIGHT_PX EQU 16
LOGO_STRIDE EQU LOGO_WIDTH_PX/2
LOGO_MARGIN_PX EQU 8
LOGO_X_BYTE EQU (640-LOGO_WIDTH_PX-LOGO_MARGIN_PX)/2

; No arguments. Paints the banner title and the right-aligned Sprinter
; logo into both VRAM buffers, same boot-time-paint precedent as every
; other render_* routine in this file. Skips the logo draw (title still
; paints) if bench_asset_page reads #FF -- no asset page published, same
; defensive guard draw_square_into already uses for piece_page1. Clobbers
; everything.
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

; --- menu bar --------------------------------------------------------------
;
; Static tab-label row (FILE/DISCONNECT/RESET/FLIP/THEME/ABOUT per render_
; layout.json's MENU band) -- one text_print call with the tabs pre-joined
; by two spaces each: S4's own proven string and position (scene_s4.asm's
; scene_draw_menu, commit 2bf4680, MAME-confirmed 2026-08-10), recovered
; from git history rather than re-derived. No focus/highlight state here
; -- that needs real key input, still on substep 3's own "not done" list
; (docs/sprinter-testnotes/S5.md) -- this is the row's static baseline.
MENU_COLOR EQU $01
MENU_LABEL_X EQU 8
MENU_LABEL_Y EQU MENU_Y+2      ; vertically centre an 8px glyph in the
                                ; 12px-tall MENU band
menu_label_msg:
    defb "FILE  DISCONNECT  RESET  FLIP  THEME  ABOUT",0

; No arguments. Paints the menu-tab row into both VRAM buffers. Clobbers
; everything.
    PUBLIC render_menu_bar
render_menu_bar:
    PUBLIC _render_menu_bar
    defc _render_menu_bar = render_menu_bar
    ld hl,VRAM_BUF0
    call @paint
    ld hl,VRAM_BUF1
    jp @paint
@paint:
    ld (@dest_base),hl
    ld de,menu_label_msg
    ld ix,MENU_LABEL_X
    ld c,MENU_LABEL_Y
    ld a,MENU_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0

; --- status-bar connection text -------------------------------------------
;
; Left side of the STATUS band, paired with render_status_clock's RTC
; readout on the right (same Y). "NO SESSION" is a literal, honest
; placeholder, not invented status text: substep 4 (plan D5) is what
; wires a real hot-seat pseudo-transport and gives this a real state to
; report -- nothing before that point has any session/connection to
; describe.
STATUS_TEXT_COLOR EQU $01
STATUS_TEXT_X EQU 8
status_text_msg:
    defb "NO SESSION",0

; No arguments. Paints the connection-status placeholder into both VRAM
; buffers. Clobbers everything.
    PUBLIC render_status_text
render_status_text:
    PUBLIC _render_status_text
    defc _render_status_text = render_status_text
    ld hl,VRAM_BUF0
    call @paint
    ld hl,VRAM_BUF1
    jp @paint
@paint:
    ld (@dest_base),hl
    ld de,status_text_msg
    ld ix,STATUS_TEXT_X
    ld c,STATUS_CLOCK_Y
    ld a,STATUS_TEXT_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0

; --- input line ------------------------------------------------------------
;
; ">" prompt at the left of the INPUT band -- S4's own proven position
; (scene_s4.asm's scene_draw_input, commit 2bf4680). Painted once at boot,
; same static baseline as the rest of this file's HUD chrome; the raw-
; key-code debug echo just right of it (render_input_key_echo, below) is
; what the frame loop actually repaints.
INPUT_COLOR EQU $01
INPUT_PROMPT_X EQU 8
INPUT_PROMPT_Y EQU INPUT_Y+2
input_prompt_msg:
    defb "> ",0

; No arguments. Paints the input-line prompt into both VRAM buffers.
; Clobbers everything.
    PUBLIC render_input_line
render_input_line:
    PUBLIC _render_input_line
    defc _render_input_line = render_input_line
    ld hl,VRAM_BUF0
    call @paint
    ld hl,VRAM_BUF1
    jp @paint
@paint:
    ld (@dest_base),hl
    ld de,input_prompt_msg
    ld ix,INPUT_PROMPT_X
    ld c,INPUT_PROMPT_Y
    ld a,INPUT_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0

; --- input: raw key-code echo (S5 substep 3, input handling's first
; slice) -----------------------------------------------------------------
;
; A=byte. DE=dest (2 bytes: high nibble hex digit then low nibble hex
; digit, uppercase, no NUL -- caller owns the byte after). Clobbers AF,
; BC, DE.
format2hex:
    ld c,a
    srl a
    srl a
    srl a
    srl a
    call @digit
    ld a,c
    and $0F
    call @digit
    ret
@digit:
    and $0F
    cp 10
    jr c,@digit_num
    add a,'A'-10
    jr @digit_store
@digit_num:
    add a,'0'
@digit_store:
    ld (de),a
    inc de
    ret

; Same box-colour reasoning as every other routine in this file: bg=0
; blends into real black once clear_bg_signal runs.
INPUT_KEY_ECHO_COLOR EQU $01
INPUT_KEY_ECHO_X EQU INPUT_PROMPT_X+24 ; just right of the "> " prompt
INPUT_KEY_ECHO_Y EQU INPUT_PROMPT_Y

; No arguments. Reads key_code (im2_s1.asm's key_poll, polled every frame
; from main()'s frame loop) and repaints it as two hex digits just right
; of the "> " prompt, into both VRAM buffers -- a debug echo proving the
; DSS keyboard-input path reaches the screen end to end, and that key_
; poll's DSS-code-to-semantic-code translation (0x81/0x82/0x83/0x84 up/
; down/left/right, 0x8A cancel, 0x08 backspace, printable ASCII) produces
; the values a real input handler will eventually consume. key_code is a
; LATCH (see key_poll's own comment): it holds the last recognised key
; until the next one arrives, not just whatever happened this exact
; frame, specifically so a human reading this echo has more than one
; ~20ms frame to read it (human tester feedback, 2026-08-11 -- the first
; version reset to "00" every frame with nothing newly queued and was
; unreadable).
;
; board_cursor_move (below, added right after this routine was confirmed
; working) is now a real consumer of the 0x81-0x84 arrow codes: it clears
; key_code itself once it recognises and acts on one (edge-triggered for
; those four codes only), so this echo will flash back to "00" the frame
; after an arrow move lands -- expected, not a regression, once there is
; something else on screen (the cursor marker moving) confirming the key
; landed. Every other code (ASCII, cancel, backspace) still has no
; consumer and keeps latching/displaying exactly as before. Clobbers
; everything.
    PUBLIC render_input_key_echo
render_input_key_echo:
    PUBLIC _render_input_key_echo
    defc _render_input_key_echo = render_input_key_echo
    ld a,(key_code)
    ld de,@buf
    call format2hex
    xor a
    ld (@buf+2),a

    ld hl,VRAM_BUF0
    call @paint
    ld hl,VRAM_BUF1
    jp @paint
@paint:
    ld (@dest_base),hl
    ld de,@buf
    ld ix,INPUT_KEY_ECHO_X
    ld c,INPUT_KEY_ECHO_Y
    ld a,INPUT_KEY_ECHO_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0
@buf: defb 0,0,0

; --- board cursor (S5 substep 3, first real key handler) -------------------
;
; The dot/ring hardware-key markers scene_s4.asm's own scene_draw_board_
; and_markers proved (slots recovered from git history, commit 2bf4680,
; MAME-confirmed 2026-08-10) are the only two S4-proven small overlay
; assets; the ring is repurposed here as the board-cursor highlight rather
; than adding a third marker asset for an increment this small. The dot
; (DOT_SLOT) is left for a later move-target/legal-move marker (substep 4
; and later, once real move legality exists) -- reusing it here would
; collide with that meaning once it exists.
CURSOR_MARKER_SLOT EQU 51      ; RING_SLOT, scene_s4.asm (commit 2bf4680)
MARKER_W EQU 8                 ; bytes (16px) -- S4's own proven marker
MARKER_ROWS EQU 8              ; tile geometry, both dot and ring
MARKER_CENTER_OFFSET EQU 8     ; centre an 8-byte/8px-tall marker in a
                                ; 24-byte/24px cell: (24-8)/2 = 8

; No arguments. Paints the cursor-highlight ring marker at (cursor_row,
; cursor_col)'s cell centre into both VRAM buffers, hardware-keyed
; (VRAM_ALIAS_KEY) the same way render_banner's logo and S4's own demo
; markers are, so it overlays the square's existing background/piece
; without erasing either. Skips silently if no asset page is published yet
; (same guard as render_banner's logo draw and draw_square_into's piece
; draw). Clobbers everything.
    PUBLIC render_cursor_marker
render_cursor_marker:
    PUBLIC _render_cursor_marker
    defc _render_cursor_marker = render_cursor_marker
    ld a,(bench_asset_page)
    cp $FF
    ret z

    ld hl,VRAM_BUF0
    call @paint
    ld hl,VRAM_BUF1
    jp @paint
@paint:
    ld (tile_dest_base),hl

    ld a,(bench_asset_page)
    ld (tile_src_page),a
    ld a,CURSOR_MARKER_SLOT
    ld (tile_src_slot),a
    ld a,MARKER_W
    ld (tile_width),a
    ld (tile_stride),a
    ld a,MARKER_ROWS
    ld (tile_rows),a
    ld a,VRAM_ALIAS_KEY
    ld (tile_alias),a

    ld a,(cursor_col)
    ld hl,MUL_CELL_TABLE
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    add a,BOARD_X_BYTE
    add a,MARKER_CENTER_OFFSET
    ld (tile_x_byte),a
    xor a
    ld (tile_x_hi),a

    ld a,(cursor_row)
    ld hl,MUL_CELL_TABLE
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    add a,BOARD_Y
    add a,MARKER_CENTER_OFFSET
    ld (tile_y),a

    jp gfx_draw_tile

; No arguments. Reads key_code (im2_s1.asm's key_poll, polled every frame
; from main()'s frame loop) and, if it is one of the four semantic arrow
; codes (0x81-0x84 up/down/left/right, same convention key_poll and ZX/
; Next's gui.h already share), moves the board cursor one square in that
; direction, clamped to the 0-7 board edges (a press against an edge is
; silently swallowed, not wrapped or bounced). Every other key_code value
; (ASCII, cancel, backspace, or nothing pending) is a no-op that leaves
; key_code untouched, since nothing else consumes it yet.
;
; Unlike key_code's own latch semantics, this routine deliberately clears
; key_code itself the instant it recognises an arrow code -- edge-
; triggered, read-and-clear, the "proper poll-and-clear semantics for a
; real input consumer" this port's own S5 testnotes flagged as still
; missing after the raw-echo probe shipped. This is the first thing in
; the port that does so; render_input_key_echo (above) and every other
; still-unconsumed code keep the plain latch behaviour.
;
; Repaints the old cell plainly (draw_square_into, both VRAM buffers) to
; erase the marker before moving, then paints the marker at the new cell
; (render_cursor_marker) -- never both cells at once, so there is exactly
; one ring on screen at any time. Clobbers everything.
    PUBLIC board_cursor_move
board_cursor_move:
    PUBLIC _board_cursor_move
    defc _board_cursor_move = board_cursor_move
    ld a,(key_code)
    cp $81
    jr z,@up
    cp $82
    jr z,@down
    cp $83
    jr z,@left
    cp $84
    jr z,@right
    ret                         ; not an arrow -- key_code left untouched

@up:
    xor a
    ld (key_code),a             ; consume: edge-triggered once recognised
    ld a,(cursor_row)
    or a
    ret z                       ; already top row -- silently swallowed
    dec a
    ld (@new_row),a
    ld a,(cursor_col)
    ld (@new_col),a
    jr @move
@down:
    xor a
    ld (key_code),a
    ld a,(cursor_row)
    cp 7
    ret z
    inc a
    ld (@new_row),a
    ld a,(cursor_col)
    ld (@new_col),a
    jr @move
@left:
    xor a
    ld (key_code),a
    ld a,(cursor_col)
    or a
    ret z
    dec a
    ld (@new_col),a
    ld a,(cursor_row)
    ld (@new_row),a
    jr @move
@right:
    xor a
    ld (key_code),a
    ld a,(cursor_col)
    cp 7
    ret z
    inc a
    ld (@new_col),a
    ld a,(cursor_row)
    ld (@new_row),a

@move:
    ld a,(cursor_row)
    ld b,a
    ld a,(cursor_col)
    ld c,a
    ld hl,VRAM_BUF0
    call draw_square_into
    ld a,(cursor_row)
    ld b,a
    ld a,(cursor_col)
    ld c,a
    ld hl,VRAM_BUF1
    call draw_square_into

    ld a,(@new_row)
    ld (cursor_row),a
    ld a,(@new_col)
    ld (cursor_col),a

    jp render_cursor_marker
@new_row: defb 0
@new_col: defb 0
