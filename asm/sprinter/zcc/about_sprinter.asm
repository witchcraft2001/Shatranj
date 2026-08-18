; ABOUT overlay (SPECTRUM_OVL_ABOUT = 12u, S9 About pass), page 2 of the
; WIN3 overlay window (tools/make_sprinter_overlay_page.py's LAYOUT2).
;
; WHAT IT DOES. Paints the full-screen About artwork into the back buffer,
; swaps in the artwork's own 16-entry palette, and prints the version
; caption over it. It does NOT wait for a key or restore anything: the
; caller (src/sprinter/session_sprinter.c) owns that, the same way it owns
; every other screen's lifecycle. Exit is a palette restore (video_init)
; plus an ordinary full board repaint.
;
; WHY THERE IS NO MODE SWITCH. port.md originally planned About as mode #81
; (320x256x8bpp, 256 colours). It is drawn in the ordinary #82 mode
; (640x256x4bpp, 16 colours) instead, decided 2026-08-17:
;   - no SetVMod means the "garbage on return to 640" hardware risk, the
;     last open HW item in S9, simply does not exist;
;   - mode #82 pixels are half as wide, so the same physical area is 512x256
;     stored pixels instead of 256x256 -- TWICE the horizontal detail, which
;     visibly offsets the smaller palette on this artwork;
;   - text_print is a 640-only routine (afnt640 lineage, 320-byte row edge),
;     so this mode is the only one where the version caption can be drawn
;     live from VERSION instead of being baked into the picture, which
;     CLAUDE.md rule 5 forbids;
;   - 512x256 at 4bpp is 4 asset pages, one FEWER than mode #81 needed.
; The cost is 16 colours instead of 256: the dark gradients posterise.
;
; WHY IT IS AN OVERLAY AND NOT RESIDENT CODE. All three resident pools were
; full when this was written -- WIN1 8 bytes free, WIN2 40, the WIN3 cold
; page 0. The only unfragmented room left anywhere was page 2's RESERVE2.
;
; WHY THE PICTURE IS BLITTED IN 32 PIECES. The blitter is the RESIDENT
; gfx_draw_tile, reused rather than reimplemented (there was no room to
; reimplement it -- see above). Two consequences shape the loop below:
;   - tile_stride is ONE byte, so a 512-pixel row (256 bytes) cannot be
;     expressed. The image is stored as two 256-pixel halves, 128 bytes per
;     row, and blitted side by side. tools/build_sprinter_about.py's own
;     header describes the page layout that follows from this.
;   - gfx_draw_tile holds DI for its whole call. A whole page in one call
;     would be 16 KiB with interrupts off (~5 ms) and DSS's keyboard FIFO is
;     three bytes deep -- exactly the overrun that cost this port a MAME
;     round in S9's second pass. 16 rows per call is 2 KiB, ~0.6 ms, in the
;     same band .copy_rect and text_print settled on.
;
; This file is plain asm rather than C because every one of those 32 calls
; is just filling the tile_* parameter block, and because the overlay must
; not hand text_print a pointer into its own page (see the caption code).

SECTION code_user

; --- resident bridge (build/sprinter/generated/platform_defs.asm) ---------
    EXTERN about_page0
    EXTERN palette_apply_from
    EXTERN gfx_draw_tile
    EXTERN gfx_blit_rows
    EXTERN flip_mark_dirty_all
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
    EXTERN LOWRAM_OVERLAY_SCRATCH_ADDR

; --- generated data -------------------------------------------------------
    EXTERN about_palette_rgb        ; build_sprinter_about.py, 16 x 3 bytes
    EXTERN sprinter_banner_msg      ; gen_sprinter_version.py --mode z80asm

VRAM_ALIAS_OPAQUE EQU $50           ; dss.inc's own value. Restated (not
                                     ; INCLUDEd) because dss.inc is sjasmplus
                                     ; dialect and this file is z80asm --
                                     ; the same split the atlas table's own
                                     ; hand-shared EQUs live with.

; Geometry. The stored image is 512x256 in a 640x256 screen, centred:
; (640-512)/2 = 64 pixels = 32 bytes of black either side. Each half is 256
; pixels = 128 bytes per row.
ABOUT_MARGIN_BYTES EQU 32
ABOUT_HALF_BYTES   EQU 128
ABOUT_CHUNK_ROWS   EQU 16           ; rows per gfx_draw_tile call (DI budget)
ABOUT_CHUNKS       EQU 8            ; 128 rows per page / 16
ABOUT_CHUNK_SLOTS  EQU 8            ; 16 rows * 128 bytes / 256 bytes per slot
ABOUT_PAGE_ROWS    EQU 128          ; rows of the image held in one page

; Caption. Bottom-left of the picture, clear of the artwork's own centred
; title. X must be even (text_print rejects odd), Y <= 248 (8-row glyph).
ABOUT_TEXT_X       EQU 72
ABOUT_TEXT_Y       EQU 240
ABOUT_CAPTION_BG   EQU 14           ; reserved black (build_sprinter_about.py)
ABOUT_CLEAR_ROWS   EQU 64           ; margin rows per blit call (DI budget)

; LOWRAM_OVERLAY_SCRATCH layout used by this overlay (160 bytes total, and
; documented as belonging to whichever overlay is loaded). Three staging
; areas, because everything the resident render primitives read must live
; outside this overlay's own WIN3 page -- they map VRAM there while running.
ABOUT_SCRATCH_PAL  EQU 0            ; 48 bytes: the artwork palette
ABOUT_SCRATCH_TEXT EQU 48           ; 32 bytes: the version caption
ABOUT_SCRATCH_FILL EQU 80           ; 32 bytes: one row of margin black
ABOUT_TEXT_COLOUR  EQU $EF          ; bg<<4|fg = index 14 on index 15, the
                                     ; two entries build_sprinter_about.py
                                     ; reserves and checks.

; uint8_t about_render_ovl(uint8_t *ctx) __z88dk_fastcall -- ctx unused.
; Returns 0 in L (nothing to report; the caller drives the lifecycle).
    PUBLIC _about_render_ovl
_about_render_ovl:
    ld a,(about_page0)
    cp $FF
    jr z,@no_pages              ; image not published in this build

    call about_clear_margins    ; 512 of 640 columns are picture; the rest
                                 ; would otherwise still show the board and
                                 ; HUD underneath (reported from MAME,
                                 ; 2026-08-17)
    call about_blit_image
    call about_caption
    ; Palette LAST. It is global to both banks, so the instant it changes
    ; the still-displayed front buffer is recoloured too -- doing it here
    ; keeps that to the single frame before the flip, instead of showing a
    ; board painted in the artwork's colours for the whole paint.
    call about_palette_swap
    call flip_mark_dirty_all    ; whole screen changed; say so outright
                                 ; rather than leaning on the flip ring
                                 ; overflowing after 32 logged rects
    ld l,0
    ret
@no_pages:
    ld l,0
    ret

; Blacks out the two 32-byte columns the picture does not cover. The image
; is 512 of the screen's 640 pixels, centred, so 64 pixels either side stay
; whatever the board/HUD left there -- the first MAME run showed the rank
; numbers, the FILE menu and the clock down both margins, framing the
; picture. Filled with palette index 14, the caption background the
; artwork palette reserves as pure black (build_sprinter_about.py).
;
; NOT gfx_fill_rect, even though filling is exactly what this does: that
; routine takes its destination column as ONE byte ("B=x_byte(0-255)") and
; adds it with "ld e,a / ld d,0", so it cannot address the right margin at
; byte 288 at all -- it would silently wrap to byte 32 and paint over the
; picture. (Caught by t_about_blit.asm before it ever reached MAME.)
; gfx_blit_rows takes a 16-bit column (tile_x_byte + tile_x_hi) and, with
; tile_stride = 0, repeats one source row down the whole band -- its own
; header documents that as the intended way to stretch a composed row.
;
; The source row is 32 bytes of #EE (index 14 in both nibbles) staged in
; low RAM: it must NOT be in this overlay's own page, because gfx_blit_rows
; maps VRAM into WIN3 and would read the picture's own bytes instead. Same
; trap the palette and caption staging below avoid.
;
; Chunked 64 rows at a time for the DI budget, like the picture itself:
; 64 x 32 = 2048 bytes per call, the same ~0.6 ms band. Clobbers everything.
about_clear_margins:
    ; stage one row of #EE after the palette (48) and caption (32) areas
    ld hl,LOWRAM_OVERLAY_SCRATCH_ADDR+ABOUT_SCRATCH_FILL
    ld b,ABOUT_MARGIN_BYTES
@stage:
    ld (hl),$EE                 ; two pixels of index 14 per byte
    inc hl
    djnz @stage

    ld a,ABOUT_MARGIN_BYTES
    ld (tile_width),a
    xor a
    ld (tile_stride),a          ; 0 = repeat the one staged row
    ld (tile_x_hi),a
    ld a,ABOUT_CLEAR_ROWS
    ld (tile_rows),a
    ld a,VRAM_ALIAS_OPAQUE
    ld (tile_alias),a
    ld hl,(back_base)
    ld (tile_dest_base),hl

    xor a
    ld (@margin_idx),a
@margin_loop:
    xor a
    ld (@chunk),a
@chunk_loop:
    ; left margin is byte 0; right margin starts where the picture ends
    ld a,(@margin_idx)
    or a
    jr z,@have_x
    ld a,ABOUT_MARGIN_BYTES+ABOUT_HALF_BYTES+ABOUT_HALF_BYTES-256
    ld (tile_x_byte),a          ; 288 = #120: low byte here, high byte below
    ld a,1
    ld (tile_x_hi),a
    jr @x_done
@have_x:
    xor a
    ld (tile_x_byte),a
    ld (tile_x_hi),a
@x_done:
    ld a,(@chunk)
    add a,a
    add a,a
    add a,a
    add a,a
    add a,a
    add a,a                     ; chunk * ABOUT_CLEAR_ROWS (64)
    ld (tile_y),a

    ld hl,LOWRAM_OVERLAY_SCRATCH_ADDR+ABOUT_SCRATCH_FILL
    call gfx_blit_rows

    ld hl,@chunk
    inc (hl)
    ld a,(hl)
    cp 4                        ; 4 x 64 = 256 rows
    jr c,@chunk_loop

    ld hl,@margin_idx
    inc (hl)
    ld a,(hl)
    cp 2
    jr c,@margin_loop
    ret
@margin_idx: defb 0
@chunk:      defb 0

; Copies the artwork palette out of THIS PAGE into low RAM, then asks the
; resident to install it. The copy is not optional: palette_apply_from maps
; VRAM into WIN3 for the duration, which unmaps this overlay -- a pointer
; into about_palette_rgb would be read as VRAM. LOWRAM_OVERLAY_SCRATCH is
; WIN2 (always mapped) and is documented as belonging to whichever overlay
; is currently loaded. Clobbers everything.
about_palette_swap:
    ld hl,about_palette_rgb
    ld de,LOWRAM_OVERLAY_SCRATCH_ADDR+ABOUT_SCRATCH_PAL
    ld bc,48                    ; 16 entries x 3 bytes
    ldir
    ld hl,LOWRAM_OVERLAY_SCRATCH_ADDR+ABOUT_SCRATCH_PAL
    jp palette_apply_from

; Walks the four image pages, 8 chunks of 16 rows each, filling the shared
; tile_* block and calling the resident blitter. Page order is fixed by
; tools/build_sprinter_about.py: pages 0/1 are the LEFT half's rows 0-127
; and 128-255, pages 2/3 the RIGHT half's. So the page index alone gives
; both the destination column (bit 1: left vs right half) and the starting
; row (bit 0: top vs bottom). Clobbers everything.
about_blit_image:
    xor a
    ld (@page_idx),a
@page_loop:
    ; tile_src_page = about_page0[page_idx]
    ld a,(@page_idx)
    ld e,a
    ld d,0
    ld hl,about_page0
    add hl,de
    ld a,(hl)
    ld (tile_src_page),a

    ; x byte = margin + (page_idx >= 2 ? half : 0)
    ld a,(@page_idx)
    and 2
    jr z,@left_half
    ld a,ABOUT_MARGIN_BYTES+ABOUT_HALF_BYTES
    jr @have_x
@left_half:
    ld a,ABOUT_MARGIN_BYTES
@have_x:
    ld (tile_x_byte),a
    xor a
    ld (tile_x_hi),a            ; every column here is < 256

    ; base row = (page_idx & 1) ? 128 : 0
    ld a,(@page_idx)
    and 1
    jr z,@top_rows
    ld a,ABOUT_PAGE_ROWS
    jr @have_row
@top_rows:
    xor a
@have_row:
    ld (@row_base),a

    ; constant for every chunk of this page
    ld hl,(back_base)
    ld (tile_dest_base),hl
    ld a,ABOUT_HALF_BYTES
    ld (tile_width),a
    ld (tile_stride),a
    ld a,ABOUT_CHUNK_ROWS
    ld (tile_rows),a
    ld a,VRAM_ALIAS_OPAQUE
    ld (tile_alias),a

    xor a
    ld (@chunk),a
@chunk_loop:
    ld a,(@chunk)
    add a,a
    add a,a
    add a,a                     ; chunk * ABOUT_CHUNK_SLOTS (8)
    ld (tile_src_slot),a

    ld a,(@chunk)
    add a,a
    add a,a
    add a,a
    add a,a                     ; chunk * ABOUT_CHUNK_ROWS (16)
    ld hl,@row_base
    add a,(hl)
    ld (tile_y),a

    call gfx_draw_tile          ; DI/EI internally, ~0.6 ms per call

    ld hl,@chunk
    inc (hl)
    ld a,(hl)
    cp ABOUT_CHUNKS
    jr c,@chunk_loop

    ld hl,@page_idx
    inc (hl)
    ld a,(hl)
    cp 4
    jr c,@page_loop
    ret
@page_idx: defb 0
@chunk:    defb 0
@row_base: defb 0

; Prints the generated version string over the picture. Same staging reason
; as the palette: text_print's own contract says the string must be in
; resident RAM, "never the WIN0/WIN3 windows", and it maps VRAM into WIN3
; itself. The string is parked after the 48 palette bytes in the same
; scratch region (LOWRAM_OVERLAY_SCRATCH is 160 bytes, so 48 + a short
; version string fits with room to spare). Clobbers everything.
about_caption:
    ld hl,sprinter_banner_msg
    ld de,LOWRAM_OVERLAY_SCRATCH_ADDR+ABOUT_SCRATCH_TEXT
    ld bc,32                    ; generous fixed copy: the generated string
    ldir                         ; is far shorter and NUL-terminated, and a
                                 ; fixed length costs less than a scan

    ld de,LOWRAM_OVERLAY_SCRATCH_ADDR+ABOUT_SCRATCH_TEXT
    ld ix,ABOUT_TEXT_X
    ld c,ABOUT_TEXT_Y
    ld a,ABOUT_TEXT_COLOUR
    ld hl,(back_base)
    jp text_print
