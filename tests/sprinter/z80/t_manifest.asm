; z80 unit test for asm/sprinter/manifest.inc's manifest_validate routine:
; a valid STM1 manifest must pass with B=page_count, and each field
; corrupted one at a time must be rejected (CF=1). Run through
; tools/run_sprinter_z80_tests.sh (sjasmplus + z88dk-ticks); protocol at
; extern/sprinter-libs/gfx320/tests/z80/harness.inc.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

test_buf: ds 32,0

start:
        ld sp,#e800
        call t_begin

        ; A valid manifest passes and reports the page count in B.
        call build_valid
        ld hl,test_buf
        call manifest_validate
        call t_keep_a
        ld a,1
        call t_expect_nc
        ld a,b
        cp 2
        ld a,2
        call t_expect_z

        ; manifest_validate must not clobber the caller's HL pointer.
        call build_valid
        ld hl,test_buf
        push hl
        call manifest_validate
        pop de
        or a
        sbc hl,de
        ld a,3
        call t_expect_z

        ; Corrupt magic.
        call build_valid
        ld a,'X'
        ld (test_buf),a
        ld hl,test_buf
        call manifest_validate
        ld a,4
        call t_expect_c

        ; Corrupt version.
        call build_valid
        ld a,99
        ld (test_buf+4),a
        ld hl,test_buf
        call manifest_validate
        ld a,5
        call t_expect_c

        ; Zero page count.
        call build_valid
        xor a
        ld (test_buf+5),a
        ld hl,test_buf
        call manifest_validate
        ld a,6
        call t_expect_c

        ; Entry address does not match TRAMPOLINE_ADDR.
        call build_valid
        xor a
        ld (test_buf+6),a
        ld (test_buf+7),a
        ld hl,test_buf
        call manifest_validate
        ld a,7
        call t_expect_c

        ; Payload size does not match page_count * MANIFEST_PAGE_SIZE.
        call build_valid
        xor a
        ld (test_buf+8),a
        ld (test_buf+9),a
        ld hl,test_buf
        call manifest_validate
        ld a,8
        call t_expect_c

        ; A single-page manifest (page_count=1) must also validate, proving
        ; the payload check isn't hardcoded to 2 pages.
        call build_valid
        ld a,1
        ld (test_buf+5),a
        ld a,low MANIFEST_PAGE_SIZE
        ld (test_buf+8),a
        ld a,high MANIFEST_PAGE_SIZE
        ld (test_buf+9),a
        ld hl,test_buf
        call manifest_validate
        call t_keep_a
        ld a,9
        call t_expect_nc
        ld a,b
        cp 1
        ld a,10
        call t_expect_z

        call t_end
        halt

; Reset test_buf to a manifest that must pass validation. LDIR copies
; (HL)->(DE): HL=source (valid_fixture), DE=destination (test_buf).
build_valid:
        ld hl,valid_fixture
        ld de,test_buf
        ld bc,32
        ldir
        ret

valid_fixture:
        db "STM1"
        db 1                    ; version
        db 2                    ; page_count
        dw TRAMPOLINE_ADDR      ; entry
        dw 2*MANIFEST_PAGE_SIZE ; payload size
        ds 22,0                 ; reserved

        include "manifest.inc"

        assert $ < TEST_RESULT
