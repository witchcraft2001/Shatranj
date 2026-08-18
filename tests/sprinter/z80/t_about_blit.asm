; z80 unit test for the S9 About screen, run against the bytes that ship.
;
; WHY THIS EXISTS. The About screen paints a 512x256 picture out of four
; asset pages using the RESIDENT gfx_draw_tile, 16 rows at a time, 32 calls
; in all (asm/sprinter/zcc/about_sprinter.asm explains why it is chopped up
; like that). Every one of those calls is a hand-filled tile_* parameter
; block, and this port has already lost several MAME rounds to exactly that
; kind of code: a hint marker sourced slot 8 instead of 50 for three
; successive builds because nothing checked what the blitter was actually
; handed (see t_hint_blit.asm's own header). So the overlay is INCBINned at
; its real ORG, the four resident routines it calls are stubbed, and every
; blit request is recorded and checked.
;
; What it proves: the 32 requests together cover the destination rectangle
; exactly once -- 128 bytes x 16 rows each, left half at byte 32 and right
; half at byte 160, rows 0..255 -- with the right source page and slot for
; every one, and that the palette swap, the caption and the whole-screen
; invalidation each happen exactly once.
;
; What it canNOT prove: that the accelerator then puts the right pixels on
; a real screen (unverifiable outside MAME/hardware, the same caveat
; t_draw_tile.asm carries).

        device  noslot64k
        org     0
        jp      start
        ds      #0100-$,0

        include "harness.inc"
        include "coldrender_test_defs.inc"

; The ABOUT slot's link address (tools/make_sprinter_overlay_page.py's
; LAYOUT2). The INCBIN below places the overlay here, so if this and the
; link ORG ever disagree the overlay's own absolute jumps land nowhere and
; the assertions fail loudly rather than silently testing the wrong bytes.
ABOUT_ORG       EQU #F000

EXPECT_CALLS    EQU 32
EXPECT_WIDTH    EQU 128
EXPECT_ROWS     EQU 16
EXPECT_X_LEFT   EQU 32
EXPECT_X_RIGHT  EQU 160
ALIAS_OPAQUE    EQU #50

; Scratch, clear of both the harness and the overlay.
LOG      EQU #A000        ; 4 bytes per recorded call: page, slot, x, y
LOGCNT   EQU #9F00
PALCNT   EQU #9F01
TXTCNT   EQU #9F02
DIRTYCNT EQU #9F03
LOGPTR   EQU #9F04
WALKIDX  EQU #9F06
FILLCNT  EQU #9F07
FILLLOG  EQU #9F10        ; 8 bytes per margin blit: x_lo,x_hi,y,rows,w,stride

start:
        ld      sp,#7000
        call    t_begin

        ; Four distinct page numbers, so the log shows which page was used
        ; for which part of the screen rather than just "some page".
        ld      a,#40
        ld      (about_page0),a
        ld      a,#41
        ld      (about_page0+1),a
        ld      a,#42
        ld      (about_page0+2),a
        ld      a,#43
        ld      (about_page0+3),a

        ld      hl,#C000
        ld      (back_base),hl

        xor     a
        ld      (LOGCNT),a
        ld      (PALCNT),a
        ld      (TXTCNT),a
        ld      (DIRTYCNT),a
        ld      (FILLCNT),a
        ld      hl,LOG
        ld      (LOGPTR),hl

        ; Stub the resident routines the overlay reaches through the
        ; platform bridge. They live in WIN1/WIN2, which this harness does
        ; not load, so each gets a JP to a recorder planted at its address.
        ld      a,#C3
        ld      (gfx_draw_tile),a
        ld      hl,rec_blit
        ld      (gfx_draw_tile+1),hl
        ld      a,#C3
        ld      (palette_apply_from),a
        ld      hl,rec_pal
        ld      (palette_apply_from+1),hl
        ld      a,#C3
        ld      (text_print),a
        ld      hl,rec_txt
        ld      (text_print+1),hl
        ld      a,#C3
        ld      (flip_mark_dirty_all),a
        ld      hl,rec_dirty
        ld      (flip_mark_dirty_all+1),hl
        ld      a,#C3
        ld      (gfx_blit_rows),a
        ld      hl,rec_fill
        ld      (gfx_blit_rows+1),hl

        ; Dispatch through the overlay's own entry table (count byte, then
        ; one address per entry) rather than jumping at a hardcoded offset,
        ; so a change to the table's shape is caught here too.
        ld      a,(ABOUT_ORG)
        cp      1
        ld      a,1
        call    t_expect_z              ; exactly one entry (ABOUT_RENDER)
        ld      hl,(ABOUT_ORG+1)
        call    call_hl

        ; --- 1. The picture was requested in exactly 32 pieces.
        ld      a,(LOGCNT)
        cp      EXPECT_CALLS
        ld      a,2
        call    t_expect_z

        ; --- 2. Palette swap, caption and invalidation happen once each.
        ld      a,(PALCNT)
        cp      1
        ld      a,3
        call    t_expect_z
        ld      a,(TXTCNT)
        cp      1
        ld      a,4
        call    t_expect_z
        ld      a,(DIRTYCNT)
        cp      1
        ld      a,5
        call    t_expect_z

        ; --- 2b. The two uncovered margins are blacked out. The picture is
        ; 512 of 640 columns, so 32 bytes either side would otherwise still
        ; show the board and HUD underneath (MAME, 2026-08-17).
        ;
        ; This is the assertion that caught a real bug before MAME did: the
        ; first version used gfx_fill_rect, whose destination column is a
        ; single byte, so the right margin at byte 288 wrapped to 32 and
        ; painted over the picture. gfx_blit_rows takes a 16-bit column.
        ld      a,(FILLCNT)
        cp      8                       ; 2 margins x 4 chunks of 64 rows
        ld      a,14
        call    t_expect_z

        ; Chunks 0-3 are the LEFT margin: column 0, high byte 0.
        ld      a,(FILLLOG+0)           ; x low
        or      a
        ld      a,15
        call    t_expect_z
        ld      a,(FILLLOG+1)           ; x high
        or      a
        ld      a,16
        call    t_expect_z

        ; Chunks 4-7 are the RIGHT margin: byte 288 = #0120, so low #20
        ; and high #01. A one-byte column cannot express this at all.
        ld      a,(FILLLOG+32+0)
        cp      #20
        ld      a,17
        call    t_expect_z
        ld      a,(FILLLOG+32+1)
        cp      #01
        ld      a,18
        call    t_expect_z

        ; Every margin blit: 32 bytes wide, 64 rows, stride 0 (one staged
        ; row repeated -- the documented way to stretch a fill). Recorded
        ; per call, not read back at the end: the picture blit runs after
        ; these and leaves its own 128/128 in the shared cells.
        ld      hl,FILLLOG+4
        ld      b,8
.fillchk:
        ld      a,(hl)                  ; width
        cp      32
        ld      a,19
        push    bc
        push    hl
        call    t_expect_z
        pop     hl
        pop     bc
        inc     hl
        ld      a,(hl)                  ; stride
        or      a
        ld      a,20
        push    bc
        push    hl
        call    t_expect_z
        pop     hl
        pop     bc
        ; advance to the next entry's width field
        ld      de,7
        add     hl,de
        djnz    .fillchk

        ; --- 3. The constant half of the parameter block.
        ld      a,(tile_width)
        cp      EXPECT_WIDTH
        ld      a,6
        call    t_expect_z
        ld      a,(tile_stride)
        cp      EXPECT_WIDTH            ; tightly packed rows: stride = width
        ld      a,7
        call    t_expect_z
        ld      a,(tile_rows)
        cp      EXPECT_ROWS
        ld      a,8
        call    t_expect_z
        ld      a,(tile_alias)
        cp      ALIAS_OPAQUE            ; NOT the #FF transparency key: a
        ld      a,9                      ; keyed blit would punch holes
        call    t_expect_z               ; wherever the art used index 15

        ; --- 4. Walk the log: entry N must be page (N/8), slot (N%8)*8,
        ; x by half, y by position. This is the whole point of the test --
        ; it pins the exact rectangle every call writes.
        xor     a
        ld      (WALKIDX),a
.walk:
        ld      a,(WALKIDX)
        add     a,a
        add     a,a                     ; index*4 = log offset
        ld      e,a
        ld      d,0
        ld      hl,LOG
        add     hl,de                   ; HL -> this entry

        ; page must be #40 + (idx >> 3)
        ld      a,(WALKIDX)
        rrca
        rrca
        rrca
        and     3
        add     a,#40
        cp      (hl)
        ld      a,10
        call    t_expect_z

        ; slot must be (idx & 7) * 8
        inc     hl
        ld      a,(WALKIDX)
        and     7
        add     a,a
        add     a,a
        add     a,a
        cp      (hl)
        ld      a,11
        call    t_expect_z

        ; x must be 32 for pages 0/1 (idx < 16), 160 for pages 2/3
        inc     hl
        ld      a,(WALKIDX)
        cp      16
        jr      nc,.right_half
        ld      a,EXPECT_X_LEFT
        jr      .have_x
.right_half:
        ld      a,EXPECT_X_RIGHT
.have_x:
        cp      (hl)
        ld      a,12
        call    t_expect_z

        ; y must be (idx & 15) * 16 -- each half walks rows 0..255 itself
        inc     hl
        ld      a,(WALKIDX)
        and     15
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        cp      (hl)
        ld      a,13
        call    t_expect_z

        ld      a,(WALKIDX)
        inc     a
        ld      (WALKIDX),a
        cp      EXPECT_CALLS
        jr      c,.walk

        call    t_end
        halt

call_hl:
        jp      (hl)

; --- recorders ------------------------------------------------------------
; Each stands in for a resident routine. Only AF/HL/DE are touched and all
; are saved: the overlay's own loop keeps live state in memory, but a
; recorder that quietly clobbered a register would turn a passing test into
; a lie about code that works only because it was stubbed.
rec_blit:
        push    af
        push    hl
        push    de
        ld      hl,(LOGPTR)
        ld      a,(tile_src_page)
        ld      (hl),a
        inc     hl
        ld      a,(tile_src_slot)
        ld      (hl),a
        inc     hl
        ld      a,(tile_x_byte)
        ld      (hl),a
        inc     hl
        ld      a,(tile_y)
        ld      (hl),a
        inc     hl
        ld      (LOGPTR),hl
        ld      hl,LOGCNT
        inc     (hl)
        pop     de
        pop     hl
        pop     af
        ret

rec_pal:
        push    hl
        ld      hl,PALCNT
        inc     (hl)
        pop     hl
        ret

rec_txt:
        push    hl
        ld      hl,TXTCNT
        inc     (hl)
        pop     hl
        ret

rec_dirty:
        push    hl
        ld      hl,DIRTYCNT
        inc     (hl)
        pop     hl
        ret

; Stands in for gfx_blit_rows (HL = source; everything else in tile_*).
; Records the destination column as a 16-bit value plus the row and count,
; four bytes per call.
rec_fill:
        push    af
        push    hl
        push    de
        ld      a,(FILLCNT)
        add     a,a
        add     a,a
        add     a,a                     ; 8 bytes per entry
        ld      e,a
        ld      d,0
        ld      hl,FILLLOG
        add     hl,de
        ld      a,(tile_x_byte)
        ld      (hl),a
        inc     hl
        ld      a,(tile_x_hi)
        ld      (hl),a
        inc     hl
        ld      a,(tile_y)
        ld      (hl),a
        inc     hl
        ld      a,(tile_rows)
        ld      (hl),a
        inc     hl
        ld      a,(tile_width)
        ld      (hl),a
        inc     hl
        ld      a,(tile_stride)
        ld      (hl),a
        ld      hl,FILLCNT
        inc     (hl)
        pop     de
        pop     hl
        pop     af
        ret

; The shipped overlay at its real load address. Padded with "ds", not
; "org": --raw writes a flat file from 0 and an "org" jump would leave the
; gap unwritten (the same trap t_hint_blit.asm and t_net_frame_blob.asm
; document).
        ds      ABOUT_ORG-$,0
        incbin  "overlay_about_sprinter.bin"
