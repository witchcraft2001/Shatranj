; Exercise the real UNETLD and ng_up/ng_shutdown with a scripted libman
; boundary. t_net_gate/t_net_core separately test the real libman dispatcher.
; This fixture can force every LOAD/NETSTART failure without a DSS filesystem.
        device noslot64k
        org 0
        jp start
        ds #10-$,0
dss_stub:
        ld a,c
        cp DSS_ENVIRON
        jr z,.env
        scf
        ret
.env:
        ld a,(env_present)
        or a
        ret z
        ld hl,(env_source)
.copy:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        or a
        jr nz,.copy
        ld a,#ff
        ret
        ds #100-$,0
        include "harness.inc"

start:
        ld sp,#e800
        call t_begin
        ld hl,CANARY_SENTINEL
        ld (CANARY_ADDR),hl
        ld a,1
        ld (test_case),a
.case:
        call fixture_reset
        ld a,(test_case)
        ld (failure),a
        call ng_up
        ld (seen_status),a
        ld a,1
        call t_expect_c
        ld hl,expected_errors-1
        ld a,(test_case)
        ld e,a
        ld d,0
        add hl,de
        ld a,(seen_status)
        cp (hl)
        ld a,2
        call t_expect_z
        ld a,(ng_up_reason)
        cp (hl)
        ld a,3
        call t_expect_z
        ld a,(ng_v_depth)
        or a
        ld a,4
        call t_expect_z

        ; Retry directly with the failed handle still open. Successful
        ; retry must free it first, and must not overwrite the diagnostics
        ; with a stale loader error from a full single-entry handle table.
        xor a
        ld (failure),a
        call ng_up
        ld a,5
        call t_expect_nc
        ld a,(load_count)
        cp 2
        ld a,6
        call t_expect_z
        ld a,(test_case)
        cp 1
        ld a,0
        jr z,.expected_free
        inc a
.expected_free:
        ld (expected_frees),a
        ld b,a
        ld a,(free_count)
        cp b
        ld a,7
        call t_expect_z
        ld a,(UNETLD.FLAGS)
        cp UNETLD_F_LOADED | UNETLD_F_NETINIT
        ld a,8
        call t_expect_z
        ld a,(ng_up_reason)
        or a
        ld a,9
        call t_expect_z
        call ng_up
        ld a,10
        call t_expect_nc
        ld a,(load_count)
        cp 2
        ld a,11
        call t_expect_z

        call ng_shutdown
        ld a,(close_count)
        cp 1
        ld a,12
        call t_expect_z
        ld a,(done_count)
        cp 1
        ld a,13
        call t_expect_z
        ld a,(expected_frees)
        inc a
        ld b,a
        ld a,(free_count)
        cp b
        ld a,14
        call t_expect_z
        ld a,(UNETLD.FLAGS)
        or a
        ld a,15
        call t_expect_z
        ld a,(UNETLD.DLL_NAME)
        or a
        ld a,16
        call t_expect_z
        call ng_shutdown
        ld a,(expected_frees)
        inc a
        ld b,a
        ld a,(free_count)
        cp b
        ld a,17
        call t_expect_z
        ld a,(boundary_failures)
        or a
        ld a,18
        call t_expect_z
        ld hl,test_case
        inc (hl)
        ld a,(hl)
        cp 12
        jp c,.case

        ; Shutdown after an ABI mismatch must free the handle without
        ; sending CLOSE or NETDONE into a DLL that did not pass validation.
        call fixture_reset
        ld a,6
        ld (failure),a
        call ng_up
        call ng_shutdown
        ld a,(close_count)
        or a
        ld a,19
        call t_expect_z
        ld a,(done_count)
        or a
        ld a,20
        call t_expect_z
        ld a,(free_count)
        cp 1
        ld a,21
        call t_expect_z

        ; DSS may return 255 characters plus NUL. The small editor field
        ; must be capped before that value can reach WIN3 overlay storage.
        ; Editor seeding precedes ng_up on a fresh NETWORK screen. It
        ; must initialize the DLL name before the screen reads it.
        call fixture_reset
        ld hl,long_env
        ld (env_source),hl
        ld hl,net_name
        ld (ng_c_env_name),hl
        ld hl,small_field
        ld (ng_c_env_dest),hl
        ld a,6
        ld (ng_c_env_capacity),a
        call ng_c_env_get
        ld a,(UNETLD.DLL_NAME)
        or a
        ld a,30
        call t_expect_z
        ld a,(UNETLD.FLAGS)
        or a
        ld a,31
        call t_expect_z
        ld a,(ng_initialized)
        cp 1
        ld a,32
        call t_expect_z
        ld a,(ng_c_env_found)
        cp 1
        ld a,22
        call t_expect_z
        ld a,(small_field+4)
        cp 'X'
        ld a,23
        call t_expect_z
        ld a,(small_field+5)
        or a
        ld a,24
        call t_expect_z
        ld a,(field_before)
        cp #a5
        ld a,25
        call t_expect_z
        ld a,(field_after)
        cp #5a
        ld a,26
        call t_expect_z
        ld a,(UNETLD.ENV_VALUE+255)
        or a
        ld a,27
        call t_expect_z
        xor a
        ld (env_present),a
        ld a,'Q'
        ld (small_field),a
        call ng_c_env_get
        ld a,(ng_c_env_found)
        or a
        ld a,28
        call t_expect_z
        ld a,(small_field)
        cp 'Q'
        ld a,29
        call t_expect_z
        ld a,(boundary_failures)
        or a
        ld a,33
        call t_expect_z
        call t_end
        halt

fixture_reset:
        xor a
        ld (ng_initialized),a
        ld (ng_up_reason),a
        ld (ng_v_depth),a
        ld (failure),a
        ld (live_handle),a
        ld (load_count),a
        ld (free_count),a
        ld (close_count),a
        ld (done_count),a
        ld (boundary_failures),a
        ; Compact state is not initially zeroed by EXE loading. Poison it
        ; to ensure the first ng_up really RESETs before its first UNLOAD.
        ld a,#ff
        ld (UNETLD.FLAGS),a
        ld hl,#ffff
        ld (UNETLD.HANDLE),hl
        ld hl,wifi_value
        ld (env_source),hl
        ld a,1
        ld (env_present),a
        ret

; Modes: load, info, name, GETCAPS CF, GETCAPS status, ABI, no TCP,
; STATUS CF, STATUS status, NETINIT CF, NETINIT status.
expected_errors: db 3,4,5,6,6,7,10,11,8,11,9
test_case: db 0
failure: db 0
seen_status: db 0
expected_frees: db 0
live_handle: db 0
load_count: db 0
free_count: db 0
close_count: db 0
done_count: db 0
boundary_failures: db 0
env_present: db 1
env_source: dw wifi_value
wifi_value: db "WIFI",0
net_name: db "NETHOST",0
long_env: ds 255,'X'
          db 0
field_before: db #a5
small_field: ds 6,#cc
field_after: db #5a
good_info: db "UNETESP",0
bad_info: db "UNETRTL",0
HDR: ds 256,0
svmod_safe: ret

        assert $ < #8000
        ds #8000-$,0
        include "im2_s1.asm"
        include "text640.asm"
        include "buffers.asm"

; Contract doubles keep the loaded-handle lifetime and simulate both
; dispatcher CF failures and uNet A-status failures independently.
        MODULE LIBMAN
l_load:
        cp 1
        call nz,boundary_error
        call check_guard
        ld a,(live_handle)
        or a
        call nz,boundary_error
        ld hl,load_count
        inc (hl)
        ld a,(failure)
        cp 1
        jr z,.fail
        ld a,1
        ld (live_handle),a
        ld hl,#1234
        or a
        ret
.fail: scf
        ret
l_info:
        call check_guard
        ld a,(failure)
        cp 2
        jr z,.fail
        ld hl,good_info
        cp 3
        jr nz,.copy
        ld hl,bad_info
.copy:
        ; l_info copies a 32-byte L1 header, whose name starts at +16.
        push de
        ld bc,16
        ex de,hl
        add hl,bc
        ex de,hl
.char:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        or a
        jr nz,.char
        pop de
        or a
        ret
.fail: scf
        ret
l_call:
        call check_guard
        ld a,(live_handle)
        or a
        call z,boundary_error
        ld a,b
        cp UNET_FN_GETCAPS
        jr z,.caps
        cp UNET_FN_STATUS
        jr z,.status
        cp UNET_FN_NETINIT
        jr z,.init
        cp UNET_FN_CLOSE
        jr z,.close
        cp UNET_FN_NETDONE
        jr z,.done
        call boundary_error
        scf
        ret
.caps:
        ld a,(failure)
        cp 4
        jr z,.dispatch_fail
        cp 5
        jr z,.status_fail
        ld de,UNET_CAP_TCP
        cp 7
        jr nz,.abi
        ld de,0
.abi:
        ld ix,UNET_ABI_VERSION
        cp 6
        jr nz,.ok
        ld ix,UNET_ABI_VERSION+#100
        jr .ok
.status:
        ld a,(failure)
        cp 8
        jr z,.dispatch_fail
        cp 9
        jr z,.status_fail
        jr .ok
.init:
        ld a,(failure)
        cp 10
        jr z,.dispatch_fail
        cp 11
        jr z,.status_fail
        jr .ok
.close:
        ld hl,close_count
        inc (hl)
        jr .ok
.done:
        ld hl,done_count
        inc (hl)
.ok:   xor a
        ret
.dispatch_fail:
        ld a,NERR_PARAM
        scf
        ret
.status_fail:
        ld a,NERR_HW
        or a
        ret
l_free:
        call check_guard
        ld a,(live_handle)
        or a
        call z,boundary_error
        ld hl,free_count
        inc (hl)
        xor a
        ld (live_handle),a
        ret
check_guard:
        push af
        ld a,(ng_v_depth)
        cp 1
        call nz,boundary_error
        ld a,i
        call po,boundary_error
        pop af
        ret
boundary_error:
        push hl
        ld hl,boundary_failures
        inc (hl)
        pop hl
        ret
        ENDMODULE

        DEFINE _DSS_INC
ENV_GET EQU DSS_ENV_GET
DSS EQU RST_DSS
        DEFINE UNETLD_STATE_BASE LOWRAM_NET_GATE_ADDR
        include "unetld.asm"
        include "net_gate.asm"
        include "net_gate_tail.asm"
        assert $ < LOWRAM_NET_GATE_ADDR
        end start
