; IM2 interrupt chain support for the S1 platform stand (port.md section
; 3.9, rules R4/R6/R11). Position-independent routines and data, INCLUDEd
; once from resident_s1.asm's flexible code area. The fixed-position 15-
; byte stub itself (IM2_STUB_ADDR) is NOT here: it lives inline in
; resident_s1.asm right at that anchor, since it is tiny, single-use, and
; tightly coupled to the exact address gen_sprinter_layout.py derives from
; im2.fill_byte -- pulling it into this file would need a second, fixed-
; position INCLUDE of the same file, which is more complex than just
; writing 8 lines inline.
;
; S1_TEST_HOOK: tests/sprinter/z80/t_frame_wait.asm assembles this file
; with -DS1_TEST_HOOK, replacing the HALT in frame_wait's retry loop with a
; call to a test-supplied s1_test_mock_interrupt routine (the test controls
; exactly which call sets frame_flag, simulating "the ISR fired on this
; wait"). Production builds get a plain HALT.
;
; STANDING INVARIANT (S3+ must preserve): while IM2 is installed, the
; vector table and stub live in the WIN2 half (#BDBD/#BE00). Nothing may
; remap WIN2 with interrupts enabled -- a vector fetch through a foreign
; page jumps to garbage. Today every WIN2-affecting path runs under DI
; (svmod_safe callers, exit after im2_uninstall); any future DSS/BIOS
; gateway that can remap SLOT2 with EI must DI around the call or
; uninstall IM2 first.

        IFNDEF SPRINTER_IM2_S1_INC
        DEFINE SPRINTER_IM2_S1_INC

        INCLUDE "dss.inc"
        INCLUDE "fixed_layout.inc"
        INCLUDE "hdr.inc"

FRAME_WAIT_TIMEOUT EQU 256

        IFDEF S1_TEST_HOOK
        MACRO S1_WAIT_STEP
        call    s1_test_mock_interrupt
        ENDM
        ELSE
        MACRO S1_WAIT_STEP
        halt
        ENDM
        ENDIF

; Fill IM2_TABLE_ADDR..+IM2_TABLE_SIZE with IM2_FILL_BYTE. The static image
; (resident_s1.asm) already has these bytes assembled in place; this is
; belt-and-suspenders re-establishment at boot and the routine
; tests/sprinter/z80/t_im2_table.asm exercises directly. Idempotent.
im2_fill_table:
        ld      hl,IM2_TABLE_ADDR
        ld      (hl),IM2_FILL_BYTE
        ld      de,IM2_TABLE_ADDR+1
        ld      bc,IM2_TABLE_SIZE-1
        ldir
        ret

; Install IM2 (R6): fill the table, clear frame_flag, point I at the table,
; switch mode. Self-contained DI/EI (2026-08-10, S5 substep 3 crash
; investigation): originally documented as "must run under DI; caller EIs
; afterward" with no caller actually doing so -- main.c's plain
; im2_install() call ran it fully under EI, the only caller there has ever
; been. The fixed instruction order here (fill the table completely, THEN
; point I at it, THEN switch mode) happens to make every individual step
; interrupt-safe on its own, so this was not confirmed as the render_
; board_full crash's mechanism, but it is a real, verifiable gap between
; the documented contract and what ran, worth closing outright rather than
; leaving the single call site to keep getting it wrong by inspection.
; Saves the previous I register for im2_uninstall (R11).
im2_install:
        di
        call    im2_fill_table
        xor     a
        ld      (frame_flag),a
        ld      a,i
        ld      (im2_saved_i),a
        ld      a,high IM2_TABLE_ADDR
        ld      i,a
        im      2
        ei
        ret

; Restore IM 1 and the previous I register (R11). Must run under DI.
im2_uninstall:
        ld      a,(im2_saved_i)
        ld      i,a
        im      1
        ret

; Fatal screen: canary corrupted (R4). Does not return. Uninstalls IM2
; first: DSS_EXIT frees the resident pages, and leaving I pointed at the
; soon-to-be-freed IM2 table would turn the next interrupt into a jump
; through whatever page gets mapped there later.
fatal_stack_overflow:
        di
        call    im2_uninstall
        ld      b,0
        ld      a,DSS_VMOD_T40
        call    svmod_safe              ; WIN2-half wrapper: SetVMod clobbers
                                         ; the WIN1 mapping and this code IS
                                         ; WIN1-half (see resident_s1.asm)
        ld      hl,fatal_msg_stack
        ld      c,DSS_PCHARS
        rst     RST_DSS
        ld      b,1
        ld      c,DSS_EXIT
        rst     RST_DSS
.hang:  jr      .hang

; Z if the stack canary is intact, else jumps to fatal_stack_overflow and
; does not return. Call from frame_wait and (S3+) from net/libman gateways.
; Clobbers AF, HL, DE.
canary_check:
        ld      hl,(CANARY_ADDR)
        ld      de,CANARY_SENTINEL
        or      a
        sbc     hl,de
        ret     z
        jp      fatal_stack_overflow

; Wait for the next frame tick (IM2 stub sets frame_flag). NC on success
; (a frame occurred), CF on timeout after FRAME_WAIT_TIMEOUT waits. Checks
; the canary first. Clobbers AF, B.
;
; HALT only wakes on an interrupt: if interrupts are somehow fully dead,
; the timeout itself never resolves either. This is a deliberate, documented
; limitation (port.md section 3.9) -- on the live system keyboard IRQs alone
; wake it well within the timeout even during a frame-tick gap.
;
; S5-finish plan D11 (buffer flip): if render_core.asm has logged any
; unflushed paint since the last flip (buffers.asm's flip_ring_count/
; flip_dirty_all), request a flip before waiting -- DI-set flip_request,
; the same cell im2_frame_isr's tail reads. The ISR runs to completion
; (set frame_flag, act on flip_request, clear it) before HALT ever returns
; control here, so by the time .got_frame is reached the ISR that set
; frame_flag has already either consumed our request or not seen one --
; no separate race window exists between "woke up" and "checked
; flip_request" to close (unlike a preemptive OS), this DI block is
; defensive symmetry with every other flip_request access, not a fix for
; an observed race. Only calls resolve_buffers/flip_sync when THIS call
; actually asked for a flip (@requested) and the request was consumed
; (flip_request now 0): a timeout leaves flip_request set and the ring
; untouched, so the next frame_wait call re-requests the same pending
; paint instead of silently dropping it.
frame_wait:
        call    canary_check

        xor     a
        ld      (@requested),a
        ld      a,(flip_ring_count)
        or      a
        jr      nz,@do_request
        ld      a,(flip_dirty_all)
        or      a
        jr      z,@wait
@do_request:
        di
        ld      a,1
        ld      (flip_request),a
        ei
        ld      a,1
        ld      (@requested),a
@wait:
        ld      b,0                     ; DJNZ over 256: 0 wraps to 255 first
.wait_loop:
        di
        xor     a
        ld      (frame_flag),a
        ei
        S1_WAIT_STEP
        ld      a,(frame_flag)
        or      a
        jr      nz,.got_frame
        djnz    .wait_loop
        scf
        ret
.got_frame:
        ld      a,(@requested)
        or      a
        jr      z,.done
        di
        ld      a,(flip_request)
        ei
        or      a
        jr      nz,.done                ; not consumed this tick -- retry
                                         ; on the next frame_wait call
        call    resolve_buffers
        call    flip_sync
.done:
        or      a
        ret
@requested: DB 0

; Non-blocking keyboard poll, translating DSS's raw keyboard-buffer output
; into this port's own semantic key codes (the same convention ZX/Next's
; spectrum_input_poll_event contract already uses -- src/spectrum/ui/
; gui.h/gui.c, asm/spectrum/screen.asm: 0x81/0x82/0x83/0x84 = up/down/
; left/right, 0x8A = CANCEL, 0x08 = backspace, 0x20-0x7E = printable
; ASCII passthrough, 0x90 = SPECTRUM_GUI_KEY_MENU), so a future real input
; handler can share that contract instead of inventing a Sprinter-specific
; one. 0x90 is this port's own addition (S5-finish plan D12): ZX's own
; MENU key is a specific physical Spectrum key this port's PS/2 mapping
; has no equivalent for, so TAB (raw ASCII 9, otherwise unclaimed) is
; mapped to it instead -- everything else in this table is a cross-checked
; ZX/Next convention, this one line is not. The DSS side of
; this (TESTKEY-peek-then-SCANKEY, and reading D as a positional scan
; code when A/ascii is 0) recovers the approach the previous, since-
; restarted Sprinter port attempt already worked out (runtime.asm's
; sprinter_key_poll, branch sprinter-port commit 59d158e -- CLAUDE.md's
; "old branch reference-only" applies to that branch's architecture, not
; to this specific, independently-checkable DSS API fact) -- cross-
; checked against Estex-DSS's own KEYINTER.ASM XLAT_T table rather than
; trusted as-is: raw PS/2 Set-2 scancode 0x75 (Up) translates to
; positional #58, 0x72 (Down) to #52, 0x6B (Left) to #54, 0x74 (Right) to
; #56 -- exactly the four positional values used below, confirmed against
; DSS's own scancode-translation table, not just the old branch's say-so.
;
; Uses DSS_TESTKEY (non-destructive peek) before DSS_SCANKEY (consumes
; the queued event) so an empty buffer costs one cheap peek, not a wasted
; consuming read.
;
; Writes the result to key_code, a shared cell rather than a returned
; register value (same reasoning rtc_sample's rtc_valid/rtc_hour etc use:
; this port has already shipped one real bug from assuming a z88dk
; calling/return convention instead of verifying it -- overlay_loader_
; sprinter.asm's SP+2 argument decode, docs/sprinter-testnotes/S5.md's
; first MAME run). key_code is a LATCH, not a per-frame snapshot: it is
; only overwritten when a key press actually translates to a recognised
; non-zero code, and left untouched on every frame with nothing pending
; or with an unmapped key -- deliberately, so a human reading the debug
; echo (render_input_key_echo, render_core.asm) sees the last real key
; for as long as it takes to read, instead of it reverting to "00" one
; frame (~20ms) after the keypress, which is unreadable (human tester
; feedback, 2026-08-11, on the first version of this routine that reset
; to 0 every frame with nothing newly queued). A real input consumer
; (later substep-3 work) will need its own poll-and-clear contract on top
; of this, matching ZX's own _spectrum_input_poll_event -- this cell is
; not that yet, only a persistent "last key" for visibility. Safe to call
; while IM2 is installed: the IM2 stub (resident_s1.asm's im2_stub) tail-
; jumps to DSS's own #0038 handler for anything that is not a frame tick,
; so DSS's keyboard FIFO keeps filling exactly as it would under DSS's
; native interrupt mode (port.md's R6). Clobbers AF, BC, DE.
key_poll:
        ld      c,DSS_TESTKEY
        rst     RST_DSS
        ret     z                       ; nothing queued -- key_code unchanged
        ld      c,DSS_SCANKEY
        rst     RST_DSS
        ld      (.scan_ascii),a
        ld      a,d
        and     $7F
        ld      (.scan_pos),a

        ld      a,(.scan_ascii)
        or      a
        jr      z,.positional

        cp      $1B                     ; ESC
        jr      z,.cancel
        cp      9                       ; TAB -- opens/closes the menu bar
        jr      z,.menu                 ; (SPECTRUM_GUI_KEY_MENU, gui.h) --
                                          ; Sprinter's own key choice: ZX's
                                          ; own physical MENU key does not
                                          ; exist on this port's PS/2
                                          ; keyboard mapping, and TAB is not
                                          ; otherwise claimed by anything
                                          ; above (S5-finish plan D12).
        cp      8                       ; backspace
        jr      z,.store
        cp      $0D                     ; enter/CR
        jr      z,.store
        cp      $7F                     ; delete -> backspace
        jr      z,.backspace
        cp      $20
        jr      c,.none                 ; control code, not handled
        cp      $7F
        jr      nc,.none                ; > printable range
        jr      .store                  ; 0x20-0x7E: printable ASCII

.positional:
        ld      a,(.scan_pos)
        cp      $58
        jr      z,.up
        cp      $52
        jr      z,.down
        cp      $54
        jr      z,.left
        cp      $56
        jr      z,.right
        jr      .none

.cancel:     ld      a,$8A
             jr      .store
.menu:       ld      a,$90
             jr      .store
.backspace:  ld      a,8
             jr      .store
.up:         ld      a,$81
             jr      .store
.down:       ld      a,$82
             jr      .store
.left:       ld      a,$83
             jr      .store
.right:      ld      a,$84
             jr      .store
.store:
        ld      (key_code),a
.none:
        ret
.scan_ascii: DB 0
.scan_pos:   DB 0

key_code: DB 0

; R11 exit discipline: network torn down first (ng_shutdown needs EI and
; WIN1 still resident -- S3), then IM2 uninstalled (so no stray interrupt
; lands mid-transition), video mode/screen restored from HDR, PORT_Y
; parked, DSS.Exit. Does not return.
exit_stand:
        call    ng_shutdown
        di
        call    im2_uninstall
        ld      a,(HDR_ADDR+HDR_SAVED_SCREEN_OFFSET)
        ld      b,a
        ld      a,(HDR_ADDR+HDR_SAVED_MODE_OFFSET)
        call    svmod_safe              ; WIN2-half wrapper (SetVMod clobbers
                                         ; the WIN1 mapping; this code is
                                         ; WIN1-half -- see resident_s1.asm)
        ; S5-finish plan D11/F2: SetVMod's B parameter restores the saved
        ; screen's own descriptor/mode but is independent of PORT_RGMOD --
        ; im2_frame_core may have left RGMOD bit 0 selecting buffer 1
        ; (mid-game flips), and DSS.Exit does not touch video state (see
        ; port.md's platform cheat-sheet). Park it back to buffer 0 so
        ; whatever runs next (DSS, a reloaded program) sees a known,
        ; boot-matching buffer instead of whichever one gameplay happened
        ; to leave selected.
        in      a,(PORT_RGMOD)
        and     $FE
        out     (PORT_RGMOD),a
        ld      a,#C0
        out     (PORT_Y),a
        ei
        ld      b,0
        ld      c,DSS_EXIT
        rst     RST_DSS
.hang:  jr      .hang

; --- frame-tick ISR tail (S5-finish plan D11: buffer flip) -----------------
;
; im2_stub (platform_primitives.asm, the pinned 15-byte fixed-address stub)
; tail-jumps here instead of setting frame_flag inline, on the branch that
; already determined (via SIO RR0 bit 0) that this interrupt is a frame
; tick and not a keyboard one. Splits into a body (im2_frame_core, RET --
; callable directly from tests/sprinter/z80/t_frame_wait.asm's mock to
; simulate "the ISR fired") and a thin ISR wrapper (im2_frame_isr) that
; replicates the stub's own .chain tail (pop af / jp #0038) the stub no
; longer falls through to once it has jumped away.
;
; im2_frame_core sets frame_flag unconditionally (im2_stub's own previous
; behaviour), then -- only if the main loop asked for a flip via frame_wait
; setting flip_request -- toggles PORT_RGMOD and clears flip_request. Both
; happen inside the same interrupt, atomically with respect to frame_wait's
; own mainline code (an ISR runs to completion before the HALT it woke
; returns control), so there is no window where frame_flag is visibly set
; while a pending flip_request is not yet acted on. Clobbers AF.
im2_frame_core:
        ld      a,1
        ld      (frame_flag),a
        ld      a,(flip_request)
        or      a
        ret     z
        in      a,(PORT_RGMOD)
        xor     1
        out     (PORT_RGMOD),a
        xor     a
        ld      (flip_request),a
        ret

; Real ISR entry point (jumped to from im2_stub with AF already pushed by
; the stub). Clobbers nothing visible to the interrupted code: AF is
; restored before the tail jump, matching im2_stub's own .chain contract.
im2_frame_isr:
        call    im2_frame_core
        pop     af
        jp      #0038

flip_request:   DB 0

CANARY_SENTINEL EQU #5A5A

frame_flag:     DB 0
im2_saved_i:    DB 0
fatal_msg_stack: DB 13,10,"Sprinter S1: stack canary corrupted (R4).",13,10,0

        ENDIF
