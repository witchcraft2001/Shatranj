; S4 static scene (port.md section 5/S4): a board at the starting position
; with the §3.4 HUD layout, theme switching (palette-only) and piece-set
; switching (asset pages) on hotkeys 'B'/'T'/'S'. No new architectural
; mechanics -- every drawing primitive here is S1-S3-proven (gfx_fill_rect/
; gfx_draw_tile from S2, the WIN0-under-DI theme-blob copy from S3's
; ovl_s3.asm pattern, both-bank palette writes from S1's write_palette).
;
; Precomposed piece tiles (tools/build_sprinter_piece_tiles.py) carry their
; board-square background as PALETTE INDICES 2/3, not baked-in RGB, so a
; theme switch is a handful of palette writes with zero tile traffic and
; zero redraw -- the whole board (pieces included) recolours instantly.
;
; Position-independent code and data: INCLUDEd once from resident_s1.asm's
; flexible code area, after ovl_s3.asm (which it does not depend on, but
; keeping every WIN1-half module's relative order stable avoids gratuitous
; resident.bin diffs between stages).

        IFNDEF SPRINTER_SCENE_S4_INC
        DEFINE SPRINTER_SCENE_S4_INC

        INCLUDE "dss.inc"
        INCLUDE "win0.inc"
        INCLUDE "fixed_layout.inc"
        INCLUDE "hdr.inc"
        INCLUDE "render_layout.inc"

; Generated from VERSION (CLAUDE.md rule 5: no version literals in code):
; a guarded sprinter_banner_msg DATA label, same shape as palette_base.
; inc's palette_rgb. Named sprinter_version.inc, not the generic
; "version.inc" -- extern/esp_net/src/include/version.inc (the uNet
; submodule's own package-version file) is on the same -I search path
; and would otherwise silently shadow this one (sjasmplus resolves
; INCLUDE by search order, not by directory proximity -- the collision
; produced a confusing "Label not found" only in the final assembly
; pass, since it opened the WRONG file). tools/run_sprinter_z80_tests.sh
; generates its own copy into its private generated dir first on its
; include path, same as fixed_layout.inc/render_layout.inc/
; palette_base.inc -- no test-only special-casing needed here, unlike
; S2_TEST_FONT_BASE (text640.asm), because nothing in the S4 unit tests
; needs to observe a specific version string.
        INCLUDE "sprinter_version.inc"

; --- fixed slot contract (tools/build_sprinter_ui_assets.py; "shared by
; hand, no generated bridge" -- the same convention bench_s2.asm's
; TILE_A_SLOT etc. already use) ---------------------------------------

THEME_SLOT      EQU 27          ; make_sprinter_assets_page.py's --theme-bin
; Theme-record name field (gen_sprinter_palette.py's THEME_NAME_FIELD_LEN):
; 8 bytes, of which the generator lets a name use at most 7 so the last one
; is always NUL -- scene_draw_status prints the field in place as ASCIIZ.
THEME_NAME_LEN  EQU 8
LOGO_SLOT       EQU 44
DOT_SLOT        EQU 50
RING_SLOT       EQU 51

; Sprinter logo geometry (assets/sprinter/logo_sprinter.png; cross-checked
; against the committed PNG's actual size by
; tests/tools/test_scene_logo_dims.py so a resize doesn't silently misalign
; the banner). Right-aligned with a small margin from the screen edge --
; the reason gfx_core.asm's tile_x_byte got a tile_x_hi companion (S4):
; pixel x = SCREEN_W - LOGO_WIDTH_PX - margin happens to stay under 256
; bytes for this specific asset, but the mechanism is exercised by
; tests/sprinter/z80/t_draw_tile.asm's own >=256 case regardless.
LOGO_WIDTH_PX   EQU 172
LOGO_HEIGHT_PX  EQU 16
LOGO_STRIDE     EQU LOGO_WIDTH_PX/2
LOGO_MARGIN_PX  EQU 8
LOGO_X_BYTE     EQU (SCREEN_W-LOGO_WIDTH_PX-LOGO_MARGIN_PX)/2

; Both board cell dimensions happen to equal 24 in their own units
; (CELL_W_BYTES=BOARD_CELL_W/2=24 bytes; BOARD_CELL_H=24 pixels), so one
; lookup table serves both the byte-column (x) and pixel-row (y) domains.
; That coincidence is what the single table depends on, so it is asserted
; rather than assumed: if render_layout.json ever gives the cell a
; different width or height, this file must gain a second table instead of
; silently laying the board out wrong.
        ASSERT CELL_W_BYTES == 24
        ASSERT BOARD_CELL_H == 24
MUL_CELL_TABLE: DB 0,24,48,72,96,120,144,168

; --- coordinate glyphs (a-h, 1-8) --------------------------------------
;
; Outside the playfield, exactly as the ZX original does it
; (asm/spectrum/screen.asm's draw_board_coords writes the file letters on
; the row above NETCHESSZX_GAME_BOARD_TOP_ROW and the rank digits in the
; column left of NETCHESSZX_GAME_BOARD_LEFT_COL). The first cut printed
; them inside the edge cells instead; on a 48x24 cell already carrying a
; 32x16 piece that leaves the glyph fighting the piece art for contrast,
; and it was unreadable in MAME.
;
; The a-h row lives in the MOVE band, whose own move/timer line moved into
; the panel column (see scene_draw_move_line) precisely to free it; the
; 1-8 digits fit in the 16px margin the layout already leaves between the
; screen edge and BOARD_X, so neither the board nor any band moved.
;
; AFNT is proportional: '1'-'8' and 'a'-'h' are all 3 packed byte-columns
; = 6px wide (only 'f' is narrower, 4px, which puts it 1px off-centre --
; invisible at this size). text_print rejects an odd X, so each centring
; offset is the true centre rounded down to even.
COORD_GLYPH_W   EQU 6
COORD_GLYPH_H   EQU 8                   ; AFNT raster height (text640.asm)
COORD_Y         EQU MOVE_Y+(MOVE_H-COORD_GLYPH_H)/2
FILE_X_OFFSET   EQU ((BOARD_CELL_W-COORD_GLYPH_W)/2) & #FE
RANK_X          EQU ((BOARD_X-COORD_GLYPH_W)/2) & #FE
RANK_Y_OFFSET   EQU (BOARD_CELL_H-COORD_GLYPH_H)/2
COORD_COLOR     EQU #01                 ; bg=0 (screen), fg=1 (text)
; Right end of the status bar, mirroring the banner's 8px left margin.
; "--:--" is 5 AFNT glyphs of 3,3,2,3,3 packed byte-columns = 28px, hence
; the width below; it is a placeholder string this file owns outright, so
; a font-metric constant here cannot drift out from under some other
; caller the way a shared one could.
STATUS_CLOCK_W  EQU 28
STATUS_CLOCK_X  EQU SCREEN_W-8-STATUS_CLOCK_W
        ASSERT (FILE_X_OFFSET & 1) == 0
        ASSERT (RANK_X & 1) == 0
        ASSERT RANK_X+COORD_GLYPH_W <= BOARD_X            ; clear of the board
        ASSERT FILE_X_OFFSET+COORD_GLYPH_W <= BOARD_CELL_W ; inside its file
        ASSERT COORD_Y >= MENU_Y+MENU_H                    ; clear of the menu
        ASSERT COORD_Y+COORD_GLYPH_H <= MOVE_Y+MOVE_H      ; clear of the board

; --- state (WIN1-half: not one of the section gate's pinned prefixes,
; nothing here needs to survive an S3 l_call) --------------------------

scene_active:      DB 0     ; main_loop's debug-row draw skips while set
scene_ready:        DB 0     ; 0=not checked, 1=ready, 2=no piece pages
scene_theme_idx:    DB 0
scene_set_idx:      DB 0
scene_piece_page1:  DB 0     ; physical page: HDR asset index 1
scene_piece_page2:  DB 0     ; physical page: HDR asset index 2
scene_dest_base:    DW 0     ; set by the caller before each scene_draw_* call
scene_char_buf:     DB 0,0   ; 1-char ASCIIZ staging for coordinate glyphs
scene_theme_buf:    DS 256,0

; 64 squares x 4 bits, rank 8 first, high nibble = file a (port.md S4
; plan): 0 empty, 1-6 = wK,wQ,wR,wB,wN,wP, 7-12 = bK,bQ,bR,bB,bN,bP.
; Codes: 1=wK 2=wQ 3=wR 4=wB 5=wN 6=wP 7=bK 8=bQ 9=bR 10=bB 11=bN 12=bP.
scene_start_position:
        DB #9B,#A8,#7A,#B9     ; rank 8: bR bN bB bQ bK bB bN bR
        DB #CC,#CC,#CC,#CC     ; rank 7: bP x8
        DB #00,#00,#00,#00     ; rank 6
        DB #00,#00,#00,#00     ; rank 5
        DB #00,#00,#00,#00     ; rank 4
        DB #00,#00,#00,#00     ; rank 3
        DB #66,#66,#66,#66     ; rank 2: wP x8
        DB #35,#42,#14,#53     ; rank 1: wR wN wB wQ wK wB wN wR

; --- hotkey entry points ------------------------------------------------

; 'B': toggle the scene. Activating draws it (lazily initialising on first
; use); deactivating restores the S1 stand's own palette and grid via
; video_init (also undoes any theme override of indices 2/3).
scene_toggle:
        ld      a,(scene_active)
        or      a
        jr      nz,.deactivate

        ld      a,(scene_ready)
        or      a
        jr      nz,.have_ready
        call    scene_init
.have_ready:
        ld      a,(scene_ready)
        cp      2
        ret     z               ; unavailable: message already on screen

        ld      a,1
        ld      (scene_active),a
        jp      scene_draw_all

.deactivate:
        xor     a
        ld      (scene_active),a
        jp      video_init

; 'T': next theme (palette-only, both banks, zero tile traffic). No-op if
; the scene is inactive or has no theme data.
scene_theme_next:
        ld      a,(scene_active)
        or      a
        ret     z
        ld      a,(scene_ready)
        cp      1
        ret     nz
        ld      a,(scene_theme_buf+1)  ; theme_count
        or      a
        ret     z

        ld      b,a
        ld      a,(scene_theme_idx)
        inc     a
        cp      b
        jr      c,.store_idx
        xor     a
.store_idx:
        ld      (scene_theme_idx),a

        call    scene_theme_record_ptr
        ld      bc,THEME_NAME_LEN
        add     hl,bc                   ; hl -> first entry (index,R,G,B)

        ; entries_per_theme is blob data: 0 would make the DJNZ below run
        ; 256 times over whatever follows the record and spray both palette
        ; banks. tools/gen_sprinter_palette.py rejects such a theme, and
        ; this is the resident's own half of that guard.
        ld      a,(scene_theme_buf+2)   ; entries_per_theme
        or      a
        jr      z,.name_only
        ld      b,a

        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a
.entry_loop:
        ld      a,(hl)
        inc     hl
        call    write_palette_entry     ; advances hl by 3 itself
        djnz    .entry_loop

        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei

.name_only:
        jp      scene_draw_theme_name_both
.saved_win3: DB 0

; 'S': next piece set -- redraws only the board (fills + 32 piece blits +
; coordinate glyphs + demo markers), both buffers. No-op if inactive.
scene_set_next:
        ld      a,(scene_active)
        or      a
        ret     z

        ld      a,(scene_set_idx)
        inc     a
        cp      3
        jr      c,.store_idx
        xor     a
.store_idx:
        ld      (scene_set_idx),a

        ld      hl,#C000
        ld      (scene_dest_base),hl
        call    scene_draw_board_and_markers
        ld      hl,#C140
        ld      (scene_dest_base),hl
        jp      scene_draw_board_and_markers

; --- lazy init -----------------------------------------------------------

; Requires >=3 asset pages (font/UI + 2 piece pages). Copies the theme
; blob (page 0, slot THEME_SLOT) into scene_theme_buf via the same
; win0_map_di/LDIR/win0_restore pattern S3's ovl_s3.asm uses for its
; overlay copy. Clobbers AF, BC, DE, HL, IX.
scene_init:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGES_OFFSET)
        cp      3
        jr      nc,.have_pages

        ld      a,2
        ld      (scene_ready),a
        call    resolve_buffers
        ld      hl,(front_base)
        ld      de,scene_no_pages_msg
        ld      ix,BOARD_X
        ld      c,BOARD_Y
        ld      a,1
        jp      scene_text

.have_pages:
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+1)
        ld      (scene_piece_page1),a
        ld      a,(HDR_ADDR+HDR_ASSET_PAGE0_OFFSET+2)
        ld      (scene_piece_page2),a

        ld      a,(bench_asset_page)
        win0_map_di
        ld      hl,THEME_SLOT*256
        ld      de,scene_theme_buf
        ld      bc,256
        ldir
        win0_restore

        ld      a,1
        ld      (scene_ready),a
        ret

scene_no_pages_msg: DB "NO PIECE PAGES",0

; Returns HL -> scene_theme_buf's current-theme record (name[8], then
; entries_per_theme x (index,R,G,B)). Clobbers AF, BC.
scene_theme_record_ptr:
        ld      a,(scene_theme_buf+2)  ; entries_per_theme
        add     a,a
        add     a,a
        add     a,THEME_NAME_LEN
        ld      c,a                     ; c = record stride

        ld      hl,scene_theme_buf+4
        ld      a,(scene_theme_idx)
        or      a
        ret     z
        ld      b,a
.mul_loop:
        ld      a,l
        add     a,c
        ld      l,a
        jr      nc,.no_carry
        inc     h
.no_carry:
        djnz    .mul_loop
        ret

; B=row(0..7), C=col(0..7). Returns A=packed code from scene_start_
; position (0 empty, 1-6 wK..wP, 7-12 bK..bP), the raw nibble -- callers
; that want a piece_index still need their own "dec a" after checking for
; 0. A standalone routine (not inlined into scene_draw_board_and_markers)
; so the start-position table's decode logic has a register-only
; interface a z80 unit test can drive directly. Clobbers AF, DE, HL.
scene_piece_code_at:
        push    bc
        ld      a,b
        add     a,a
        add     a,a                     ; row*4
        ld      l,a
        ld      h,0
        ld      a,c
        srl     a                       ; col/2
        ld      e,a
        ld      d,0
        add     hl,de
        ld      de,scene_start_position
        add     hl,de
        ld      a,(hl)
        ld      (.byte_val),a
        pop     bc
        ld      a,c
        and     1                       ; col parity (LD below preserves F)
        ld      a,(.byte_val)
        jr      z,.high_nibble
        and     #0F
        ret
.high_nibble:
        rrca
        rrca
        rrca
        rrca
        and     #0F
        ret
.byte_val: DB 0

; B=row(0..7), C=col(0..7). Returns A = that square's board-colour palette
; index: 2 (light) or 3 (dark). Row 0 is rank 8 and col 0 is file a, so the
; expected corners are a8 light, a1 dark, h1 light. A standalone routine
; for the same reason scene_piece_code_at is one: an inverted parity draws
; a plausible-looking but wrong board, and this gives the z80 unit test a
; register-only interface to pin the formula against named squares.
; Clobbers AF.
scene_cell_bg:
        ld      a,b
        add     a,c
        and     1
        add     a,2                     ; 2=light, 3=dark
        ret

; A=piece_index(0..11), B=bg_offset(0=light,1=dark). Returns A=slot,
; E=physical asset page, reading scene_set_idx/scene_piece_page1/
; scene_piece_page2 (module state) for which of the 3 sets is active.
; Slot layout matches tools/build_sprinter_piece_tiles.py: slot = set_
; base + piece_index*2 + bg_offset, set_base 0/24 on page1 (california/
; mpchess) or 0 on page2 (totoy). Clobbers AF, C, DE, HL.
scene_piece_slot_and_page:
        push    af
        ld      a,(scene_set_idx)
        or      a
        jr      z,.set0
        cp      1
        jr      z,.set1
        ld      c,0
        ld      a,(scene_piece_page2)
        jr      .have_base
.set0:
        ld      c,0
        ld      a,(scene_piece_page1)
        jr      .have_base
.set1:
        ld      c,24
        ld      a,(scene_piece_page1)
.have_base:
        ld      e,a                     ; e = physical page
        pop     af                      ; a = piece_index restored
        add     a,a                     ; *2
        add     a,c                     ; + set_base
        add     a,b                     ; + bg_offset
        ret

; --- full draw -----------------------------------------------------------

; Draws the whole static scene into BOTH VRAM buffers (so hotkey '1's
; RGMOD flip stays honest -- video_init's own precedent). Clobbers
; everything (calls throughout).
scene_draw_all:
        ld      hl,#C000
        ld      (scene_dest_base),hl
        call    .draw_one
        ld      hl,#C140
        ld      (scene_dest_base),hl
        call    .draw_one
        ret
.draw_one:
        ld      hl,(scene_dest_base)
        xor     a
        call    gfx_clear_buffer
        call    scene_draw_banner
        call    scene_draw_menu
        call    scene_draw_move_line
        call    scene_draw_board_and_markers
        call    scene_draw_coords
        call    scene_draw_panel
        call    scene_draw_status
        jp      scene_draw_input

; --- individual bands ------------------------------------------------

; Title + version (text) on the left, the real Sprinter logo (hardware-
; keyed tile) right-aligned via tile_x_hi. Clobbers AF, BC, DE, HL, IX.
scene_draw_banner:
        ld      hl,(scene_dest_base)
        ld      de,sprinter_banner_msg
        ld      ix,8
        ld      c,4
        ld      a,1
        call    scene_text

        ld      a,(bench_asset_page)
        ld      (tile_src_page),a
        ld      a,LOGO_SLOT
        ld      (tile_src_slot),a
        ld      a,LOGO_STRIDE
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      a,LOGO_HEIGHT_PX
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_KEY
        ld      (tile_alias),a
        ld      hl,(scene_dest_base)
        ld      (tile_dest_base),hl
        ld      a,LOGO_X_BYTE
        ld      (tile_x_byte),a
        ld      a,LOGO_X_BYTE/256
        ld      (tile_x_hi),a
        xor     a
        ld      (tile_y),a
        jp      gfx_draw_tile

scene_draw_menu:
        ld      hl,(scene_dest_base)
        ld      de,scene_menu_msg
        ld      ix,8
        ld      c,MENU_Y+2
        ld      a,1
        jp      scene_text

scene_menu_msg: DB "FILE  DISCONNECT  RESET  FLIP  THEME  ABOUT",0

; The move/game-timer line, in the PANEL column rather than over the board:
; the band's left half is now the a-h coordinate row (scene_draw_coords),
; and the panel column at this Y sits directly under the Sprinter logo and
; directly above the panel's own header/move list, so the whole right-hand
; column reads as one block. This is also where the ZX original keeps it
; (src/spectrum/ui/layout.h: NETCHESSZX_TOP_TIMER_ROW/_COL put the game
; timer at the top RIGHT, above the info panel, not over the board).
;
; Content mirrors the ZX line's two clocks (gui.c's build_game_timer_line:
; "GAME:" total + " TURN:" for the current move) plus this stand's move
; placeholder -- 176px of the panel's 232, so it clears the panel's right
; edge without text_print's pre-scan having to clip anything.
scene_draw_move_line:
        ld      hl,(scene_dest_base)
        ld      de,scene_move_msg
        ld      ix,PANEL_X
        ld      c,COORD_Y
        ld      a,1
        jp      scene_text

scene_move_msg: DB "Move: --  GAME --:--  TURN --:--",0

; Board fills (64 cells) + 32 starting-position piece blits + the two demo
; hardware-key markers. A stand-alone unit (not folded into scene_draw_
; all's linear sequence) so scene_set_next can redraw just this after a
; set switch: the demo markers live on cells this routine also fills, so
; both must repaint together or the fill would erase them. The coordinate
; glyphs are deliberately NOT in here -- they now sit outside the
; playfield (scene_draw_coords), so a set switch cannot disturb them and
; need not repaint them. Clobbers everything.
scene_draw_board_and_markers:
        xor     a
        ld      (.row),a
.row_loop:
        xor     a
        ld      (.col),a
.col_loop:
        ld      a,(.row)
        ld      b,a
        ld      a,(.col)
        ld      c,a
        call    scene_cell_bg
        ld      (.bg),a

        ld      a,(.col)
        ld      hl,MUL_CELL_TABLE
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(hl)
        add     a,BOARD_X_BYTE
        ld      (.x_byte),a

        ld      a,(.row)
        ld      hl,MUL_CELL_TABLE
        ld      e,a
        add     hl,de
        ld      a,(hl)
        add     a,BOARD_Y
        ld      (.y),a

        ld      a,(.x_byte)
        ld      b,a
        ld      a,(.y)
        ld      c,a
        ld      d,CELL_W_BYTES
        ld      e,BOARD_CELL_H
        ld      hl,(scene_dest_base)
        ld      a,(.bg)
        call    gfx_fill_rect

        ld      a,(.row)
        ld      b,a
        ld      a,(.col)
        ld      c,a
        call    scene_piece_code_at
        or      a
        jr      z,.no_piece

        dec     a                       ; piece_index 0..11
        ld      (.piece_index),a

        ld      a,(.bg)
        sub     2                       ; 2/3 -> 0/1 bg_offset
        ld      b,a
        ld      a,(.piece_index)
        call    scene_piece_slot_and_page
        ld      (tile_src_slot),a
        ld      a,e
        ld      (.piece_page),a

        ld      a,(.piece_page)
        ld      (tile_src_page),a
        ld      hl,(scene_dest_base)
        ld      (tile_dest_base),hl
        ld      a,(.x_byte)
        add     a,4                     ; centre: (48-32)/2 = 8px = 4 bytes
        ld      (tile_x_byte),a
        xor     a
        ld      (tile_x_hi),a
        ld      a,(.y)
        add     a,4                     ; centre: (24-16)/2 = 4px
        ld      (tile_y),a
        ld      a,16
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_OPAQUE
        ld      (tile_alias),a
        call    gfx_draw_tile

.no_piece:
        ld      hl,.col
        inc     (hl)
        ld      a,(hl)
        cp      BOARD_COLS
        jp      c,.col_loop
        ld      hl,.row
        inc     (hl)
        ld      a,(hl)
        cp      BOARD_ROWS
        jp      c,.row_loop

        jp      .draw_markers

; Demo hardware-key markers: dot on e4 (light square), ring on e5 (dark
; square) -- the two central squares closest to the middle of the board
; that differ in colour, so the #FF key's effect is visible against both
; board colours on one screen. Both squares are empty in the starting
; position.
;
; The S4 plan said e4/d5; that pairing does not do the job, because d5 is
; light too (scene_cell_bg: row 3, col 3 -> even -> index 2), which would
; have put both markers on the same background and proved nothing about
; the key over a dark square. e5 is the fix, pinned by the unit test.
.draw_markers:
        ld      a,(bench_asset_page)
        ld      (tile_src_page),a
        ld      a,DOT_SLOT
        ld      (tile_src_slot),a
        ld      a,8
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_KEY
        ld      (tile_alias),a
        ld      hl,(scene_dest_base)
        ld      (tile_dest_base),hl
        ld      a,BOARD_X_BYTE+4*CELL_W_BYTES+8 ; col e (4), centred in 16x8
        ld      (tile_x_byte),a
        xor     a
        ld      (tile_x_hi),a
        ld      a,BOARD_Y+4*BOARD_CELL_H+8      ; row 4 = rank 4
        ld      (tile_y),a
        call    gfx_draw_tile

        ld      a,(bench_asset_page)
        ld      (tile_src_page),a
        ld      a,RING_SLOT
        ld      (tile_src_slot),a
        ld      a,8
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_KEY
        ld      (tile_alias),a
        ld      hl,(scene_dest_base)
        ld      (tile_dest_base),hl
        ld      a,BOARD_X_BYTE+4*CELL_W_BYTES+8 ; col e (4)
        ld      (tile_x_byte),a
        xor     a
        ld      (tile_x_hi),a
        ld      a,BOARD_Y+3*BOARD_CELL_H+8      ; row 3 = rank 5
        ld      (tile_y),a
        jp      gfx_draw_tile

.row: DB 0
.col: DB 0
.bg: DB 0
.x_byte: DB 0
.y: DB 0
.piece_index: DB 0
.piece_page: DB 0

; a-h centred over each file, on the row above the board (the MOVE band's
; freed left half); 1-8 centred on each rank, in the margin left of
; BOARD_X. Both print on the screen background (COORD_COLOR), so unlike
; the in-cell first cut they neither depend on nor disturb the board
; colours -- which also means a theme switch leaves them alone and a piece
; -set switch never has to repaint them. Clobbers everything.
scene_draw_coords:
        xor     a
        ld      (.i),a
.file_loop:
        ld      a,(.i)
        add     a,'a'
        ld      (scene_char_buf),a
        xor     a
        ld      (scene_char_buf+1),a

        ld      a,(.i)
        ld      hl,MUL_CELL_TABLE
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(hl)                  ; col * CELL_W_BYTES
        add     a,BOARD_X_BYTE
        ld      l,a
        ld      h,0
        add     hl,hl                   ; byte column -> pixel x
        ld      de,FILE_X_OFFSET
        add     hl,de
        ld      (.coord_x),hl

        ld      hl,(scene_dest_base)
        ld      de,scene_char_buf
        ld      ix,(.coord_x)
        ld      c,COORD_Y
        ld      a,COORD_COLOR
        call    scene_text

        ld      hl,.i
        inc     (hl)
        ld      a,(hl)
        cp      BOARD_COLS
        jp      c,.file_loop

        xor     a
        ld      (.i),a
.rank_loop:
        ld      a,BOARD_ROWS
        ld      b,a
        ld      a,(.i)
        ld      c,a
        ld      a,b
        sub     c
        add     a,'0'                   ; row 0 -> '8' ... row 7 -> '1'
        ld      (scene_char_buf),a
        xor     a
        ld      (scene_char_buf+1),a

        ld      a,(.i)
        ld      hl,MUL_CELL_TABLE
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(hl)                  ; row * BOARD_CELL_H
        add     a,BOARD_Y
        add     a,RANK_Y_OFFSET
        ld      (.coord_y),a

        ld      hl,(scene_dest_base)
        ld      de,scene_char_buf
        ld      ix,RANK_X
        ld      a,(.coord_y)
        ld      c,a
        ld      a,COORD_COLOR
        call    scene_text

        ld      hl,.i
        inc     (hl)
        ld      a,(hl)
        cp      BOARD_ROWS
        jp      c,.rank_loop
        ret

.i: DB 0
.coord_x: DW 0
.coord_y: DB 0

scene_draw_panel:
        ld      hl,(scene_dest_base)
        ld      de,scene_panel_header_msg
        ld      ix,PANEL_X
        ld      c,PANEL_HEADER_Y+2
        ld      a,1
        call    scene_text

        ld      hl,(scene_dest_base)
        ld      de,scene_panel_moves_msg
        ld      ix,PANEL_X
        ld      c,PANEL_MOVES_Y
        ld      a,1
        call    scene_text

        ld      a,13                    ; hud_muted
        ld      b,PANEL_X/2
        ld      c,PANEL_DIVIDER_Y
        ld      d,PANEL_W/2
        ld      e,PANEL_DIVIDER_H
        ld      hl,(scene_dest_base)
        call    gfx_fill_rect

        ld      hl,(scene_dest_base)
        ld      de,scene_panel_chat_msg
        ld      ix,PANEL_X
        ld      c,PANEL_CHAT_Y
        ld      a,1
        call    scene_text

        ld      hl,(scene_dest_base)
        ld      de,scene_panel_notice_msg
        ld      ix,PANEL_X
        ld      c,PANEL_NOTICE_Y+2
        ld      a,1
        jp      scene_text

scene_panel_header_msg: DB "SHATRANJ",0
scene_panel_moves_msg:  DB "MOVES",0
scene_panel_chat_msg:   DB "CHAT",0
scene_panel_notice_msg: DB "READY",0

; Status bar: full-width fill (two 160-byte gfx_fill_rect passes -- its
; own w_bytes parameter is 8-bit, one pass cannot cover the 320-byte-wide
; screen) plus the current theme's name, printed straight out of
; scene_theme_buf with no copy: the blob's name field is THEME_NAME_LEN
; bytes and tools/gen_sprinter_palette.py caps a name at one byte less, so
; the field is always a NUL-terminated ASCIIZ string in place (a full-width
; name would run this text_print into the record's entry bytes -- hence the
; cap, and the generator's boundary self-test). Also the redraw target for
; scene_theme_next, so a theme switch updates this line without
; repainting anything else.
scene_draw_status:
        ld      a,13
        ld      b,0
        ld      c,STATUS_Y
        ld      d,160
        ld      e,STATUS_H
        ld      hl,(scene_dest_base)
        call    gfx_fill_rect

        ld      a,13
        ld      b,160
        ld      c,STATUS_Y
        ld      d,160
        ld      e,STATUS_H
        ld      hl,(scene_dest_base)
        call    gfx_fill_rect

        call    scene_theme_record_ptr
        push    hl
        pop     de
        ld      hl,(scene_dest_base)
        ld      ix,8
        ld      c,STATUS_Y+2
        ld      a,#D1                   ; bg=13 (hud_muted), fg=1 (text)
        call    scene_text

        ld      hl,(scene_dest_base)
        ld      de,scene_clock_msg
        ld      ix,STATUS_CLOCK_X
        ld      c,STATUS_Y+2
        ld      a,#D1
        jp      scene_text

; The RTC HH:MM the layout puts at the right end of the status bar
; (render_layout.json's STATUS band). A placeholder like every other value
; on this static stand -- what it pins is the slot, so the band is not
; silently half-empty when the layout is reviewed.
scene_clock_msg: DB "--:--",0

scene_draw_theme_name_both:
        ld      hl,#C000
        ld      (scene_dest_base),hl
        call    scene_draw_status
        ld      hl,#C140
        ld      (scene_dest_base),hl
        jp      scene_draw_status

scene_draw_input:
        ld      hl,(scene_dest_base)
        ld      de,scene_input_msg
        ld      ix,8
        ld      c,INPUT_Y+2
        ld      a,1
        jp      scene_text

scene_input_msg: DB "> ",0

; --- text helper -----------------------------------------------------

; DE=text, IX=x, C=y, A=colour(bg<<4|fg), HL=dest_base -- text_print's own
; signature, plus the DI/WIN3=VRAM_ALIAS_OPAQUE bracket text_print itself
; does not provide (it only maps WIN0 for the font; echo_s3.asm's
; echo_draw_notice / ovl_s3.asm's ovl_draw_status established this exact
; pattern). DE/IX/C/HL survive untouched across the bracket setup -- only
; A is clobbered before the call, which is why it is loaded last by every
; caller here. Clobbers AF, BC, DE, HL, IX (text_print's own contract).
scene_text:
        ld      (.color),a
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a
        ld      a,(.color)
        call    text_print
        di                              ; text_print's win0_restore ends with
                                        ; EI, so without this the PORT_Y park
                                        ; and the WIN3 restore below would run
                                        ; with interrupts on and WIN3 still
                                        ; pointing at the VRAM alias. The
                                        ; precedent brackets (echo_s3.asm's
                                        ; echo_draw_notice, net_gate.asm's
                                        ; status line) leave that window open;
                                        ; it is a handful of T-states and has
                                        ; never been observed to bite, but new
                                        ; code should not copy it.
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        ret
.color: DB 0
.saved_win3: DB 0

        ENDIF
