; Execute the shipping NET wrappers and WIN2 result bridge. A fake DLL
; overwrites WIN1, proving neither return code nor arguments live there.
        device noslot64k
        org 0
        jp start
        ds #100-$,0
        include "harness.inc"
        include "host_test_defs.inc"
        include "platform_test_defs.inc"
start:
        ld sp,#3f00
        call t_begin
        ld a,#c3
        ld (plat_ng_call),a
        ld hl,dll_stub
        ld (plat_ng_call+1),hl
        ld a,18
        ld (expected_function),a
        ld hl,5000
        call host_test_host_listen
        ld a,(plat_ng_v_call_status)
        or a
        ld a,1
        call t_expect_z
        ld a,(plat_ng_v_call_cf)
        or a
        ld a,2
        call t_expect_z
        ld a,9
        ld (expected_function),a
        call host_test_host_status
        ld hl,(plat_ng_v_call_len)
        ld de,10
        or a
        sbc hl,de
        ld a,3
        call t_expect_z
        ld a,19
        ld (expected_function),a
        call host_test_host_unlisten
        ld a,(plat_ng_v_call_status)
        cp 7
        ld a,4
        call t_expect_z
        ld a,(plat_ng_v_call_cf)
        cp 1
        ld a,5
        call t_expect_z
        ld hl,(plat_ng_v_call_flags)
        ld de,#abcd
        or a
        sbc hl,de
        ld a,6
        call t_expect_z
        ld a,(#c000)
        cp 11
        ld a,7
        call t_expect_z
        ld a,13
        ld (expected_function),a
        call host_test_host_rx_pause
        ld a,14
        ld (expected_function),a
        call host_test_host_rx_resume
        call t_end
        halt
        jp $-1
expected_function: db 0
dll_stub:
        or a
        ld a,8
        call t_expect_z             ; channel is always zero
        ld a,(expected_function)
        cp b
        ld a,9
        call t_expect_z
        ld a,b
        cp 18
        jr nz,.smash
        ld hl,5000
        or a
        sbc hl,de
        ld a,10
        call t_expect_z             ; binary port, not an ASCII pointer
.smash:
        ld hl,#4000
        ld de,#4001
        ld bc,#3fff
        ld (hl),#dd
        ldir                        ; emulate DLL displacing WIN1
        ld de,10
        ld ix,#abcd
        ld a,(expected_function)
        cp 19
        ld a,7
        scf
        ret z
        xor a
        ret
        ds #4000-$,0
        incbin "resident.bin"
        assert $ == #c000
        incbin "overlay_net_sprinter.bin"
