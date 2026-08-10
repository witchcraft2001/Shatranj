; z80 unit test for asm/sprinter/im2_s1.asm's frame_wait/canary_check.
;
; S1_TEST_HOOK (defined here, before including im2_s1.asm) swaps frame_
; wait's HALT for a call to s1_test_mock_interrupt, a small test double
; with its own call counter that sets frame_flag on a configurable target
; call -- simulating "the ISR fired on wait N" without needing a real IM2
; interrupt in the harness. Only the intact-canary path is exercised: a
; corrupted canary jumps to fatal_stack_overflow, which makes real DSS RST
; calls the harness cannot service.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

        DEFINE S1_TEST_HOOK

; im2_s1.asm's exit_stand reads HDR+HDR_*_OFFSET; HDR itself is defined by
; resident_s1.asm (not included here, since this test only exercises
; frame_wait/canary_check). A placeholder satisfies the symbol reference;
; exit_stand is never called in this test. Same for svmod_safe (the
; WIN2-half SetVMod wrapper resident_s1.asm defines) and ng_shutdown (S3's
; net teardown, net_gate.asm -- not included here either).
HDR: DS 256,0
svmod_safe: ret
ng_shutdown: ret

start:
        ld      sp,#e800
        call    t_begin

        ld      hl,CANARY_SENTINEL
        ld      (CANARY_ADDR),hl

        ; canary_check on an intact canary returns normally (Z, no crash).
        call    canary_check
        ld      a,1
        call    t_expect_z

        ; Mock fires on the 3rd wait step -> NC, exactly 3 calls made.
        xor     a
        ld      (s1_test_call_counter),a
        ld      a,3
        ld      (s1_test_target_call),a
        call    frame_wait
        ld      a,2
        call    t_expect_nc
        ld      a,(s1_test_call_counter)
        cp      3
        ld      a,3
        call    t_expect_z

        ; Mock never fires -> CF after exactly FRAME_WAIT_TIMEOUT (256)
        ; waits. An 8-bit counter incremented 256 times wraps back to 0,
        ; which is what makes 0 the expected (not "still counting") result.
        xor     a
        ld      (s1_test_call_counter),a
        ld      (s1_test_target_call),a        ; 0 never matches (counter>=1)
        call    frame_wait
        ld      a,4
        call    t_expect_c
        ld      a,(s1_test_call_counter)
        cp      0
        ld      a,5
        call    t_expect_z

        call    t_end
        halt

        assert $ < TEST_RESULT

s1_test_call_counter: DB 0
s1_test_target_call:  DB 0

; Test double for HALT under S1_TEST_HOOK: increments its call counter and
; sets frame_flag exactly when the counter reaches s1_test_target_call.
; target=0 means "never fire" -- checked explicitly, not via a plain CP:
; an 8-bit counter incremented 256 times wraps back to 0 on the very last
; call, which would otherwise collide with a target of 0.
s1_test_mock_interrupt:
        ld      hl,s1_test_call_counter
        inc     (hl)
        ld      a,(s1_test_target_call)
        or      a
        ret     z
        ld      a,(s1_test_call_counter)
        ld      hl,s1_test_target_call
        cp      (hl)
        ret     nz
        ld      a,1
        ld      (frame_flag),a
        ret

        include "im2_s1.asm"
