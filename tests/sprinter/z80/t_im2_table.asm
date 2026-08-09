; z80 unit test for asm/sprinter/im2_s1.asm's im2_fill_table routine:
; fills IM2_TABLE_SIZE bytes at the real IM2_TABLE_ADDR with IM2_FILL_BYTE
; and touches nothing outside that span. z88dk-ticks runs a flat 64 KiB
; model with no real Sprinter windowing, so exercising the routine against
; its real fixed_layout.json address is safe here (it is ordinary RAM in
; the test harness) and proves the same derived-correctness invariant
; gen_sprinter_layout.py checks statically (IM2_STUB_ADDR ==
; fill_byte*0x101) also holds for code that actually executes the fill.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

; im2_s1.asm's exit_stand reads HDR+HDR_*_OFFSET; HDR itself is defined by
; resident_s1.asm (not included here, since this test only exercises
; im2_fill_table). A placeholder satisfies the symbol reference; exit_stand
; is never called in this test. Same for svmod_safe, the WIN2-half
; SetVMod wrapper resident_s1.asm defines.
HDR: DS 256,0
svmod_safe: ret

start:
        ld      sp,#e800
        call    t_begin

        ; Sentinels immediately outside the table, so an overrun in either
        ; direction is detectable.
        ld      a,#A5
        ld      (IM2_TABLE_ADDR-1),a
        ld      (IM2_TABLE_ADDR+IM2_TABLE_SIZE),a

        call    im2_fill_table

        ld      a,(IM2_TABLE_ADDR-1)
        cp      #A5
        ld      a,1
        call    t_expect_z
        ld      a,(IM2_TABLE_ADDR+IM2_TABLE_SIZE)
        cp      #A5
        ld      a,2
        call    t_expect_z

        ld      hl,IM2_TABLE_ADDR
        ld      b,0
.check: ld      a,(hl)
        cp      IM2_FILL_BYTE
        ld      a,3
        call    t_expect_z
        inc     hl
        djnz    .check          ; 256 of the 257 bytes checked via B=0 wrap
        ld      a,(hl)
        cp      IM2_FILL_BYTE
        ld      a,4
        call    t_expect_z      ; the 257th byte (the 0xFF/0x100 straddle)

        call    t_end
        halt

        assert $ < IM2_TABLE_ADDR - 1
        assert $ < TEST_RESULT

        include "im2_s1.asm"
