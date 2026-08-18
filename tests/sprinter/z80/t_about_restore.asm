; z80 unit test for the post-About SCREEN REBUILD, run against the bytes that
; actually ship.
;
; WHY THIS EXISTS. Dismissing the About screen has now failed two MAME rounds
; in a row, both times for the same reason and never for a reason reading the
; source made obvious:
;
;   round 1 (2026-08-17): the board and the HUD came back correct, framed by
;   leftover artwork -- nothing had pixel-cleared the screen at all, and every
;   render_*() in the restore paints only its own box or cell;
;   round 2 (same day): the clear was there, and the rebuild came back missing
;   the move list, the chat log, the notice line, the clock and the turn label
;   -- every field that is repainted from state the WIN1 resident cannot see.
;
; What both have in common is that they are failures of a SEQUENCE, not of any
; one routine: each painter works, the caller just does not call it. Nothing
; static catches that (a missing call is not a link error, and there is no
; portable judge for a screen rebuild -- this is the platform-specific adapter
; layer), and MAME catches it one field at a time, one round-trip apiece.
;
; So: INCBIN build/sprinter/cold_win3_page.bin at its real ORG (#C000),
; replace every paint the rebuild is supposed to reach with a recorder that
; logs an id and returns, CALL about_restore_screen at the address its own
; .map reports (tools/gen_sprinter_coldrender_defs.py), and assert the call
; log. The code under test is byte-identical to the code in SHATRANJ.EXE.
;
; What this canNOT cover: whether those painters then put the right pixels on
; screen (unverifiable outside MAME/hardware, same caveat t_hint_blit.asm and
; t_about_blit.asm carry). It covers which paints happen and in what order,
; which is where both failures so far have actually lived.

        device  noslot64k
        org     0
        jp      start
        ds      #0100-$,0

        include "harness.inc"
        include "fixed_layout.inc"
        include "platform_test_defs.inc"
        include "coldrender_test_defs.inc"

; --- recorder ids ----------------------------------------------------------
; One per paint the rebuild must reach. Numbered in the order about_restore_
; screen issues them, so a log dump reads as a sequence at a glance.
ID_CLEAR        EQU 1       ; video_clear_both_buffers   (the pixel clear)
ID_VINIT        EQU 2       ; video_init                 (the theme palette)
ID_BOARD        EQU 3       ; spectrum_gui_restore_board_area
ID_COORDS       EQU 4       ; render_coord_labels
ID_BANNER       EQU 5       ; render_banner
ID_MENUBAR      EQU 6       ; render_menu_bar
ID_STATUS_TEXT  EQU 7       ; render_status_text  (placeholder + key hints)
ID_INPUT        EQU 8       ; render_input_line
ID_PANEL        EQU 9       ; spectrum_info_show_game    (panel chrome)
ID_MOVES        EQU 10      ; spectrum_render_moves      (move list)
ID_CHAT         EQU 11      ; spectrum_render_chat       (chat log)
ID_CLOCK        EQU 12      ; spectrum_render_clock      (wall clock)
ID_TIMER        EQU 13      ; spectrum_render_game_timer_clear (GAME/TURN)
ID_CONN         EQU 14      ; spectrum_gui_set_connected (link indicator)
ID_NOTICE       EQU 15      ; spectrum_render_notice     (notice line)
ID_STATUS_LIVE  EQU 16      ; net_status_idle            (live status text)
ID_TURN         EQU 17      ; spectrum_gui_set_turn_label
ID_LAST         EQU 17

LOG             EQU #B800   ; call log, one id per entry, clear of everything

start:
        ld      sp,#7000

        ; harness.inc's four status cells (#F000-#F003) sit INSIDE the cold
        ; page this test loads at #C000 -- right on top of render_board_full's
        ; row loop (#EFF9). t_begin zeroes them, so stash the page's own bytes
        ; first, put them back for the run, and re-zero afterwards for the
        ; assertion phase. Nothing reached below actually executes there (the
        ; board paint is one of the recorded stubs), but a test that silently
        ; corrupts the image it is testing is not worth the four bytes saved.
        ld      hl,TEST_RESULT
        ld      de,saved_cells
        ld      bc,4
        ldir
        call    t_begin
        ld      hl,saved_cells
        ld      de,TEST_RESULT
        ld      bc,4
        ldir

        call    patch_all

        ; State the About screen actually leaves behind, plus the one path
        ; through gui.c this run is meant to take.
        ld      a,2                     ; spectrum_gui_show_fileui's own value
        ld      (_about_visible),a
        xor     a
        ld      (_net_active),a         ; hot seat -> the net_status_idle arm
        ld      (_menu_visible),a       ; closed -> the plain timer painter
        ld      (_notice_error),a
        ld      (_notice_success),a     ; -> the plain notice painter

        ld      hl,LOG
        ld      (log_ptr),hl
        xor     a
        ld      (log_count),a

        call    _about_restore_screen

        call    t_begin                 ; re-arm the harness cells

        ; --- 1/2. The clear comes FIRST, and the palette straight after it.
        ; Round 1's defect is exactly "no ID_CLEAR at all"; the order matters
        ; too, since swapping the two displays the artwork through the theme
        ; palette for a frame (colour noise, not black).
        ld      a,(LOG+0)
        cp      ID_CLEAR
        ld      a,1
        call    t_expect_z
        ld      a,(LOG+1)
        cp      ID_VINIT
        ld      a,2
        call    t_expect_z

        ; --- 3..19. Every paint in the contract happened. This is round 2's
        ; defect: a rebuild that clears the screen and then leaves five fields
        ; blank is worse than one that leaves the artwork up.
        ld      a,ID_BOARD
        ld      b,3
        call    require_id
        ld      a,ID_COORDS
        ld      b,4
        call    require_id
        ld      a,ID_BANNER
        ld      b,5
        call    require_id
        ld      a,ID_MENUBAR
        ld      b,6
        call    require_id
        ld      a,ID_STATUS_TEXT
        ld      b,7
        call    require_id
        ld      a,ID_INPUT
        ld      b,8
        call    require_id
        ld      a,ID_PANEL
        ld      b,9
        call    require_id
        ld      a,ID_MOVES
        ld      b,10
        call    require_id
        ld      a,ID_CHAT
        ld      b,11
        call    require_id
        ld      a,ID_CLOCK
        ld      b,12
        call    require_id
        ld      a,ID_TIMER
        ld      b,13
        call    require_id
        ld      a,ID_CONN
        ld      b,14
        call    require_id
        ld      a,ID_NOTICE
        ld      b,15
        call    require_id
        ld      a,ID_STATUS_LIVE
        ld      b,16
        call    require_id
        ld      a,ID_TURN
        ld      b,17
        call    require_id

        ; --- 20. render_status_text paints the boot-time "NO SESSION"
        ; placeholder into the very cell the live status goes in, so it has to
        ; come FIRST or a networked game comes back from About claiming it has
        ; no session.
        ld      a,ID_STATUS_TEXT
        call    find_id
        ld      a,b
        ld      (pos_a),a
        ld      a,ID_STATUS_LIVE
        call    find_id
        ld      a,(pos_a)
        cp      b                       ; placeholder position < live position
        ld      a,20
        call    t_expect_c

        ; --- 21. The modal gate is down afterwards. render_clock_only and
        ; render_game_timer_only return early while it is up, so leaving it
        ; set would silently freeze the clock and the GAME/TURN line for the
        ; rest of the session -- and assertions 12/13 above only prove the
        ; gate was down BY the time the rebuild reached them.
        ld      a,(_about_visible)
        or      a
        ld      a,21
        call    t_expect_z

        call    t_end
        halt

; A = id, B = assertion id. Fails the assertion when the id never appeared.
require_id:
        ld      c,b
        call    find_id
        ld      a,b
        or      a
        ld      a,c
        call    t_expect_nz
        ret

; A = id -> B = 1-based position in the log, 0 when absent. Clobbers AF,BC,DE,HL.
find_id:
        ld      c,a
        ld      b,0
        ld      a,(log_count)
        or      a
        ret     z
        ld      d,a
        ld      e,1
        ld      hl,LOG
.loop:
        ld      a,(hl)
        cp      c
        jr      z,.found
        inc     hl
        inc     e
        dec     d
        jr      nz,.loop
        ret                             ; B still 0
.found:
        ld      b,e
        ret

; Rewrites the first three bytes of each painter with a jump to its recorder.
; Table is address pairs, terminated by a zero target.
patch_all:
        ld      hl,patch_table
.loop:
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      a,d
        or      e
        ret     z
        ld      a,#C3                   ; JP nn
        ld      (de),a
        inc     de
        ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     de
        ld      a,(hl)
        ld      (de),a
        inc     hl
        jr      .loop

; Logs A's id and returns, in place of a painter. Every one of the intercepted
; entries returns void and takes its argument in HL (__z88dk_fastcall) or none
; at all, so clobbering nothing but the log is a faithful stand-in.
        MACRO RECORDER id?
        push    af
        push    hl
        ld      hl,(log_ptr)
        ld      (hl),id?
        inc     hl
        ld      (log_ptr),hl
        ld      hl,log_count
        inc     (hl)
        pop     hl
        pop     af
        ret
        ENDM

rec_clear:          RECORDER ID_CLEAR
rec_vinit:          RECORDER ID_VINIT
rec_board:          RECORDER ID_BOARD
rec_coords:         RECORDER ID_COORDS
rec_banner:         RECORDER ID_BANNER
rec_menubar:        RECORDER ID_MENUBAR
rec_status_text:    RECORDER ID_STATUS_TEXT
rec_input:          RECORDER ID_INPUT
rec_panel:          RECORDER ID_PANEL
rec_moves:          RECORDER ID_MOVES
rec_chat:           RECORDER ID_CHAT
rec_clock:          RECORDER ID_CLOCK
rec_timer:          RECORDER ID_TIMER
rec_conn:           RECORDER ID_CONN
rec_notice:         RECORDER ID_NOTICE
rec_status_live:    RECORDER ID_STATUS_LIVE
rec_turn:           RECORDER ID_TURN

patch_table:
        dw      video_clear_both_buffers,         rec_clear
        dw      _video_init,                      rec_vinit
        dw      _spectrum_gui_restore_board_area, rec_board
        dw      _render_coord_labels,             rec_coords
        dw      render_banner,                    rec_banner
        dw      render_menu_bar,                  rec_menubar
        dw      render_status_text,               rec_status_text
        dw      render_input_line,                rec_input
        dw      _spectrum_info_show_game,         rec_panel
        dw      _spectrum_render_moves,           rec_moves
        dw      _spectrum_render_chat,            rec_chat
        dw      _spectrum_render_clock,           rec_clock
        dw      _spectrum_render_game_timer_clear, rec_timer
        dw      _spectrum_gui_set_connected,      rec_conn
        dw      _spectrum_render_notice,          rec_notice
        dw      _net_status_idle,                 rec_status_live
        dw      _spectrum_gui_set_turn_label,     rec_turn
        dw      0

log_ptr:        dw 0
log_count:      db 0
pos_a:          db 0
saved_cells:    ds 4,0

; The real cold page at its real load address. Padded with "ds", not "org":
; --raw writes a flat file from address 0, and an "org" jump leaves the gap
; UNWRITTEN, so the page would never land at #C000 in the emulated image
; (t_hint_blit.asm and t_net_frame_blob.asm pad the same way for the same
; reason).
        ds      #C000-$,0
        incbin  "cold_win3_page.bin"
