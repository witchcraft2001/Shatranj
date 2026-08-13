; z80 unit test for the WIN3 cold-page call trampoline (S7 step 5).
;
; The trampoline (tools/gen_sprinter_cold_thunks.py, generated here in
; sjasmplus dialect from the same string the shipped z88dk-z80asm stubs
; come from) is the one piece of this port whose failure modes are all
; runtime-only: a wrong stack discipline links cleanly, passes every
; static check, and then hands a routine somebody else's arguments. The
; three things checked below are exactly those:
;
;   1. THE ARGUMENT FRAME SURVIVES. The trampoline must not insert a frame
;      of its own -- it swaps the caller's return address for cold_ret and
;      jumps -- so a target reading z88dk classic's ordinary SP+2/SP+4
;      arguments sees what its caller pushed. The S7 step 4 version used
;      `call` and got away with it only because every entry it served was
;      `void f(void)` or __z88dk_fastcall; gui.c's three-argument entries
;      would have read the return address as their first argument.
;   2. NESTING UNWINDS. Cold-page code calls back into the resident, which
;      calls painters again through these stubs, so the saved page and
;      return address are a stack, not two cells. After an inner call
;      returns, the outer call's state must be exactly what it was.
;   3. THE DEPTH GUARD REFUSES CLEANLY. Past COLD_SAVE_DEPTH the
;      trampoline must return without running the target AND without
;      writing past cold_v_stack -- and the caller must still get control
;      back with its stack balanced.
;
; What this model CANNOT check, and does not pretend to: the paging
; itself. z88dk-ticks has a flat 64 KiB address space, so `out (#E2),a`
; is a no-op and #C000 is just ordinary RAM -- which is what makes the
; fake entry table below possible in the first place. That the trampoline
; restores the page it READ rather than a constant is covered statically
; instead (tests/tools/test_sprinter_cold_page.py).

        device noslot64k
        org 0
        jp start
        include "harness.inc"

WIN3_PORT EQU #E2

; Not #FF: the trampoline treats #FF as "bench_init has not published the
; page yet" and skips the call entirely. Any other value is "a page".
cold_win3_page: db #40

        include "cold_thunks_test.inc"

; --- fake cold page ---------------------------------------------------------
;
; The stubs jump to $C000+3*i by construction, so the test needs its own
; jump table exactly there. Copied in at run time rather than assembled at
; `org #C000`: this file is built with sjasmplus --raw, which writes bytes
; sequentially and would pad the image out to 48 KiB for a 12-byte table.
; In the real build this is the table cold_page_crt0.asm INCLUDEs at the
; top of the page image.
COLD_ENTRY_BASE EQU #C000

t_fake_table:
        jp t_target_args        ; entry 0
        jp t_target_nested      ; entry 1
        jp t_target_regs        ; entry 2
        jp t_target_recurse     ; entry 3
t_fake_table_end:

; --- targets ----------------------------------------------------------------
;
; void t_target_args(uint16_t a, uint16_t b) in z88dk classic terms: the
; caller pushed b then a, then called, so at entry SP+2 is the first
; argument and SP+4 the second. Records both, returns 0x1234 in HL.
; Also samples the trampoline's own bookkeeping WHILE INSIDE the call --
; the only point at which nesting is observable, since by the time an
; outer target regains control the inner one has already unwound.
t_target_args:
        ld      a,(cold_v_depth)
        ld      (t_depth_inner),a
        ld      hl,(cold_v_sp)
        ld      (t_sp_inner),hl
        ld      hl,2
        add     hl,sp
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      (t_arg0),de
        ld      hl,4
        add     hl,sp
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      (t_arg1),de
        ld      hl,#1234
        ret

; Calls straight back out through another stub, which is what a cold-page
; routine calling resident code that repaints actually does. Records the
; trampoline's own depth while nested so the test can prove it really did
; nest rather than silently flattening.
t_target_nested:
        call    cold_stub_0
        ret

; Records BC/DE and the flags/A it was entered with, to prove the stub is
; register-transparent for an asm-side caller.
t_target_regs:
        ld      (t_regs_bc),bc
        ld      (t_regs_de),de
        ld      (t_regs_hl),hl
        ld      (t_regs_a),a
        ret

; Recurses through its own stub until the depth guard refuses. Counts how
; many times the body actually ran.
t_target_recurse:
        ld      a,(t_recurse_ran)
        inc     a
        ld      (t_recurse_ran),a
        call    cold_stub_3
        ret

t_arg0:         dw 0
t_arg1:         dw 0
t_depth_inner:  db 0
t_sp_inner:     dw 0
t_regs_bc:      dw 0
t_regs_de:      dw 0
t_regs_hl:      dw 0
t_regs_a:       db 0
t_recurse_ran:  db 0
t_sp_before:    dw 0
t_sp_after:     dw 0

start:
        ld      sp,#E800
        call    t_begin

        ld      hl,t_fake_table
        ld      de,COLD_ENTRY_BASE
        ld      bc,t_fake_table_end-t_fake_table
        ldir

        ; --- 1. the argument frame reaches the target intact ----------------
        ld      hl,#BEEF
        push    hl                      ; second argument
        ld      hl,#CAFE
        push    hl                      ; first argument
        call    cold_stub_0
        pop     de
        pop     de                      ; caller cleans, as z88dk classic does

        ld      hl,(t_arg0)
        ld      de,#CAFE
        or      a
        sbc     hl,de
        ld      a,1
        call    t_expect_z
        ld      hl,(t_arg1)
        ld      de,#BEEF
        or      a
        sbc     hl,de
        ld      a,2
        call    t_expect_z

        ; --- 2. the return value survives the window restore ----------------
        call    cold_stub_0             ; no arguments this time; HL=#1234 out
        ld      de,#1234
        or      a
        sbc     hl,de
        ld      a,3
        call    t_expect_z

        ; --- 3. one level deep while inside, balanced again after -----------
        ld      a,(t_depth_inner)
        cp      1
        ld      a,22
        call    t_expect_z
        ld      hl,(t_sp_inner)
        ld      de,cold_v_stack+3
        or      a
        sbc     hl,de
        ld      a,23
        call    t_expect_z

        ld      a,(cold_v_depth)
        or      a
        ld      a,4
        call    t_expect_z
        ld      hl,(cold_v_sp)
        ld      de,cold_v_stack
        or      a
        sbc     hl,de
        ld      a,5
        call    t_expect_z

        ; --- 4. register transparency for an asm-side caller ----------------
        ld      bc,#0102
        ld      de,#0304
        ld      hl,#0506
        ld      a,#5A
        call    cold_stub_2
        ld      hl,(t_regs_bc)
        ld      de,#0102
        or      a
        sbc     hl,de
        ld      a,6
        call    t_expect_z
        ld      hl,(t_regs_de)
        ld      de,#0304
        or      a
        sbc     hl,de
        ld      a,7
        call    t_expect_z
        ld      hl,(t_regs_hl)
        ld      de,#0506
        or      a
        sbc     hl,de
        ld      a,8
        call    t_expect_z
        ld      a,(t_regs_a)
        cp      #5A
        ld      a,9
        call    t_expect_z

        ; --- 5. nesting really nests, and unwinds to where it started -------
        ld      (t_sp_before),sp
        call    cold_stub_1
        ld      (t_sp_after),sp

        ld      a,(t_depth_inner)       ; outer + inner both live
        cp      2
        ld      a,10
        call    t_expect_z
        ld      hl,(t_sp_inner)         ; two entries pushed = 6 bytes
        ld      de,cold_v_stack+6
        or      a
        sbc     hl,de
        ld      a,11
        call    t_expect_z

        ld      a,(cold_v_depth)        ; fully unwound again
        or      a
        ld      a,12
        call    t_expect_z
        ld      hl,(cold_v_sp)
        ld      de,cold_v_stack
        or      a
        sbc     hl,de
        ld      a,13
        call    t_expect_z
        ld      hl,(t_sp_after)         ; and the CPU stack is where it was
        ld      de,(t_sp_before)
        or      a
        sbc     hl,de
        ld      a,14
        call    t_expect_z

        ; --- 6. the depth guard refuses instead of overrunning --------------
        xor     a
        ld      (t_recurse_ran),a
        ld      (t_sp_before),sp
        call    cold_stub_3
        ld      (t_sp_after),sp

        ld      a,(t_recurse_ran)       ; exactly COLD_SAVE_DEPTH bodies ran
        cp      COLD_SAVE_DEPTH
        ld      a,15
        call    t_expect_z
        ld      a,(cold_v_depth)        ; the refused level left nothing behind
        or      a
        ld      a,16
        call    t_expect_z
        ld      hl,(cold_v_sp)
        ld      de,cold_v_stack
        or      a
        sbc     hl,de
        ld      a,17
        call    t_expect_z
        ld      hl,(t_sp_after)
        ld      de,(t_sp_before)
        or      a
        sbc     hl,de
        ld      a,18
        call    t_expect_z

        ; --- 7. an unpublished page (#FF) is a clean no-op, not a crash -----
        ld      a,#FF
        ld      (cold_win3_page),a
        ld      hl,0
        ld      (t_arg0),hl
        ld      (t_sp_before),sp
        ld      hl,#CAFE
        push    hl
        call    cold_stub_0
        pop     de
        ld      (t_sp_after),sp

        ld      hl,(t_arg0)             ; target never ran
        ld      a,h
        or      l
        ld      a,19
        call    t_expect_z
        ld      hl,(t_sp_after)
        ld      de,(t_sp_before)
        or      a
        sbc     hl,de
        ld      a,20
        call    t_expect_z
        ld      a,(cold_v_depth)
        or      a
        ld      a,21
        call    t_expect_z

        call    t_end
.halt:  jr .halt
