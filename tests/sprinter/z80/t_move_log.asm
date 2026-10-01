; z80 unit test for the move-list ply counter, run against the bytes that
; ship.
;
; WHY THIS EXISTS. On this port the move list's own counter IS the game's
; half-move number: session_sprinter.c numbers the next outgoing MOVE as
; spectrum_gui_log_ply_get() + 1 (src/sprinter/gui_log_sprinter.c's header
; says so outright -- "a second, main.c-local counter would just be the same
; number kept twice, with the two free to drift"). So an off-by-one in what
; looks like a display module is a PROTOCOL fault, and it does not announce
; itself as one.
;
; It shipped exactly that way. spectrum_gui_remove_last_move ignored its
; `ply` argument and read its own counter's parity instead, while the caller
; (main.c's apply_takeback_snapshot) had already rolled that counter back --
; so the parity chosen was the one AFTER the removed move, and the closing
; decrement rolled the same ply back a second time. One takeback left the
; counter one short. The next move then went out at a ply the peer had
; already passed, and by docs/session-core-contract.md the peer must re-ACK
; such a ply WITHOUT applying it (the idempotent-retransmit rule --
; src/common/session/direct_session.c's `ply <= state->current_ply` branch;
; without it a lost ACK would deadlock the retry ladder). The Sprinter
; applied a move on that ACK that the opponent never made, and both sides
; then waited for each other's turn forever. Reported from MAME against a Qt
; host, human tester, 2026-08-20; the only visible clue was a move landing in
; the wrong colour column.
;
; Nothing caught it: the host transcript tests never link this file (it is
; Sprinter-native, replacing ZX's GUI_LOG overlay), the layering and ABI
; gates check shapes rather than arithmetic, and the wire ply is correct
; right up until the first takeback of a game.
;
; WHAT IT DOES. Loads the real WIN1 resident at #4000 and drives the shipped
; spectrum_gui_reset_move_log / _add_move / _remove_last_move /
; _log_ply_get, checking the counter AND which half of which row each move
; landed in, straight out of the move-log low-RAM buffer the renderer reads.
; Both takeback parities are covered -- removing a black half-move and
; removing a white one -- because the shipped bug got both wrong in
; different ways.
;
; No cold page is loaded and none is needed: the render calls leave this file
; through the generated WIN1 thunks, and with cold_win3_page left at #FF
; those are silent no-ops by construction (cold_thunks' own cold_no_page
; guard, matching overlay_loader_sprinter.asm). This test is about the
; bookkeeping, not the pixels.
;
; WHAT IT CANNOT COVER: the panel's scroll edge case (a takeback of the move
; that scrolled a row out cannot bring that row back -- documented and
; accepted in gui_log_sprinter.c, display-only), and that the peer really
; does re-ACK a stale ply (that is the session core's contract, covered by
; the portable transcript tests).

        device  noslot64k
        org     0
        jp      start
        ds      #0100-$,0

        include "harness.inc"
        include "fixed_layout.inc"
        include "resident_test_defs.inc"
        include "platform_test_defs.inc"

; src/spectrum/ui/layout.h's move-log geometry.
MOVE_SLOT_SIZE    EQU 32
MOVE_BLACK_OFFSET EQU 18

; The 5th row (0-based 4) -- where nine half-moves put the ninth.
ROW4 EQU LOWRAM_MOVE_LOG_ADDR + 4*MOVE_SLOT_SIZE

TEST_SP EQU #3F00

start:
        ld      sp,TEST_SP
        call    t_begin

        ; #FF = "no cold page published" -> every render thunk returns
        ; without touching anything. bench_init is what fills this cell on
        ; real boot; a freshly INCBINed resident is already in this state,
        ; but say so rather than depend on it.
        ld      a,#FF
        ld      (plat_cold_win3_page),a

        call    res_spectrum_gui_reset_move_log

        ; --- 1. Nine half-moves: the ninth is white's and claims the white
        ; half of row 4. Establishes the state every assertion below reads.
        ld      b,9
        call    add_moves
        call    res_spectrum_gui_log_ply_get
        ld      de,9
        or      a
        sbc     hl,de
        ld      a,1
        call    t_expect_z
        ld      a,(ROW4)
        cp      'i'                     ; 9th move text is "i9"
        ld      a,2
        call    t_expect_z

        ; --- 2. A tenth: black's, into the same row's black half.
        ld      b,1
        call    add_moves
        ld      a,(ROW4+MOVE_BLACK_OFFSET)
        cp      'j'
        ld      a,3
        call    t_expect_z

        ; --- 3. THE REGRESSION, reproduced as the caller really wrote it.
        ; main.c's apply_takeback_snapshot rolled the counter back ITSELF
        ; (spectrum_gui_log_ply_set(ply - 1)) and then called in, so the
        ; callee saw a counter that no longer matched the move it was being
        ; asked to remove. `ply` is what decides -- the counter must land on
        ; 9 whatever state it was in. The shipped version read the
        ; pre-rolled parity, took the wrong branch, and decremented again to
        ; 8, which is what put the next MOVE on the wire at a ply the
        ; opponent had already played.
        ;
        ; That caller no longer double-rolls, and this asserts it can never
        ; matter again: two writers of one counter is the trap, so the API
        ; is robust to it rather than merely un-tripped for now.
        ld      hl,9
        push    hl
        call    res_spectrum_gui_log_ply_set
        pop     de
        ld      hl,10
        push    hl
        call    res_spectrum_gui_remove_last_move
        pop     de
        call    res_spectrum_gui_log_ply_get
        ld      de,9
        or      a
        sbc     hl,de
        ld      a,4
        call    t_expect_z

        ; --- 4. ...and it must have cleared the BLACK half only. The
        ; shipped version read the wrong parity and wiped the whole row,
        ; taking white's ninth move off the panel with it.
        ld      a,(ROW4)
        cp      'i'
        ld      a,5
        call    t_expect_z
        ld      a,(ROW4+MOVE_BLACK_OFFSET)
        or      a
        ld      a,6
        call    t_expect_z

        ; --- 5. So the next move is ply 10 again, and lands in the black
        ; half -- not the white one, which is where the shipped version put
        ; it, in the opponent's column.
        ld      b,1
        call    add_moves
        call    res_spectrum_gui_log_ply_get
        ld      de,10
        or      a
        sbc     hl,de
        ld      a,7
        call    t_expect_z
        ld      a,(ROW4)
        cp      'i'
        ld      a,8
        call    t_expect_z
        ld      a,(ROW4+MOVE_BLACK_OFFSET)
        or      a
        ld      a,9
        call    t_expect_nz             ; something was written there

        ; --- 6. The other parity: unwind that black ply again, then take
        ; back white's ply 9 -- with the same pre-rolled counter the real
        ; caller used. Now the whole row goes, and the counter is 8. The
        ; shipped version mishandled this direction too: it read the even
        ; parity, cleared an already-empty black half, and left white's move
        ; on screen with the counter one short.
        ld      hl,10
        push    hl
        call    res_spectrum_gui_remove_last_move
        pop     de
        ld      hl,8
        push    hl
        call    res_spectrum_gui_log_ply_set
        pop     de
        ld      hl,9
        push    hl
        call    res_spectrum_gui_remove_last_move
        pop     de
        call    res_spectrum_gui_log_ply_get
        ld      de,8
        or      a
        sbc     hl,de
        ld      a,10
        call    t_expect_z
        ld      a,(ROW4)
        or      a
        ld      a,11
        call    t_expect_z              ; row 4 is gone entirely

        ; --- 7. And the row is reusable: the next move is white's ply 9
        ; and claims row 4's white half again.
        ld      b,1
        call    add_moves
        call    res_spectrum_gui_log_ply_get
        ld      de,9
        or      a
        sbc     hl,de
        ld      a,12
        call    t_expect_z
        ld      a,(ROW4)
        or      a
        ld      a,13
        call    t_expect_nz

        call    t_end
        halt

; Appends B moves, taking the next text from move_ptr: "a1", "b2", ... The
; first character is unique per call so an assertion can name which move it
; is looking at. z88dk classic convention: arguments pushed left to right,
; caller cleans up (same as t_net_mqtt_read.asm, which confirmed it by
; reading a compiled call site).
add_moves:
        ld      a,b
        or      a
        ret     z
.loop:  push    bc
        ld      hl,empty_ply
        push    hl
        ld      hl,(move_ptr)
        push    hl
        call    res_spectrum_gui_add_move
        pop     de
        pop     de
        ld      hl,(move_ptr)
        ld      de,3
        add     hl,de
        ld      (move_ptr),hl
        pop     bc
        djnz    .loop
        ret

move_ptr:  dw move_texts
empty_ply: db 0
; Three bytes each (two characters and a terminator), so add_moves can step
; through them with a fixed stride.
move_texts:
        db "a1",0, "b2",0, "c3",0, "d4",0, "e5",0
        db "f6",0, "g7",0, "h8",0, "i9",0, "j0",0
        db "k1",0, "l2",0, "m3",0, "n4",0, "o5",0

; The real WIN1 resident (#4000-#BFFF): gui_log_sprinter.c's compiled
; backend, the render thunks it calls, and the move-log buffer at #B000.
; Padded with "ds", not "org" -- --raw writes a flat file from address 0 and
; an "org" jump would leave the gap unwritten (t_menu_flip.asm's own note).
        ds      #4000-$,0
        incbin  "resident.bin"
