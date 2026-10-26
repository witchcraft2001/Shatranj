; Real cold-page net_drop clears MOVE/RESTORE/control state and schedules
; hosting only for the next loop. Renderers and overlay dispatch are stubs.
        device noslot64k
        org 0
        jp start
        ds #100-$,0
        include "harness.inc"
        include "fixed_layout.inc"
        include "host_test_defs.inc"
start:
        ld sp,#3f00
        call t_begin
        ld a,#c9
        ld (host_cold_net_status_idle),a
        ld (host_cold_spectrum_gui_game_timer_stop),a
        ld (host_cold_spectrum_gui_reset_chat),a
        ld (host_cold_spectrum_gui_notify),a
        ld a,#c3
        ld (host_cold_spectrum_overlay_exec_cached),a
        ld hl,dispatch
        ld (host_cold_spectrum_overlay_exec_cached+1),hl
        ld a,1
        ld (mode),a
.case:
        ld a,(mode)
        ld (LOWRAM_DIRECT_HOST_ADDR),a
        ld a,#ff
        ld (LOWRAM_DIRECT_HOST_ADDR+2),a ; peer_known
        ld (LOWRAM_DIRECT_HOST_ADDR+4),a ; ping state
        ld (LOWRAM_DIRECT_HOST_ADDR+5),a
        ld (LOWRAM_DIRECT_HOST_ADDR+6),a
        ld hl,clear_bytes
        ld b,(clear_end-clear_bytes)/2
.seed:
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (de),a
        djnz .seed
        xor a
        ld (dispatch_count),a
        ld hl,reason
        push hl
        call host_cold_net_drop
        pop bc
        ld a,(mode)
        ld b,a
        ld a,(host_cold_net_active)
        cp b
        ld a,1
        call t_expect_z
        ld a,(LOWRAM_DIRECT_HOST_ADDR+1)
        cp b
        ld a,2
        call t_expect_z
        ld a,(LOWRAM_DIRECT_HOST_ADDR)
        cp b
        ld a,3
        call t_expect_z
        ld hl,clear_bytes
        ld b,(clear_end-clear_bytes)/2
.check:
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(de)
        or a
        ld a,4
        call t_expect_z
        djnz .check
        ld a,(dispatch_count)
        cp 1                       ; cleanup only, never recursive Listen
        ld a,5
        call t_expect_z
        ld a,(mode)
        or a
        jr z,.done
        xor a
        ld (mode),a
        jp .case
.done:
        ; Explicit DISCONNECT during handshake disables the hosting intent.
        ld a,#c9
        ld (host_cold_spectrum_net_send_text),a
        xor a
        ld (host_cold_netchesszx_transport),a
        ld (dispatch_count),a
        ld a,1
        ld (host_cold_net_active),a
        ld (LOWRAM_DIRECT_HOST_ADDR),a
        call host_cold_menu_network
        ld a,(host_cold_net_active)
        or a
        ld a,7
        call t_expect_z
        ld a,(LOWRAM_DIRECT_HOST_ADDR)
        or a
        ld a,8
        call t_expect_z
        ld a,(LOWRAM_DIRECT_HOST_ADDR+1)
        or a
        ld a,9
        call t_expect_z
        ld a,(dispatch_count)
        cp 1
        ld a,10
        call t_expect_z
        ; A failed handshake returns from NET before net_dispatch invokes
        ; cleanup. Exercise the real dispatcher wrapper and real net_drop.
        xor a
        ld (dispatch_count),a
        ld a,1
        ld (fail_hello),a
        ld hl,7                     ; HELLO entry
        push hl
        call host_cold_net_dispatch
        pop bc
        ld a,l
        or a
        ld a,11
        call t_expect_z             ; failure is consumed, caller stops
        ld a,(dispatch_count)
        cp 2                        ; HELLO returned, then CLOSE
        ld a,12
        call t_expect_z
        ; START/HELLO in progress owns the operation slot even though no
        ; MOVE or cold-page control operation has been queued yet.
        ld a,1
        ld (host_cold_net_active),a
        call host_cold_net_op_busy
        ld a,l
        or a
        ld a,14
        call t_expect_nz
        ld a,1
        ld (host_cold_netchesszx_session_peer_ready_state),a
        call host_cold_net_op_busy
        ld a,l
        or a
        ld a,15
        call t_expect_z
        call t_end
        halt
        jp $-1
reason: db "test disconnect",0
mode: db 0
dispatch_count: db 0
fail_hello: db 0
dispatch:
        ld hl,dispatch_count
        inc (hl)
        ld hl,2
        add hl,sp
        ld a,(fail_hello)
        or a
        jr z,.close
        ld a,(hl)
        cp 7
        ld a,13
        call t_expect_z
        xor a
        ld (fail_hello),a
        ld hl,2                     ; SPRINTER_NET_FAILED, no nested call
        ret
.close:
        ld a,(hl)
        cp 8                        ; Sprinter NET close entry
        ld a,6
        call t_expect_z
        ld hl,1
        ret
clear_bytes:
        dw host_cold_pending_local_ply,host_cold_pending_local_ply+1
        dw host_cold_pending_local_move,host_cold_pending_retry_timer
        dw host_cold_control_pending,host_cold_control_retry_count
        dw host_cold_takeback_pending_ply,host_cold_takeback_pending_ply+1
        dw host_cold_takeback_snapshot_ply,host_cold_takeback_snapshot_ply+1
        dw host_cold_takeback_snapshot_local
        dw host_cold_restore_rx_mask,host_cold_restore_chunk_have
        dw host_cold_restore_prompt_pending,host_cold_resign_pending
        dw host_cold_resign_confirm,host_cold_game_over
        dw host_cold_netchesszx_session_peer_ready_state
        dw LOWRAM_DIRECT_HOST_ADDR+2,LOWRAM_DIRECT_HOST_ADDR+4
        dw LOWRAM_DIRECT_HOST_ADDR+5,LOWRAM_DIRECT_HOST_ADDR+6
clear_end:
        ds #4000-$,0
        incbin "resident.bin"
        assert $ == #c000
        incbin "cold_win3_page.bin"
