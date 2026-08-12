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
    EXTERN gfx_clear_buffer
    EXTERN piece_page1
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
    EXTERN BOARD_X
    EXTERN BOARD_Y
    EXTERN BOARD_COLS
    EXTERN BOARD_ROWS
    EXTERN BOARD_CELL_W
    EXTERN BOARD_CELL_H
    EXTERN LOWRAM_CHESS_BOARD_ADDR
    EXTERN _spectrum_gui_board_flipped
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
    EXTERN frame_wait
    EXTERN PANEL_X
    EXTERN PANEL_HEADER_Y
    EXTERN PANEL_DIVIDER_Y
    EXTERN PANEL_NOTICE_Y
    EXTERN PANEL_MOVES_Y
    EXTERN PANEL_CHAT_Y
    EXTERN LOWRAM_MOVE_LOG_ADDR

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
    PUBLIC cursor_row
    PUBLIC _cursor_row
cursor_row:
_cursor_row: defb 4
    PUBLIC cursor_col
    PUBLIC _cursor_col
cursor_col:
_cursor_col: defb 4

; Selection state (S5 substep 3c): the square whose piece has been picked
; up, or NO_SQUARE ($FF) when nothing is. Owned by the C side (main.c's
; board_select_or_move, the port of app.c's cursor_select_or_move), read
; here by render_select_marker/render_square_marked -- the same split ZX
; uses, where app.c owns selected_row/selected_col and screen.asm only
; draws what it is told. Exported under both names so C sees plain
; `extern unsigned char selected_row;` (z88dk classic prefixes C symbols
; with an underscore) while this file keeps its own unprefixed reads.
    PUBLIC selected_row
    PUBLIC _selected_row
selected_row:
_selected_row: defb $FF
    PUBLIC selected_col
    PUBLIC _selected_col
selected_col:
_selected_col: defb $FF

; gui.c (src/spectrum/ui/gui.c's spectrum_gui_draw_board/_restore_board_
; area) reads netchesszx_movement_hints, whose real home is src/spectrum/
; config/session.c -- NOT linked here: that file's netchesszx_hinted_rows
; uses SDCC's __at() to place a fixed-address array, which z88dk's classic
; (-clib=default) compiler does not support the same way ("duplicate
; definition" at link time, confirmed by trying it) -- an SDCC/IY-vs-
; classic-ABI mismatch in the same family as helpers.asm's packed-stack
; incompatibility (board_helpers_sprinter.c), just on the C side instead
; of asm. Movement hints (RULES entries 2/3) are not ported at all yet
; (rules_stub_sprinter.asm's own header), so the flag this port needs is
; simpler than session.c's real one: always 0, provided directly rather
; than pulling in a file this port cannot fully link.
    PUBLIC netchesszx_movement_hints
    PUBLIC _netchesszx_movement_hints
netchesszx_movement_hints:
_netchesszx_movement_hints: defb 0

    SECTION code_user

; No arguments. Pixel-clears both VRAM buffers to colour 0 (black).
; Boot-only, called once from main() before any other painting.
;
; S5-finish plan D11 fix (2026-08-11, human tester's first P15 MAME run:
; "экран не чистится при запуске"): this port never actually cleared VRAM
; PIXEL content anywhere -- `clear_bg_signal` (video.asm) only rewrites
; palette index 0's colour, relying on whatever DSS/BIOS happened to
; leave in VRAM already being that index. That was invisible while
; PORT_RGMOD never toggled (the one buffer ever displayed happened to be
; clean); the moment a real flip can show the OTHER buffer, its untouched
; boot garbage is exactly what showed up on screen. Must run before
; `resolve_buffers()`/`flip_ring_reset()` so the pending `flip_mark_dirty_
; all` calls `gfx_clear_buffer` makes are reset away cleanly, not left
; pending for the boot painters to (harmlessly, but wastefully) rediscover.
; Clobbers everything.
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
;
; S5-finish plan, real FLIP: row/col here are always MODEL coordinates
; (board.c's own indexing, row 0 = rank 8) -- every caller (render_square,
; render_board_full, board_cursor_move) passes cursor_row/selected_row/a
; loop index straight from that convention, and the content lookup below
; (LOWRAM_CHESS_BOARD_ADDR[row*8+col]) MUST stay in model space or it reads
; the wrong square entirely, flipped or not. What changes on screen when
; flipped is only WHERE a given model square is painted -- so @disp_row/
; @disp_col (below, read once via _spectrum_gui_board_flipped, gui.c's own
; portable flip flag, already the single source of truth main.c's menu
; FLIP action sets) feed the MUL_CELL_TABLE position lookups only; cell_bg
; and the content lookup further down keep reading @row/@col unchanged --
; every existing caller of this routine or render_square/render_board_full
; needed zero changes to render correctly flipped, since none of them ever
; had a separate "display coordinate" concept to begin with. cell_bg does
; not need a flipped variant either: (7-row)+(7-col) has the same parity as
; row+col, so the checker pattern is identical whichever pair feeds it.
draw_square_into:
    ld (@dest_base),hl
    ld a,b
    ld (@row),a
    ld a,c
    ld (@col),a

    call cell_bg             ; B/C still hold row/col from the caller
    ld (@bg),a

    ld a,(_spectrum_gui_board_flipped)
    or a
    jr z,@disp_same
    ld a,7
    ld hl,@row
    sub (hl)
    ld (@disp_row),a
    ld a,7
    ld hl,@col
    sub (hl)
    ld (@disp_col),a
    jr @disp_done
@disp_same:
    ld a,(@row)
    ld (@disp_row),a
    ld a,(@col)
    ld (@disp_col),a
@disp_done:

    ld a,(@disp_col)
    ld hl,MUL_CELL_TABLE
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    add a,BOARD_X_BYTE
    ld (@x_byte),a

    ld a,(@disp_row)
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
@disp_row: defb 0
@disp_col: defb 0
@bg: defb 0
@x_byte: defb 0
@y: defb 0
@piece_index: defb 0

; L=square index (row*8+col, 0-63; row 0 = rank 8, col 0 = file a --
; matches spectrum/board/board.c's own chess_board[] indexing). Repaints
; that one square (background + piece).
;
; S5-finish plan D11 (buffer flip), checkpoint F0: paints (back_base)
; only, unlike render_board_full's boot-time two-pass paint (this file's
; own banner comment) -- this is the first migrated routine, proving the
; flip+dirty-rect-sync mechanism (im2_s1.asm's frame_wait/im2_frame_isr,
; buffers.asm's flip_log_rect/flip_sync) on the board's most frequently
; and visibly repainted content (every cursor move repaints two squares
; through this, via render_square_marked below). F1 (2026-08-12) then
; migrated every other LIVE/event-driven routine in this file the same
; way (game_timer_paint, render_input_key_echo, the clock/turn-label/
; status/notice/input-text routines below); the move-list painter,
; render_board_full (menu RESET needs a live full-board repaint) and the
; menu bar itself (open/close/focus needed a visible signal, human tester
; feedback -- render_menu_tabs's own comment) joined them (S5-finish plan
; D12) -- but not every routine: boot-only, paint-
; once-forever content (render_coord_labels, render_banner, render_
; status_clock, render_status_text, render_input_line, _spectrum_info_
; show_game) stays two-pass on purpose, since nothing ever repaints it
; again after boot for a flip to matter, and it needs to be correct in
; BOTH buffers before the first flip ever happens. draw_square_into's own
; gfx_fill_rect/gfx_draw_tile calls now log every rect they paint; the now-hidden
; front buffer catches up via flip_sync once the next flip is confirmed
; -- no caller-visible change, the two-pass discipline just moved from
; "paint twice, once per buffer" to "paint once, sync once" for every
; live routine.
;
; C-callable: __z88dk_fastcall's single-argument convention loads the
; whole argument into HL, but only L carries the real value here (H's
; content is not guaranteed by every call site) -- verified 2026-08-10 by
; compiling a probe call with this exact toolchain and reading the
; generated .asm (see overlay_loader_sprinter.asm's file banner for the
; fuller story of why this port no longer trusts an un-probed calling-
; convention assumption). Clobbers everything.
;
; 2026-08-12 postscript: this routine was briefly, temporarily reverted
; to a two-pass (front_base + back_base) diagnostic probe while chasing
; a "cursor/selection square renders solid black" report (S5-finish
; testnotes, P15). The probe conclusively ruled OUT this buffering
; mechanism -- painting directly into the displayed buffer was STILL
; black -- so the real defect was elsewhere (a stale build/sprinter/
; ui_assets.bin predating the frame_cursor/frame_select asset entries,
; fixed by regenerating it; see render_core.asm's git history/S5.md for
; the full story). This is back to the single-pass F0 shape.
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
    ld hl,(back_base)
    jp draw_square_into
@index: defb 0
@row: defb 0
@col: defb 0

; No arguments: repaints every square from LOWRAM_CHESS_BOARD (the initial
; "new game" paint, and -- S5-finish plan D12 -- a menu RESET's full-board
; repaint -- see the file banner for why this is scene_s4.asm's proven
; per-cell loop, not the faster but unproven-for-pieces strip strategy).
;
; Single-pass (back_base) as of D12: the boot call happens before the
; first flip (same reasoning render_cursor_marker's own boot call already
; relies on, main.c's own comment on that), and RESET is a live menu
; action, not a second boot -- painting 64 squares logs far more than the
; 16-entry dirty-rect ring holds, so this always takes the already-MAME-
; proven dirty_all/flip_sync path (checkpoint F0), never the per-rect one.
; Clobbers everything.
    PUBLIC render_board_full
render_board_full:
    PUBLIC _render_board_full
    defc _render_board_full = render_board_full
    ld hl,(back_base)
    ld (@dest_base),hl
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
FILE_LABEL_CLEAR_W_BYTES EQU 192 ; BOARD_COLS*BOARD_CELL_W/2 = 8*48/2,
                               ; hardcoded rather than computed from the
                               ; EXTERN constants for the same reason
                               ; PIXEL_COL_X_TABLE's own comment gives:
                               ; BOARD_CELL_W only resolves at link time

; No arguments. Paints the a-h file letters (MOVE band, above the board)
; and 8-1 rank numbers (left margin beside the board; row 0 = rank 8,
; matching board.c's own indexing -- same convention draw_square_into
; uses).
;
; S5-finish plan, real FLIP: single-pass (back_base) and flip-aware, not
; boot-only two-pass any more -- FLIP is the one live caller that needs
; this to repaint (main.c's menu_flip_board). Read _spectrum_gui_board_
; flipped once into @flip: unflipped, screen column/row i shows 'a'+i /
; '8'-i same as always; flipped, it shows 'h'-i / '1'+i (matches app.c's
; own cursor_move -- the only other place in this codebase that already
; has flip-direction logic to check against). Position (PIXEL_COL_X_TABLE/
; MUL_CELL_TABLE indexed by i) never changes -- i IS the screen column/row,
; flip only changes which letter/digit is drawn there. The file-label loop
; clears its whole strip first: text_print's box is exactly as wide as
; each glyph (proportional font), 'f' is narrower (4px) than every other
; file letter (6px, font.bin's own width table) -- flipping swaps which
; column shows 'f', and repainting over a wider previous glyph without a
; clear would leave a stale sliver un-erased. Rank digits 1-8 are all the
; same width, so that loop has no equivalent risk. Clobbers everything.
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
; D12 fix #3 (2026-08-12): replaces both earlier visual signals (fix #1's
; whole-row invert, fix #2's notice-line tab-name echo) with a single
; highlight rectangle around the focused tab -- matching how the real
; ZX/Next menu bar actually works (asm/spectrum/screen.asm's draw_menu/
; draw_menu_cursor: every tab keeps its own fixed column, only the focused
; one gets a small box toggled around it -- the row itself does not
; invert) and how an earlier, abandoned Sprinter port attempt did the same
; idea (the `sprinter-port` branch's src/sprinter/render.c,
; spectrum_render_menu: per-tab text plus an outline() box around the
; focused one). Neither precedent is ported byte-for-byte: ZX's box comes
; from a precomputed pixel-mask table baked into its font asset, and the
; old attempt measured each label's width at runtime via a text_width_n
; this port's text640.asm has no equivalent of (its own pre-scan is
; internal to the paint loop, not a standalone query) -- so this uses a
; fixed pitch instead, sized against extern/sprinter-libs/afnt640/
; font.bin's own packed-column-width table (byte-columns * 2 = px):
; FILE=20, DISCC=26, RESET=30, FLIP=20, THEME=32, ABOUT=30px, all
; comfortably inside the 40px box below (32px widest label + 4px pad each
; side).
;
; DISCONNECT -> DISCC: the real ZX/Next tab (NETCHESSZX_MENU_DISCC_COL,
; tab_label_discc) and the old Sprinter attempt both use the 5-letter
; form; this port's own gui.c already names the action SPECTRUM_GUI_KEY_
; MENU_DISCC, so spelling it out in full in the joined string was the odd
; one out, not the abbreviation. DISCONNECT's own width (56px) would have
; forced a pitch wide enough to overflow past PANEL_X=408 before ABOUT.
;
; MENU_TAB_PITCH is also kept small enough that every table entry below
; (MENU_LABEL_X + up to 5*MENU_TAB_PITCH) stays under 256 -- menu_tab_x_
; table is a byte table (SCREEN_W=640 needs a word to hold an arbitrary X,
; but every position actually used here does not).
MENU_COLOR EQU $01             ; bg=0 (screen bg), fg=1 (text) -- unfocused
MENU_COLOR_FOCUS EQU $10       ; bg=1 (highlight fill), fg=0 -- focused text
MENU_TAB_COUNT EQU 6
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
    defb MENU_LABEL_X+0*MENU_TAB_PITCH
    defb MENU_LABEL_X+1*MENU_TAB_PITCH
    defb MENU_LABEL_X+2*MENU_TAB_PITCH
    defb MENU_LABEL_X+3*MENU_TAB_PITCH
    defb MENU_LABEL_X+4*MENU_TAB_PITCH
    defb MENU_LABEL_X+5*MENU_TAB_PITCH

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
    defb MENU_LABEL_X+0*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-20)/4)*2 ; FILE
    defb MENU_LABEL_X+1*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-26)/4)*2 ; DISCC
    defb MENU_LABEL_X+2*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-30)/4)*2 ; RESET
    defb MENU_LABEL_X+3*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-20)/4)*2 ; FLIP
    defb MENU_LABEL_X+4*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-32)/4)*2 ; THEME
    defb MENU_LABEL_X+5*MENU_TAB_PITCH-MENU_BOX_X_PAD+((MENU_BOX_W-30)/4)*2 ; ABOUT

menu_tab_names:
    defw @file_msg, @discc_msg, @rest_msg, @flip_msg, @theme_msg, @about_msg
@file_msg: defb "FILE",0
@discc_msg: defb "DISCC",0
@rest_msg: defb "RESET",0
@flip_msg: defb "FLIP",0
@theme_msg: defb "THEME",0
@about_msg: defb "ABOUT",0

; A=focus index in (0-5 highlighted; MENU_TAB_COUNT or higher = none, i.e.
; closed). Clears the tab row's own background, then paints all six
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
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    ld (@x),a

    ld a,(@i)
    ld hl,menu_label_x_table
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    ld (@text_x),a

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

    ld de,(@label)
    ld a,(@text_x)
    ld ixl,a
    ld ixh,0
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
    ld a,(@x)
    sub MENU_BOX_X_PAD
    srl a                        ; px -> byte offset
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
@x: defb 0
@text_x: defb 0
@color: defb 0
@label: dw 0
@dest_base: dw 0

; No arguments. Paints the closed (no tab focused) menu-tab row.
;
; S5-finish plan D12 fix: single-pass (back_base), not boot-only two-pass
; any more -- reachable live every time the menu closes (TAB, or ENTER/
; SPACE on a focused tab), same reasoning render_board_full picked up for
; RESET in the same pass. Clobbers everything.
    PUBLIC render_menu_bar
render_menu_bar:
    PUBLIC _render_menu_bar
    defc _render_menu_bar = render_menu_bar
    ld a,MENU_TAB_COUNT           ; out-of-range index -> no tab highlighted
    jp render_menu_tabs

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
; consumer and keeps latching/displaying exactly as before.
;
; S5-finish plan D11 (buffer flip): main.c's frame loop calls this every
; single frame, unconditionally -- the one call site in this port that
; painted (via text_print) on every frame even before the flip existed.
; Now that text_print/gfx_fill_rect log every paint into buffers.asm's
; dirty-rect ring (needed for the routines that DO paint conditionally),
; an unconditional every-frame repaint here would keep the ring non-empty
; forever, forcing frame_wait to request -- and get -- a flip every
; single frame, and once the ring's 16 slots fill (within seconds) every
; one of those flips syncs the WHOLE buffer. Confirmed on real hardware
; (human tester, 2026-08-11, first P15 MAME run): constant screen
; switching, the never-actually-pixel-cleared second buffer's garbage
; exposed, breakdown after sustained load. Fixed by only repainting when
; key_code has actually changed since the last echo -- @last_echoed is a
; local latch of what is currently ON SCREEN (distinct from key_code
; itself, which board_cursor_move/board_select_or_move consume/clear
; elsewhere); #FF is never a real key_code value (see key_poll's own
; comment for the full code set), so it forces the very first call to
; always paint.
;
; F1 (2026-08-12): migrated the paint itself to single-pass (back_base
; only), same as render_square/game_timer_paint -- the storm gate above
; only stopped the ring from overflowing every frame, it did not stop
; this call site's own two-pass write from tearing on whichever buffer
; happened to be live at the moment a key changed. Clobbers everything.
    PUBLIC render_input_key_echo
render_input_key_echo:
    PUBLIC _render_input_key_echo
    defc _render_input_key_echo = render_input_key_echo
    ld a,(key_code)
    ld hl,@last_echoed
    cp (hl)
    ret z                       ; unchanged since the last paint -- nothing
                                 ; to redraw, and nothing to log
    ld (hl),a

    ld de,@buf
    call format2hex
    xor a
    ld (@buf+2),a

    ld de,@buf
    ld ix,INPUT_KEY_ECHO_X
    ld c,INPUT_KEY_ECHO_Y
    ld a,INPUT_KEY_ECHO_COLOR
    ld hl,(back_base)
    jp text_print
@buf: defb 0,0,0
@last_echoed: defb $FF

; --- board cursor and selection (S5 substep 3/3c) --------------------------
;
; Both marks are whole-cell keyed frames, not point markers, because that
; is what ZX and Next actually draw: asm/spectrum/screen.asm's
; draw_square_mark paints a rectangle around the 2x2-character square and
; adds a SECOND, inner rectangle when that square is the selected one (its
; mark_mode branch); Next carries the same pair as its marker sprite's
; NEXT_MARKER_FLAG_MARK / _SELECTED. tools/make_sprinter_markers.py
; generates the two 48x24 frames to match (single hairline = cursor,
; double = selection), tools/build_sprinter_ui_assets.py packs them at
; these fixed slots, and tests/tools/test_sprinter_ui_assets.py pins both
; the slots and the cell-sized geometry.
;
; The earlier version of this file borrowed S4's 16x8 "ring" point marker
; (RING_SLOT) as a stand-in cursor. That was this port's own invention,
; not the ZX behaviour, and it also squatted on an asset whose declared
; meaning is the last-move marker; the frames replace it and give dot/ring
; back their intended roles (hint / last move).
CURSOR_FRAME_SLOT EQU 52       ; CURSOR_SLOT, build_sprinter_ui_assets.py
SELECT_FRAME_SLOT EQU 55       ; SELECT_SLOT, same fixed slot contract
FRAME_W EQU 24                 ; bytes -- one whole cell (CELL_W_BYTES)
FRAME_ROWS EQU 24              ; rows  -- one whole cell (BOARD_CELL_H)

NO_SQUARE EQU $FF              ; selected_row's "nothing picked up" value,
                                ; mirroring app.c's own NO_SQUARE

; A = asset slot of the frame to paint, B = row, C = col. Paints that
; whole-cell frame over the square, hardware-keyed (VRAM_ALIAS_KEY)
; exactly like render_banner's logo and the S4 markers, so the square's
; existing background and piece show through the frame's transparent
; interior. Skips silently if no asset page is published yet (same guard
; as every other keyed draw here).
;
; S5-finish plan D11, checkpoint F0: paints (back_base) only -- see
; render_square's own comment above for why (including the 2026-08-12
; diagnostic-probe postscript: this routine was briefly reverted to a
; two-pass front_base+back_base probe while chasing the "solid black
; cursor/selection square" report, which conclusively ruled out this
; buffering mechanism -- the real cause was a stale build/sprinter/
; ui_assets.bin predating the frame_cursor/frame_select asset entries).
;
; S5-finish plan, real FLIP: B/C are MODEL row/col (render_cursor_marker/
; render_select_marker pass cursor_row/col and selected_row/col straight
; through, same convention as everywhere else) -- transformed into a
; DISPLAY row/col for the MUL_CELL_TABLE position lookups below, same
; flip read and same transform as draw_square_into's own (this routine has
; no content to look up, so unlike that one there is no second, unflipped
; use of row/col to keep separate). Without this, the cursor/selection
; frame would stay painted at the square's UNFLIPPED screen position while
; draw_square_into's own background/piece moved to the flipped one --
; caught before this ever reached MAME by re-checking every other
; MUL_CELL_TABLE call site in this file after fixing draw_square_into, not
; by a human report. Clobbers everything.
draw_frame_at:
    ld (@slot),a
    ld a,(bench_asset_page)
    cp $FF
    ret z
    ld a,b
    ld (@row),a
    ld a,c
    ld (@col),a

    ld hl,(back_base)
    ld (tile_dest_base),hl

    ld a,(bench_asset_page)
    ld (tile_src_page),a
    ld a,(@slot)
    ld (tile_src_slot),a
    ld a,FRAME_W
    ld (tile_width),a
    ld (tile_stride),a
    ld a,FRAME_ROWS
    ld (tile_rows),a
    ld a,VRAM_ALIAS_KEY
    ld (tile_alias),a

    ld a,(_spectrum_gui_board_flipped)
    or a
    jr z,@disp_same
    ld a,7
    ld hl,@row
    sub (hl)
    ld (@disp_row),a
    ld a,7
    ld hl,@col
    sub (hl)
    ld (@disp_col),a
    jr @disp_done
@disp_same:
    ld a,(@row)
    ld (@disp_row),a
    ld a,(@col)
    ld (@disp_col),a
@disp_done:

    ld a,(@disp_col)
    ld hl,MUL_CELL_TABLE
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    add a,BOARD_X_BYTE
    ld (tile_x_byte),a
    xor a
    ld (tile_x_hi),a

    ld a,(@disp_row)
    ld hl,MUL_CELL_TABLE
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    add a,BOARD_Y
    ld (tile_y),a

    jp gfx_draw_tile
@slot: defb 0
@row: defb 0
@col: defb 0
@disp_row: defb 0
@disp_col: defb 0

; No arguments. Paints the cursor frame over (cursor_row, cursor_col).
; Clobbers everything.
    PUBLIC render_cursor_marker
render_cursor_marker:
    PUBLIC _render_cursor_marker
    defc _render_cursor_marker = render_cursor_marker
    ld a,(cursor_row)
    ld b,a
    ld a,(cursor_col)
    ld c,a
    ld a,CURSOR_FRAME_SLOT
    jp draw_frame_at

; No arguments. Paints the selection frame over (selected_row,
; selected_col), or does nothing when no piece is picked up. Clobbers
; everything.
    PUBLIC render_select_marker
render_select_marker:
    PUBLIC _render_select_marker
    defc _render_select_marker = render_select_marker
    ld a,(selected_row)
    cp NO_SQUARE
    ret z
    ld b,a
    ld a,(selected_col)
    ld c,a
    ld a,SELECT_FRAME_SLOT
    jp draw_frame_at

; L = square index (row*8+col, 0-63) -- __z88dk_fastcall, same convention
; and same "only L is guaranteed" caveat as render_square above. Repaints
; that square from the board buffer and then puts back whichever marks
; belong on it: the selection frame first, the cursor frame on top, so a
; square that is both reads as ZX's double-frame-plus-cursor does.
;
; This is the routine every caller that changes a square should use --
; render_square alone silently erases the cursor whenever it happens to
; repaint the square the cursor is standing on, which is exactly the kind
; of "disappears only in one specific position" bug that survives testing.
; Clobbers everything.
    PUBLIC render_square_marked
render_square_marked:
    PUBLIC _render_square_marked
    defc _render_square_marked = render_square_marked
    ld a,l
    and $3F
    ld (@index),a
    call render_square

    ld a,(selected_row)
    cp NO_SQUARE
    jr z,@no_select
    ld b,a
    ld a,(selected_col)
    ld c,a
    call @index_of
    ld hl,@index
    cp (hl)
    jr nz,@no_select
    call render_select_marker
@no_select:
    ld a,(cursor_row)
    ld b,a
    ld a,(cursor_col)
    ld c,a
    call @index_of
    ld hl,@index
    cp (hl)
    ret nz
    jp render_cursor_marker
; B=row, C=col -> A = row*8+col. Clobbers AF only.
@index_of:
    ld a,b
    add a,a
    add a,a
    add a,a
    add a,c
    ret
@index: defb 0

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
; Repaints exactly the two squares that change -- the one being left and
; the one being entered -- through render_square_marked, so the cursor
; frame follows the cursor while the selection frame stays on the picked-up
; piece's square.
;
; S5-finish plan, real FLIP: which physical row/col delta a given arrow
; key produces now depends on _spectrum_gui_board_flipped, so that the
; highlighted square keeps moving the way the key physically points on
; screen instead of always toward the same model edge -- matching app.c's
; own cursor_move (src/spectrum/app/app.c), the only other place in this
; codebase with flip-aware cursor-direction logic already proven against a
; human tester on ZX/Next, checked against rather than reinvented. Each of
; @up/@down/@left/@right now only decides, via the flip flag, which of the
; four physical bodies below (@row_dec/@row_inc/@col_dec/@col_inc -- the
; exact unchanged bodies this routine always had) actually runs; unflipped,
; @up->@row_dec/@down->@row_inc/@left->@col_dec/@right->@col_inc is the
; same wiring as before this change. Clobbers everything.
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
    ld a,(_spectrum_gui_board_flipped)
    or a
    jr z,@row_dec
    jr @row_inc
@down:
    xor a
    ld (key_code),a
    ld a,(_spectrum_gui_board_flipped)
    or a
    jr z,@row_inc
    jr @row_dec
@left:
    xor a
    ld (key_code),a
    ld a,(_spectrum_gui_board_flipped)
    or a
    jr z,@col_dec
    jr @col_inc
@right:
    xor a
    ld (key_code),a
    ld a,(_spectrum_gui_board_flipped)
    or a
    jr z,@col_inc
    jr @col_dec

@row_dec:
    ld a,(cursor_row)
    or a
    ret z                       ; already top row -- silently swallowed
    dec a
    ld (@new_row),a
    ld a,(cursor_col)
    ld (@new_col),a
    jr @move
@row_inc:
    ld a,(cursor_row)
    cp 7
    ret z
    inc a
    ld (@new_row),a
    ld a,(cursor_col)
    ld (@new_col),a
    jr @move
@col_dec:
    ld a,(cursor_col)
    or a
    ret z
    dec a
    ld (@new_col),a
    ld a,(cursor_row)
    ld (@new_row),a
    jr @move
@col_inc:
    ld a,(cursor_col)
    cp 7
    ret z
    inc a
    ld (@new_col),a
    ld a,(cursor_row)
    ld (@new_row),a

@move:
    ; Leave the old square: repaint it and put back whatever else belongs
    ; there. render_square_marked, not a bare repaint -- the old square may
    ; be the selected one, whose frame must survive the cursor moving off
    ; it (that is the whole point of having two different frames).
    ld a,(cursor_row)
    add a,a
    add a,a
    add a,a
    ld l,a
    ld a,(cursor_col)
    add a,l
    ld l,a
    ld a,(@new_row)
    ld (cursor_row),a
    ld a,(@new_col)
    ld (cursor_col),a
    call render_square_marked   ; cursor already moved -> old square loses it

    ld a,(cursor_row)
    add a,a
    add a,a
    add a,a
    ld l,a
    ld a,(cursor_col)
    add a,l
    ld l,a
    jp render_square_marked
@new_row: defb 0
@new_col: defb 0

; --- gui.c integration surface (S5-finish, plan D8/D9) --------------------
;
; S5's finish pass links src/spectrum/ui/gui.c into the resident unmodified
; (D8: gui.c holds the move-list/chat buffers, clocks, timers, notices,
; menu-focus state and the FLIP flag, and touches no screen memory itself
; -- it only calls the spectrum_render_*/spectrum_gui_*-adjacent entry
; points below, the same split app.c/screen.asm already use on ZX/Next).
; Everything gui.c's compiled object references must resolve for the link
; to succeed at all, whether or not main.c calls into gui.c yet -- this
; section is therefore written in full even where the CONTENT a routine
; paints is honestly still a stub (documented per routine) because the
; feature it belongs to (GUI_LOG's move list/chat, INPUT_EDIT's line
; editor) has not been ported yet.
;
; Two things every routine here shares:
;   - gui.c passes board/coordinate/text data through pointers built on its
;     own stack (src/spectrum/ui/gui.c's own square_spec/coord_mark_spec
;     locals, or a plain ASCIIZ string) -- __z88dk_fastcall's single-
;     pointer-argument convention loads the whole address into HL, the
;     ordinary case (not the accident-prone single-BYTE-argument one this
;     port's SP+2/ovl_ctx/L-only lessons were about, confirmed by a real
;     compiled-probe read: `call _asm_returns_val` / `ld h,0` immediately
;     after shows a uint8_t RETURN value also lands in L only, H left to
;     the caller -- the same convention render_square's own comment
;     already established for byte ARGUMENTS, now confirmed for byte
;     RETURNS too).
;   - Every square-touching routine below goes through render_square_marked,
;     never a bare render_square, for the same reason board_cursor_move
;     already does: a plain repaint would silently erase the cursor/
;     selection frame if it happens to land on that square.

; --- board -----------------------------------------------------------------

; HL=board pointer (__z88dk_fastcall) -- ALWAYS ignored: gui.c only ever
; passes gui_live_board (src/spectrum/ui/gui.c's own #define), which IS
; LOWRAM_CHESS_BOARD_ADDR, the exact buffer render_board_full already
; reads. Full repaint, then the cursor/selection frames are reapplied --
; render_board_full's own per-cell loop does not know about them, the same
; "frame survives an unrelated repaint" contract render_square_marked
; already guarantees for one square. Clobbers everything.
    PUBLIC _spectrum_render_board
_spectrum_render_board:
    call render_board_full
    call render_select_marker
    jp render_cursor_marker

; No separate "board area" concept yet (ZX draws the board without its
; coordinate frame here, used while movement hints are up -- hints are not
; ported, see rules_stub_sprinter.asm's own header). Same behaviour as
; spectrum_render_board above.
    PUBLIC _spectrum_render_board_area
_spectrum_render_board_area:
    call render_board_full
    call render_select_marker
    jp render_cursor_marker

; No arguments. Thin C-name wrapper: gui.c calls spectrum_render_board_
; coords, this file's own boot-time routine is render_coord_labels -- same
; routine, two names for two callers (main()'s boot paint, gui.c's FLIP
; repaint).
    PUBLIC _spectrum_render_board_coords
_spectrum_render_board_coords:
    jp render_coord_labels

; HL=spec (__z88dk_fastcall): spec[0]=row, spec[1]=col, spec[2]=0/1
; (active). ZX highlights the a-h/1-8 coordinate label of the cursor's
; current square; Sprinter's coordinate labels have no "highlighted"
; visual state of their own yet -- the frame markers already show where
; the cursor/selection are, which is why this was not an early priority --
; deliberately a no-op rather than a half-finished highlight. Revisit if a
; human tester finds the coordinate row genuinely hard to read without it.
    PUBLIC _spectrum_render_board_coord_mark
_spectrum_render_board_coord_mark:
    ret

; HL=spec (__z88dk_fastcall): spec[0]=row(display coord), spec[1]=col.
; FLIP is not wired yet (Step 3 of the S5-finish plan), so display coord
; == model coord for now; this reads spec[0]/[1] directly as row/col,
; matching render_square/render_square_marked's own convention, and
; repaints frame-safely. Shared body for every gui.c square-repaint call
; below, since none of them (flash/hint/gui-cursor-model) are ported yet
; -- see each PUBLIC entry's own comment for exactly what it is skipping.
gui_square_from_spec:
    ld a,(hl)
    add a,a
    add a,a
    add a,a                    ; row*8
    inc hl
    add a,(hl)
    ld l,a
    jp render_square_marked

    PUBLIC _spectrum_render_square
_spectrum_render_square:
    jp gui_square_from_spec

; Flash-on-move attribute effect (ZX's ATTR_FLASH, spectrum_gui_prepare_
; move's flash_square) is not ported -- no equivalent visual exists yet on
; Sprinter's 4bpp linear framebuffer, and this port's own board_select_or_
; move (S5 substep 3c) does not call spectrum_gui_prepare_move at all.
; Repaints the square plainly (frame-safe) instead of flashing it.
    PUBLIC _spectrum_render_square_attr
_spectrum_render_square_attr:
    jp gui_square_from_spec

; Legal-move hints (RULES entries 2/3) are not ported -- see rules_stub_
; sprinter.asm's own header for why. Same plain frame-safe repaint as
; spectrum_render_square.
    PUBLIC _spectrum_render_square_with_hint
_spectrum_render_square_with_hint:
    jp gui_square_from_spec

; gui.c's OWN cursor/selection model (spectrum_gui_mark_cursor et al,
; display_coord-based) is not what drives this port's board cursor --
; main.c's board_cursor_move/board_select_or_move (S5 substep 3/3c) do
; that directly against cursor_row/col and selected_row/col, bypassing
; gui.c's board-cursor path entirely (this port already had a MAME-proven
; cursor implementation before gui.c was linked at all; D8's own scope is
; gui.c's clocks/timers/notices/menu/panel state, not its board-cursor
; logic). These two routines exist only so gui.c's compiled object
; resolves at link time; unreachable from this port's own wiring today.
; If a future pass switches the cursor over to gui.c's model instead,
; this is where that would actually start drawing something different.
    PUBLIC _spectrum_render_square_mark
_spectrum_render_square_mark:
    jp gui_square_from_spec

    PUBLIC _spectrum_render_square_mark_with_hint
_spectrum_render_square_mark_with_hint:
    jp gui_square_from_spec

; --- clocks and timers (S5-finish step 1, gui.c-driven) ---------------------
;
; gui.c owns the wall clock / GAME timer / TURN timer state and formatting
; (put_hhmm/put_move_timer/build_game_timer_line, src/spectrum/ui/gui.c);
; these routines only paint what gui.c already decided to draw. The one-
; shot render_status_clock above (boot-time RTC snapshot) predates this
; integration and is superseded once main.c's frame loop starts calling
; spectrum_gui_tick()/spectrum_gui_set_clock() (S5-finish step 1 wiring) --
; left in place rather than deleted since nothing calls it yet in this
; pass, and removing a still-referenced boot routine is a needless risk
; for a size-measurement-only step.
CLOCK_ERROR_COLOR EQU $0B      ; bg=0,fg=11(hud_error) -- palette.json
CLOCK_SUCCESS_COLOR EQU $0C    ; bg=0,fg=12(hud_success)

; HL=text (__z88dk_fastcall, ASCIIZ, resident RAM -- gui.c's own stack
; buffer, never WIN0/WIN3, same contract text640.asm's own file banner
; documents). Paints the wall-clock string at the same fixed position
; render_status_clock's boot snapshot already used.
;
; F1 (2026-08-12, S5-finish plan D11): single-pass (back_base only), same
; discipline as game_timer_paint -- gui.c's own render_clock_only already
; gates this to "text actually changed" (its own strcmp against last_
; clock_line), reached at most once per spectrum_gui_tick() ~1Hz cadence,
; so no flip-storm risk. Clobbers everything.
    PUBLIC _spectrum_render_clock
_spectrum_render_clock:
    ex de,hl
    ld ix,STATUS_CLOCK_X
    ld c,STATUS_CLOCK_Y
    ld a,STATUS_COLOR
    ld hl,(back_base)
    jp text_print

GAME_TIMER_X EQU PANEL_X
GAME_TIMER_Y EQU MOVE_Y+2
GAME_TIMER_X_BYTE EQU PANEL_X/2
GAME_TIMER_TEXT_LEN EQU 23         ; NETCHESSZX_GAME_TIMER_TEXT_SIZE, layout.h
GAME_TIMER_LINE_W_BYTES EQU 92     ; erase width covering the whole line
                                    ; (written out, not GAME_TIMER_TEXT_LEN*4
                                    ; -- z80asm EQU multiplication unproven in
                                    ; this codebase, every existing EQU
                                    ; expression here only ever divides, e.g.
                                    ; LOGO_STRIDE)
GAME_TIMER_CACHE_SIZE EQU 24       ; GAME_TIMER_TEXT_LEN+1 (NUL), mirrors
                                    ; gui.c's own game_timer_line[24]

; text640.asm's text_print is PROPORTIONAL: .prescan sums each character's
; own font.bin packed-column width, not a fixed cell -- so a per-character
; delta redraw cannot reposition just the changed glyph at a fixed
; index*N pixel offset the way an earlier draft of this routine did (index*4
; bytes erase / index*8px text_print IX, as if the font were monospace).
; That only agreed with the real proportional layout at index 0; by the time
; TURN's seconds digits (index 20-21) came up, the drift was large enough to
; land in blank space clear of "TURN:00m00s" instead of on top of it --
; confirmed a real bug by a human MAME screenshot 2026-08-11 (docs/sprinter-
; testnotes/S5.md P14), not a cosmetic nit.
;
; Fixed by caching gui.c's own game_timer_line locally (game_timer_cache
; below, seeded by _spectrum_render_game_timer_clear every force-redraw,
; which per gui.c's own render_game_timer_only always precedes any delta
; call) and having BOTH routines paint through the same full-line text_print
; call -- text_print itself is then the only thing that ever computes glyph
; position, so the delta path can no longer disagree with the clear path
; about where a character lands. The per-character-pixel-write optimisation
; this trades away was never load-bearing: render_game_timer_only (gui.c)
; only reaches here once every 50 frames (~1Hz, spectrum_gui_tick), and
; docs/sprinter-render-budget.md's own measurement puts a full 38-char
; proportional line at 3.68ms -- this line is 23 chars, comfortably inside a
; once-a-second budget.
game_timer_cache:
    defs GAME_TIMER_CACHE_SIZE,' '

; HL=text (source line, up to GAME_TIMER_CACHE_SIZE bytes). Copies text into
; game_timer_cache, falls through to game_timer_paint. Clobbers everything.
game_timer_seed_and_paint:
    ld de,game_timer_cache
    ld bc,GAME_TIMER_CACHE_SIZE
    ldir

; No arguments. Paints game_timer_cache's current content at the fixed
; timer-line position.
;
; S5-finish plan D11 (buffer flip), F1: migrated to single-pass (back_base
; only) 2026-08-12, same reasoning as render_square/draw_frame_at (F0's
; own file-banner comment) -- this was the last remaining two-pass writer
; still painting directly into whichever buffer is live, so its own
; erase-then-redraw (gfx_fill_rect blanks the line, text_print then
; redraws it) was visible mid-repaint on screen exactly like P14's
; original tearing symptom this whole flip mechanism exists to fix.
; Reported by the human tester as "таймер мерцает" once the cursor/
; selection chain (F0) was confirmed fixed -- not a new regression, this
; call site was simply always out of F0's scope. gui.c's own render_
; game_timer_only already gates this to ~once a second (its own internal
; cadence), so no flip-storm risk migrating it (see [[sprinter-flip-
; storm-gotcha]]-equivalent check every F1 migration needs). Clobbers
; everything.
game_timer_paint:
    ld hl,(back_base)
    ld (@dest_base),hl
    ld b,GAME_TIMER_X_BYTE
    ld c,GAME_TIMER_Y
    ld d,GAME_TIMER_LINE_W_BYTES
    ld e,8
    xor a
    call gfx_fill_rect
    ld de,game_timer_cache
    ld ix,GAME_TIMER_X
    ld c,GAME_TIMER_Y
    ld a,STATUS_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0

; HL=text (__z88dk_fastcall, ASCIIZ, up to GAME_TIMER_TEXT_LEN chars).
; Erases the whole timer-line cell and redraws it -- used when gui.c's
; timer_force_redraw flag is set (timer just started, or after a menu
; toggle). Also the sole place game_timer_cache is seeded from gui.c's real
; content, so this must run before any _spectrum_render_game_timer_char call
; -- true today (spectrum_gui_game_timer_start/_stop and the force-redraw
; branch of render_game_timer_only always call this first). Clobbers
; everything.
    PUBLIC _spectrum_render_game_timer_clear
_spectrum_render_game_timer_clear:
    jp game_timer_seed_and_paint

; HL=spec (__z88dk_fastcall): spec[0]=index(0-22), spec[1]=char,
; spec[2]=is_space(0/1). Updates game_timer_cache[index] and repaints the
; WHOLE line through game_timer_paint -- see that routine's own comment for
; why a true per-character delta paint doesn't work against a proportional
; font. Clobbers everything.
    PUBLIC _spectrum_render_game_timer_char
_spectrum_render_game_timer_char:
    ld a,(hl)
    ld (@index),a
    inc hl
    ld a,(hl)
    ld (@char),a
    inc hl
    ld a,(hl)
    or a
    jr z,@have_char
    ld a,' '
    ld (@char),a
@have_char:
    ld a,(@index)
    ld hl,game_timer_cache
    ld e,a
    ld d,0
    add hl,de
    ld a,(@char)
    ld (hl),a
    jp game_timer_paint
@index: defb 0
@char: defb 0

; Sprinter's MENU band (y=16-28) and MOVE band (y=28-40) are two separate
; rows, unlike ZX where the menu bar and the GAME/TURN timer strip share
; one row (screen.asm's own menu_visible branch exists purely for that
; overlap) -- so there is no "timer pixels double as menu pixels" case
; here, and this is a plain alias.
    PUBLIC _spectrum_render_menu_timer_char
_spectrum_render_menu_timer_char:
    jp _spectrum_render_game_timer_char

; ZX draws the turn indicator on its own row (screen.asm's
; NETCHESSZX_TOP_TURN_ROW), separate from the GAME/TURN timer strip.
; Sprinter has no equivalent free row inside the MOVE band (already the
; timer line above) or the panel (which starts at the column headers) --
; the right-hand end of the MENU band (y=16-28) is otherwise blank once
; the static tab row's text ends, well short of PANEL_X=408, so that is
; where this lands. Not a ported ZX position; a Sprinter-specific choice,
; documented rather than silently invented.
TURN_LABEL_X EQU PANEL_X
TURN_LABEL_Y EQU MENU_Y+2
TURN_LABEL_W_BYTES EQU 24        ; 6 chars * 8px / 2

; L=mode (__z88dk_fastcall, single byte). 0=WHITE,1=BLACK,2=WHITE+check,
; 3=BLACK+check,4=CLEAR (src/spectrum/ui/gui.h's SPECTRUM_GUI_TURN_*
; values). Erases the label cell, then draws the matching fixed string
; (blank for CLEAR/unrecognised).
;
; F1 (2026-08-12, S5-finish plan D11): single-pass (back_base only) --
; event-driven (spectrum_gui_set_turn_label, called on move/game start/
; stop, never per-frame), so no flip-storm risk. Clobbers everything.
    PUBLIC _spectrum_render_turn_label
_spectrum_render_turn_label:
    ld a,l
    ld (@mode),a

    ld hl,(back_base)
    ld (@dest_base),hl
    ld b,TURN_LABEL_X/2
    ld c,TURN_LABEL_Y
    ld d,TURN_LABEL_W_BYTES
    ld e,8
    xor a
    call gfx_fill_rect

    ld a,(@mode)
    ld hl,@white_msg
    or a
    jr z,@have_msg
    dec a
    ld hl,@black_msg
    jr z,@have_msg
    dec a
    ld hl,@white_chk_msg
    jr z,@have_msg
    dec a
    ld hl,@black_chk_msg
    jr z,@have_msg
    ret                         ; CLEAR (4) or unrecognised -- erase only
@have_msg:
    ex de,hl
    ld ix,TURN_LABEL_X
    ld c,TURN_LABEL_Y
    ld a,STATUS_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0
@mode: defb 0
@white_msg: defb "WHITE",0
@black_msg: defb "BLACK",0
@white_chk_msg: defb "WHITE!",0
@black_chk_msg: defb "BLACK!",0

; --- status bar (S5-finish step 1) ------------------------------------------
;
; gui.c-driven replacement for render_status_text's own literal placeholder
; above: main.c's frame-loop wiring (Step 1) is what actually switches the
; STATUS band over to spectrum_gui_set_status("HOT SEAT") instead of the
; boot-time "NO SESSION" text -- both routines paint the exact same cell
; (STATUS_TEXT_X, STATUS_CLOCK_Y), so only one is actually visible once
; wired, same reasoning as the clock pair above.
STATUS_TEXT_W_BYTES EQU 106      ; generous erase width, clear of STATUS_CLOCK_X

; HL=text (__z88dk_fastcall, ASCIIZ). Erases and redraws the STATUS band's
; left-hand text.
;
; F1 (2026-08-12, S5-finish plan D11): single-pass (back_base only) --
; event-driven (spectrum_gui_set_status, not per-frame), no flip-storm
; risk. Clobbers everything.
    PUBLIC _spectrum_render_status
_spectrum_render_status:
    ld (@text),hl
    ld hl,(back_base)
    ld (@dest_base),hl
    ld b,STATUS_TEXT_X/2
    ld c,STATUS_CLOCK_Y
    ld d,STATUS_TEXT_W_BYTES
    ld e,8
    xor a
    call gfx_fill_rect
    ld de,(@text)
    ld ix,STATUS_TEXT_X
    ld c,STATUS_CLOCK_Y
    ld a,STATUS_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0
@text: dw 0

; Same as spectrum_render_status but in the error colour. Same F1
; single-pass migration, same reasoning (spectrum_gui_set_status_error,
; event-driven).
    PUBLIC _spectrum_render_status_error
_spectrum_render_status_error:
    ld (@text),hl
    ld hl,(back_base)
    ld (@dest_base),hl
    ld b,STATUS_TEXT_X/2
    ld c,STATUS_CLOCK_Y
    ld d,STATUS_TEXT_W_BYTES
    ld e,8
    xor a
    call gfx_fill_rect
    ld de,(@text)
    ld ix,STATUS_TEXT_X
    ld c,STATUS_CLOCK_Y
    ld a,CLOCK_ERROR_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0
@text: dw 0

; L=connected (__z88dk_fastcall, single byte: 0=off,1=mqtt/connecting,
; 2=on -- src/spectrum/ui/gui.c's own spectrum_gui_set_connected values).
; ZX draws this as a coloured attribute LED; there is no attribute plane
; here to repurpose the same way, and nothing in this port's own S5-finish
; wiring calls spectrum_gui_set_connected yet (Step 1 drives the STATUS
; text directly via spectrum_gui_set_status instead) -- an honest no-op
; stub rather than a half-designed indicator with no caller to validate it
; against. Revisit with a real design once S7's session wiring gives this
; a live caller.
    PUBLIC _spectrum_render_connection
_spectrum_render_connection:
    ret

; --- notices (S5-finish step 1) ---------------------------------------------
;
; ZX's notice line lives inside the info panel (INFO_NOTICE_ROW), not the
; global STATUS/INPUT bands -- render_layout.json's own panel.NOTICE
; section mirrors that. This is the first real feedback P13's "an illegal
; move does nothing at all, and there is no notice line yet" gap gets
; closed for -- main.c's board_select_or_move (Step 1 wiring) starts
; calling spectrum_gui_notify*/spectrum_gui_notify_msg on the same
; illegal-move/wrong-side paths app.c's cursor_select_or_move already
; covers.
NOTICE_X EQU PANEL_X
NOTICE_Y EQU PANEL_NOTICE_Y+2
NOTICE_W_BYTES EQU 112           ; comfortably inside the panel's own width
                                   ; (PANEL_X..PANEL_X+232, i.e. the screen's
                                   ; right edge) without a bridged PANEL_W

; HL=text (__z88dk_fastcall, ASCIIZ). Erases and redraws the notice line
; in the given colour. Shared body; the three PUBLIC entries below only
; differ in which colour they pass in A before falling through.
;
; F1 (2026-08-12, S5-finish plan D11): single-pass (back_base only) --
; event-driven (notify_internal, on illegal moves/etc, not per-frame), no
; flip-storm risk. Clobbers everything.
notice_paint:
    ld (@text),hl
    ld (@colour),a
    ld hl,(back_base)
    ld (@dest_base),hl
    ld b,NOTICE_X/2
    ld c,NOTICE_Y
    ld d,NOTICE_W_BYTES
    ld e,8
    xor a
    call gfx_fill_rect
    ld de,(@text)
    ld ix,NOTICE_X
    ld c,NOTICE_Y
    ld a,(@colour)
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0
@text: dw 0
@colour: defb 0

    PUBLIC _spectrum_render_notice
_spectrum_render_notice:
    ld a,STATUS_COLOR
    jp notice_paint

    PUBLIC _spectrum_render_notice_error
_spectrum_render_notice_error:
    ld a,CLOCK_ERROR_COLOR
    jp notice_paint

    PUBLIC _spectrum_render_notice_success
_spectrum_render_notice_success:
    ld a,CLOCK_SUCCESS_COLOR
    jp notice_paint

; --- input line (S5-finish step 1/3) ----------------------------------------
;
; The "> " prompt (render_input_line, above) is static; this paints the
; typed text that follows it. INPUT_EDIT (id 9, Step 3) is what actually
; drives this with live keystrokes -- until then nothing calls it, but it
; must link and paint something sane once wired.
INPUT_TEXT_X EQU INPUT_PROMPT_X+16
INPUT_TEXT_Y EQU INPUT_PROMPT_Y
INPUT_TEXT_W_BYTES EQU 240        ; generous erase width, well inside the
                                    ; 640px screen from x=24 onward

; HL=text (__z88dk_fastcall, ASCIIZ). Erases and redraws the input line's
; text (after the "> " prompt).
;
; F1 (2026-08-12, S5-finish plan D11): single-pass (back_base only) for
; consistency with every other live/event-driven routine in this file,
; even though nothing calls this one yet (see banner above) -- so a
; future INPUT_EDIT implementer does not copy the stale two-pass shape.
; Clobbers everything.
    PUBLIC _spectrum_render_input
_spectrum_render_input:
    ld (@text),hl
    ld hl,(back_base)
    ld (@dest_base),hl
    ld b,INPUT_TEXT_X/2
    ld c,INPUT_TEXT_Y
    ld d,INPUT_TEXT_W_BYTES
    ld e,8
    xor a
    call gfx_fill_rect
    ld de,(@text)
    ld ix,INPUT_TEXT_X
    ld c,INPUT_TEXT_Y
    ld a,INPUT_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0
@text: dw 0

; HL=spec (__z88dk_fastcall). ZX repaints one character cell at a given
; column with an optional cursor-inverted attribute (src/spectrum/ui/
; gui.c's spectrum_gui_input_cell -> this). Per-cell/cursor rendering needs
; a real design pass tied to INPUT_EDIT's own line-editing semantics (Step
; 3 scope, not yet built) -- honest no-op stub until then, same reasoning
; as the GUI_LOG-dependent stubs below.
    PUBLIC _spectrum_render_input_cell
_spectrum_render_input_cell:
    ret

; --- move list (Step 2 scope, GUI_LOG(2)) -----------------------------------
;
; ZX/Next's move list is fed by a ported overlay (GUI_LOG, id 2,
; asm/overlay/gui_log/entry_gui_log.asm's word-wrap/ply-parsing Z80
; helpers, src/spectrum/overlay/gui_log_ovl.c). Those helpers are ZX-only
; asm this port cannot link, and hot-seat has no network ply text to parse
; in the first place -- every move is generated locally, already in order.
; src/sprinter/gui_log_sprinter.c is the Sprinter-native replacement: its
; own ply counter and its own scrolling, writing into the SAME move_lines
; low-RAM layout (src/spectrum/ui/layout.h's NETCHESSZX_MOVE_* constants)
; gui.h's own spectrum_gui_add_move contract already assumes, so a later
; pass (real notation, remote moves) can extend that file without
; touching this one. MOVE_ROWS/MOVE_SLOT_SIZE/MOVE_BLACK_OFFSET below
; mirror layout.h's own values, hardcoded here rather than bridged -- same
; reasoning as this file's own VRAM_ALIAS_KEY (a fixed manifest constant,
; not shared address state).
;
; The chat panel has no content-producing path at all this pass (no
; INPUT_EDIT, no network) -- port.md's own S5 DoD only asks for a
; placeholder ("чат-заглушка"), painted once at boot as part of
; _spectrum_info_show_game below. spectrum_render_chat/_chat_at/
; _chat_scroll stay honest no-op stubs -- nothing calls them.
MOVE_ROWS EQU 7                    ; layout.h NETCHESSZX_MOVE_ROWS
MOVE_SLOT_SIZE EQU 32               ; layout.h NETCHESSZX_MOVE_SLOT_SIZE
MOVE_BLACK_OFFSET EQU 18            ; layout.h NETCHESSZX_MOVE_BLACK_OFFSET
MOVE_ROW_H EQU 12                   ; same 12px rhythm as every other row band
MOVE_WHITE_X EQU PANEL_X+8          ; matches PANEL_HEADER_WHITE_X below
MOVE_BLACK_X EQU PANEL_X+120        ; matches PANEL_HEADER_BLACK_X below
MOVE_ERASE_X_BYTE EQU PANEL_X/2
MOVE_ERASE_W_BYTES EQU 116          ; PANEL_W(232)/2 -- the whole row width,
                                     ; one erase covers both columns
MOVE_ROW_Y_TABLE:
    defb 0,12,24,36,48,60,72        ; row*MOVE_ROW_H

; A=row(0-6). Erases and repaints one move-list row from LOWRAM_MOVE_LOG_
; ADDR+row*MOVE_SLOT_SIZE (white text at +0, black at +MOVE_BLACK_OFFSET,
; both always repainted together -- gui_log_sprinter.c never writes one
; half without the other already being correct). Single-pass (back_base):
; reachable live (a menu RESET as well as every add-move call), not
; boot-only, same discipline as every other F1-migrated routine. Clobbers
; everything.
render_move_row:
    ld (@row),a
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl                       ; HL = row*32
    ld de,LOWRAM_MOVE_LOG_ADDR
    add hl,de
    ld (@line),hl

    ld a,(@row)
    ld hl,MOVE_ROW_Y_TABLE
    ld e,a
    ld d,0
    add hl,de
    ld a,(hl)
    add a,PANEL_MOVES_Y
    ld (@y),a

    ld hl,(back_base)
    ld (@dest_base),hl
    ld b,MOVE_ERASE_X_BYTE
    ld a,(@y)
    ld c,a
    ld d,MOVE_ERASE_W_BYTES
    ld e,MOVE_ROW_H
    xor a
    ld hl,(@dest_base)
    call gfx_fill_rect

    ld de,(@line)
    ld ix,MOVE_WHITE_X
    ld a,(@y)
    ld c,a
    ld a,STATUS_COLOR
    ld hl,(@dest_base)
    call text_print

    ld hl,(@line)
    ld de,MOVE_BLACK_OFFSET
    add hl,de
    ex de,hl
    ld ix,MOVE_BLACK_X
    ld a,(@y)
    ld c,a
    ld a,STATUS_COLOR
    ld hl,(@dest_base)
    jp text_print
@row: defb 0
@line: dw 0
@y: defb 0
@dest_base: dw 0

; HL=moves (__z88dk_fastcall) -- ALWAYS ignored: this file's move rows
; live at the fixed LOWRAM_MOVE_LOG_ADDR gui_log_sprinter.c and this file
; already agree on, so the passed pointer never names anything render_
; move_row does not already read itself. Full repaint of every row.
    PUBLIC _spectrum_render_moves
_spectrum_render_moves:
    xor a
@loop:
    push af
    call render_move_row
    pop af
    inc a
    cp MOVE_ROWS
    jr c,@loop
    ret

; HL=line (__z88dk_fastcall): a row-BASE pointer into LOWRAM_MOVE_LOG_ADDR
; (gui_log_sprinter.c always passes move_lines+row*MOVE_SLOT_SIZE, never
; the black-column-shifted pointer). Repaints just that one row.
    PUBLIC _spectrum_render_move_at
_spectrum_render_move_at:
    ld de,LOWRAM_MOVE_LOG_ADDR
    or a
    sbc hl,de
    ld a,l                          ; offset fits one byte (log is 224B)
    srl a
    srl a
    srl a
    srl a
    srl a                            ; /32 = row
    jp render_move_row

    PUBLIC _spectrum_render_moves_scroll
_spectrum_render_moves_scroll:
    ret
    PUBLIC _spectrum_render_chat
_spectrum_render_chat:
    ret
    PUBLIC _spectrum_render_chat_at
_spectrum_render_chat_at:
    ret
    PUBLIC _spectrum_render_chat_scroll
_spectrum_render_chat_scroll:
    ret

; --- info panel chrome (S5-finish step 1) -----------------------------------
;
; ZX's _spectrum_info_show_game (screen.asm) paints "White"/"Black" column
; headers over the move list plus a "Chat" title and a divider line over
; the chat panel, each its own dedicated 8px character row. Sprinter's
; DIVIDER section is only 7px tall (render_layout.json -- the panel's five
; sections must tile exactly 192px, and MOVES/CHAT/NOTICE/HEADER's own
; sizes leave no room for a second dedicated row the way ZX's two rows
; do), and AFNT640 needs a full 8px for any glyph -- so the divider here
; is a plain rule with no "Chat" label, a Sprinter-specific simplification
; forced by the pixel budget, not a ported ZX behaviour.
PANEL_HEADER_WHITE_X EQU PANEL_X+8
PANEL_HEADER_BLACK_X EQU PANEL_X+120
PANEL_HEADER_TEXT_Y EQU PANEL_HEADER_Y+2
PANEL_HEADER_RULE_Y EQU PANEL_HEADER_Y+11
PANEL_DIVIDER_RULE_Y EQU PANEL_DIVIDER_Y+3
PANEL_RULE_X_BYTE EQU PANEL_X/2
PANEL_RULE_W_BYTES EQU 108        ; ~216px, inside the panel's 232px width
PANEL_RULE_COLOR EQU 13           ; hud_muted

PANEL_CHAT_TEXT_Y EQU PANEL_CHAT_Y+2

; No arguments. Paints the move-list column headers, the two panel
; dividers (header/moves and moves/chat), and the chat panel's one static
; placeholder line (port.md's own S5 DoD only asks for a "чат-заглушка" --
; no INPUT_EDIT, no network, nothing to show yet -- see this file's own
; move-list section header for the fuller reasoning). Boot-only, two-pass
; on purpose: nothing repaints this again after boot (S5-finish plan D12).
; Clobbers everything.
    PUBLIC _spectrum_info_show_game
_spectrum_info_show_game:
    ld hl,VRAM_BUF0
    call @paint
    ld hl,VRAM_BUF1
    jp @paint
@paint:
    ld (@dest_base),hl
    ld de,@white_msg
    ld ix,PANEL_HEADER_WHITE_X
    ld c,PANEL_HEADER_TEXT_Y
    ld a,STATUS_COLOR
    ld hl,(@dest_base)
    call text_print

    ld de,@black_msg
    ld ix,PANEL_HEADER_BLACK_X
    ld c,PANEL_HEADER_TEXT_Y
    ld a,STATUS_COLOR
    ld hl,(@dest_base)
    call text_print

    ld b,PANEL_RULE_X_BYTE
    ld c,PANEL_HEADER_RULE_Y
    ld d,PANEL_RULE_W_BYTES
    ld e,1
    ld a,PANEL_RULE_COLOR
    ld hl,(@dest_base)
    call gfx_fill_rect

    ld b,PANEL_RULE_X_BYTE
    ld c,PANEL_DIVIDER_RULE_Y
    ld d,PANEL_RULE_W_BYTES
    ld e,1
    ld a,PANEL_RULE_COLOR
    ld hl,(@dest_base)
    call gfx_fill_rect

    ld de,@chat_msg
    ld ix,PANEL_HEADER_WHITE_X
    ld c,PANEL_CHAT_TEXT_Y
    ld a,STATUS_COLOR
    ld hl,(@dest_base)
    jp text_print
@dest_base: dw 0
@white_msg: defb "White",0
@black_msg: defb "Black",0
@chat_msg: defb "Chat: n/a (hot-seat)",0

; --- menu bar visibility (S5-finish step 1/3, plan D12 fix) -----------------
;
; L=visible (__z88dk_fastcall, single byte -- gui.c's own packed contract:
; 0=hide, bit7 set=partial focus-highlight redraw (old<<3|new), else=full
; redraw -- L is focus+1). D12 fix #3 (2026-08-12): the two earlier
; visual signals (whole-row invert, then a notice-line tab-name echo --
; see render_menu_tabs's own comment for why those shipped first and what
; replaced them) are gone; this now just decodes L into a focus index (or
; MENU_TAB_COUNT for "closed") and hands it to render_menu_tabs, which
; paints the per-tab highlight box directly.
    PUBLIC _spectrum_render_menu
_spectrum_render_menu:
    ld a,l
    or a
    jr z,@closed
    bit 7,a
    jr z,@opened
    and 7                       ; navigating: new focus already in bits 0-2
    jp render_menu_tabs
@opened:
    dec a                       ; opened: L was focus+1
    jp render_menu_tabs
@closed:
    jp render_menu_bar

; --- About (S9 scope, plan D10) ---------------------------------------------
;
; ABOUT (id 12) is a full-screen-mode-switch overlay (320x256x8bpp, port.md
; S9) -- explicitly out of S5's scope. Honest stub: returns "did not show"
; (0 in L, the confirmed uint8_t-return register -- see this section's own
; opening comment) so spectrum_gui_show_about's own caller falls back
; cleanly (src/spectrum/ui/gui.c's own about_visible reset already handles
; a false return).
    PUBLIC _spectrum_render_about
_spectrum_render_about:
    ld l,0
    ret

; --- misc bridges ------------------------------------------------------------

; No arguments. platform.h's spectrum_frame_wait -- a thin alias for this
; port's own frame_wait (im2_s1.asm), which main.c already calls directly;
; gui.c needs the portable name to link.
    PUBLIC _spectrum_frame_wait
_spectrum_frame_wait:
    jp frame_wait

; No arguments. uart.h's spectrum_uart_background_pump -- Sprinter has no
; UART transport (uNet/DSS is the only network path, port.md), so this is
; a permanent no-op rather than a stub awaiting a later step.
    PUBLIC _spectrum_uart_background_pump
_spectrum_uart_background_pump:
    ret

; No arguments, returns uint8_t in L (see this section's own opening
; comment). render.h's spectrum_key_poll, gui.c's spectrum_gui_poll_key
; wrapper's own backing call -- a read-and-clear poll of the same key_code
; latch key_poll (im2_s1.asm) already fills every frame. Unreachable from
; this port's own wiring today (main.c drives key_code through key_poll/
; board_cursor_move/board_select_or_move directly, not through gui.c's
; poll wrapper), same reasoning as spectrum_render_square_mark above --
; exists so gui.c's compiled object resolves, ready if a future pass
; switches input handling over to gui.c's own model.
    PUBLIC _spectrum_key_poll
_spectrum_key_poll:
    ld a,(key_code)
    ld l,a
    xor a
    ld (key_code),a
    ret
