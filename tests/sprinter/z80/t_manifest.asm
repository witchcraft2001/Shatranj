; z80 unit test for asm/sprinter/manifest.inc's manifest_validate routine
; (v2 format, port.md section 5/S2): a valid STM1 manifest must pass with
; B=total page_count and E=asset page count, and each field corrupted one
; at a time must be rejected (CF=1). Run through
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

        ; A valid manifest (2 resident + 1 asset page) passes and reports
        ; the total page count in B and the asset page count in E.
        call build_valid
        ld hl,test_buf
        call manifest_validate
        call t_keep_a
        ld a,1
        call t_expect_nc
        ld a,b
        cp 3
        ld a,2
        call t_expect_z
        ld a,e
        cp 1
        ld a,3
        call t_expect_z

        ; manifest_validate must not clobber the caller's HL pointer.
        call build_valid
        ld hl,test_buf
        push hl
        call manifest_validate
        pop de
        or a
        sbc hl,de
        ld a,4
        call t_expect_z

        ; Corrupt magic.
        call build_valid
        ld a,'X'
        ld (test_buf),a
        ld hl,test_buf
        call manifest_validate
        ld a,5
        call t_expect_c

        ; Corrupt version.
        call build_valid
        ld a,99
        ld (test_buf+4),a
        ld hl,test_buf
        call manifest_validate
        ld a,6
        call t_expect_c

        ; Zero page count.
        call build_valid
        xor a
        ld (test_buf+5),a
        ld hl,test_buf
        call manifest_validate
        ld a,7
        call t_expect_c

        ; Entry address does not match TRAMPOLINE_ADDR.
        call build_valid
        xor a
        ld (test_buf+6),a
        ld (test_buf+7),a
        ld hl,test_buf
        call manifest_validate
        ld a,8
        call t_expect_c

        ; Payload size (256-byte units) does not match
        ; page_count * (MANIFEST_PAGE_SIZE/MANIFEST_PAYLOAD_UNIT).
        call build_valid
        xor a
        ld (test_buf+8),a
        ld (test_buf+9),a
        ld hl,test_buf
        call manifest_validate
        ld a,9
        call t_expect_c

        ; Asset page count equal to the total page count (no resident page
        ; left) must be rejected.
        call build_valid
        ld a,3
        ld (test_buf+10),a
        ld hl,test_buf
        call manifest_validate
        ld a,10
        call t_expect_c

        ; Asset page count greater than the total page count.
        call build_valid
        ld a,9
        ld (test_buf+10),a
        ld hl,test_buf
        call manifest_validate
        ld a,11
        call t_expect_c

        ; A fully-resident manifest (page_count=1, asset_pages=0) must also
        ; validate, proving the payload check isn't hardcoded to 2 pages
        ; and asset_pages=0 is legal.
        call build_valid
        ld a,1
        ld (test_buf+5),a
        ld a,low (MANIFEST_PAGE_SIZE/MANIFEST_PAYLOAD_UNIT)
        ld (test_buf+8),a
        ld a,high (MANIFEST_PAGE_SIZE/MANIFEST_PAYLOAD_UNIT)
        ld (test_buf+9),a
        xor a
        ld (test_buf+10),a
        ld hl,test_buf
        call manifest_validate
        call t_keep_a
        ld a,12
        call t_expect_nc
        ld a,b
        cp 1
        ld a,13
        call t_expect_z
        ld a,e
        cp 0
        ld a,14
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
        db 2                                          ; version
        db 3                                          ; page_count (2 resident + 1 asset)
        dw TRAMPOLINE_ADDR                             ; entry
        dw 3*(MANIFEST_PAGE_SIZE/MANIFEST_PAYLOAD_UNIT) ; payload size, 256-B units
        db 1                                           ; asset_pages
        ds 21,0                                        ; reserved

        include "manifest.inc"

        assert $ < TEST_RESULT
