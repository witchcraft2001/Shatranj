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
; switch mode. Must run under DI; caller EIs afterward. Saves the previous
; I register for im2_uninstall (R11).
im2_install:
        call    im2_fill_table
        xor     a
        ld      (frame_flag),a
        ld      a,i
        ld      (im2_saved_i),a
        ld      a,high IM2_TABLE_ADDR
        ld      i,a
        im      2
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
frame_wait:
        call    canary_check
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
        or      a
        ret

; R11 exit discipline: IM2 uninstalled first (so no stray interrupt lands
; mid-transition), video mode/screen restored from HDR, PORT_Y parked,
; DSS.Exit. Does not return.
exit_stand:
        di
        call    im2_uninstall
        ld      a,(HDR+HDR_SAVED_SCREEN_OFFSET)
        ld      b,a
        ld      a,(HDR+HDR_SAVED_MODE_OFFSET)
        call    svmod_safe              ; WIN2-half wrapper (SetVMod clobbers
                                         ; the WIN1 mapping; this code is
                                         ; WIN1-half -- see resident_s1.asm)
        ld      a,#C0
        out     (PORT_Y),a
        ei
        ld      b,0
        ld      c,DSS_EXIT
        rst     RST_DSS
.hang:  jr      .hang

CANARY_SENTINEL EQU #5A5A

frame_flag:     DB 0
im2_saved_i:    DB 0
fatal_msg_stack: DB 13,10,"Sprinter S1: stack canary corrupted (R4).",13,10,0

        ENDIF
