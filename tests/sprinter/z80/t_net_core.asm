; z80 unit test for net_gate.asm's S7 additions: ng_send's capacity
; boundary + WIN2 staging discipline, ng_recv's flag/length pass-through,
; and the ng_c_* C-callable wrappers' result-cell population. Same fake-
; DLL-via-poked-lib_table technique as t_net_gate.asm (that file's own
; banner explains the RST #10 stub and lib_table[0] poke); scenarios here
; are net_gate's higher-level wrappers, not ng_call's own funnel (already
; covered there).
;
; nc_pump() itself (net_frame.c, a separate zcc/z88dk-z80asm build) is not
; exercised here -- this sjasmplus harness cannot link that toolchain's
; output. Its correctness rests on two things this repo does verify: this
; file's proof that ng_c_recv_poll's result cells are populated correctly
; from a real dispatch, and tests/sprinter/host/test_net_frame.c's proof
; that nc_feed() (what nc_pump feeds those results into) handles scripted
; chunk sequences correctly. A true end-to-end nc_pump proof needs a live
; DLL (MAME/hardware), same as the rest of net_gate.asm's DLL-facing half.

        device  noslot64k

        org     0
        jp      start
        ds      #0010-$,0
dss_stub:
        ld      a,c
        cp      #39                     ; SETWIN1 (corecall's explicit call)
        jr      z,.setwin1
        ld      a,#7f                   ; anything else (incl. ENVIRON,
        scf                             ; #46): "not found"/unhandled --
        ret                             ; ng_env_try's own contract treats
                                         ; CF=1 as "fall back to default".
.setwin1:
        xor     a
        ret

        assert  $ < #0100
        ds      #0100-$,0

        include "harness.inc"

; net_gate.asm's ng_trap_screen/exit_stand (pulled in transitively via
; im2_s1.asm) reference these; neither is ever reached by this test's
; scenarios (t_net_gate.asm's own precedent for this stub pair).
HDR: DS 256,0
svmod_safe: ret

start:
        ld      sp,#e800
        call    t_begin

        ld      hl,CANARY_SENTINEL
        ld      (CANARY_ADDR),hl
        call    ng_test_install_lib

; --- Scenario 1: ng_send(B=65) is rejected before ever reaching the DLL
; (NG_TX_CAPACITY=64): CF=1, A=NERR_PARAM, dispatch never happens. --------
        xor     a
        ld      (test_dll_send_called),a
        ld      hl,test_src_65
        ld      b,65
        call    ng_send
        ld      (test_status_seen),a
        ld      a,1
        call    t_expect_c
        ld      a,(test_status_seen)
        cp      9                       ; NERR_PARAM
        ld      a,2
        call    t_expect_z
        ld      a,(test_dll_send_called)
        or      a
        ld      a,3
        call    t_expect_z

; --- Scenario 2: ng_send(B=64) is accepted, stages exactly 64 bytes into
; ng_buf_tx (a WIN2 address -- never test_src_64 itself), and the fake DLL
; sees that staged copy byte-for-byte. -------------------------------------
        ld      hl,test_src_64
        ld      b,64
        call    ng_send
        ld      a,4
        call    t_expect_nc
        ld      a,(test_dll_send_called)
        or      a
        ld      a,5
        call    t_expect_nz
        ld      a,(test_dll_send_de_lo)
        ld      hl,ng_buf_tx
        cp      l
        ld      a,6
        call    t_expect_z
        ld      a,(test_dll_send_de_hi)
        ld      hl,ng_buf_tx
        cp      h
        ld      a,7
        call    t_expect_z
        ld      a,(test_dll_send_match)
        or      a
        ld      a,8
        call    t_expect_nz

; --- Scenario 3: ng_recv passes DE (length) and IX (flags) through from
; the DLL unmangled, and the received bytes land in ng_buf_rx. ------------
        ld      iy,0
        call    ng_recv
        ld      a,9
        call    t_expect_nc
        ld      a,(ng_buf_rx)
        cp      "H"
        ld      a,10
        call    t_expect_z
        ld      a,(ng_buf_rx+1)
        cp      "i"
        ld      a,11
        call    t_expect_z
        ld      a,e
        cp      2
        ld      a,12
        call    t_expect_z
        ld      a,ixl
        cp      2                       ; UNET_RXF_MORE
        ld      a,13
        call    t_expect_z

; --- Scenario 4: ng_c_recv_poll (the C-callable wrapper) sets IY=0 itself
; and mirrors the same dispatch into ng_v_call_status/len/flags/cf. -------
        call    ng_c_recv_poll
        ld      a,(ng_v_call_cf)
        or      a
        ld      a,14
        call    t_expect_z
        ld      a,(ng_v_call_status)
        or      a
        ld      a,15
        call    t_expect_z
        ld      hl,(ng_v_call_len)
        ld      de,2
        or      a
        sbc     hl,de
        ld      a,16
        call    t_expect_z
        ld      hl,(ng_v_call_flags)
        ld      de,2
        or      a
        sbc     hl,de
        ld      a,17
        call    t_expect_z

; --- Scenario 5: ng_c_send's overflow path (oversized length, ng_send's
; own NERR_PARAM branch) still populates ng_v_call_cf/status -- the C
; caller must be able to tell "argument rejected" from "dispatch failed"
; either way. ---------------------------------------------------------------
        ld      hl,test_src_65
        ld      (ng_c_send_ptr),hl
        ld      a,65
        ld      (ng_c_send_len),a
        call    ng_c_send
        ld      a,(ng_v_call_cf)
        or      a
        ld      a,18
        call    t_expect_nz
        ld      a,(ng_v_call_status)
        cp      9                       ; NERR_PARAM
        ld      a,19
        call    t_expect_z

; --- Scenario 6: ng_c_connect resolves NETHOST/NETPORT itself; the env
; stub above always reports "not found", so this also proves the
; compiled-in defaults (127.0.0.1/7777) reach CONNECT correctly. ---------
        call    ng_c_connect
        ld      a,(ng_v_call_cf)
        or      a
        ld      a,20
        call    t_expect_z
        ld      a,(test_dll_connect_match)
        or      a
        ld      a,21
        call    t_expect_nz

        call    t_end
        halt

        assert  $ < TEST_RESULT

test_src_65: DB "oversized-send-payload-content-is-never-read-before-the-length-check",0
test_src_64: DB "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzABCDEFGHIJKL"

ng_test_install_lib:
        ld      hl,LIBMAN.lib_table
        ld      (hl),1
        inc     hl
        ld      (hl),7
        inc     hl
        ld      (hl),#40
        inc     hl
        ld      (hl),0
        ld      hl,0
        ld      (ng_handle),hl
        ret

test_status_seen:       DB 0
test_dll_send_called:   DB 0
test_dll_send_de_lo:    DB 0
test_dll_send_de_hi:    DB 0
test_dll_send_match:    DB 0
test_dll_connect_match: DB 0
test_recv_reply:        DB "Hi"
connect_default_host:   DB "127.0.0.1",0
connect_default_port:   DB "7777",0

; Fake DLL jump table, indexed directly by function number (t_net_gate.
; asm's own established shape) -- but using the REAL UNET_FN_* numbers
; this time (unet.inc, INCLUDEd by net_gate.asm below), since this test
; drives the real ng_connect/ng_send/ng_recv, not synthetic scenarios.
        assert  $ < #4020
        ds      #4020-$,0
fake_dll_table:
        jp      fake_dll_unused         ; 0 INIT
        jp      fake_dll_unused         ; 1 FREE
        jp      fake_dll_unused         ; 2 GETCAPS
        jp      fake_dll_unused         ; 3 NETINIT
        jp      fake_dll_unused         ; 4 NETDONE
        jp      fake_dll_connect        ; 5 UNET_FN_CONNECT
        jp      fake_dll_send           ; 6 UNET_FN_SEND
        jp      fake_dll_recv           ; 7 UNET_FN_RECV

; UNET_FN_SEND: A=channel, DE=buffer, IX=length -> A, DE=bytes sent.
; Records whether DE points at ng_buf_tx (not the caller's own WIN1
; source buffer) and whether the 64 staged bytes match test_src_64.
fake_dll_send:
        ld      a,1
        ld      (test_dll_send_called),a
        ld      a,e
        ld      (test_dll_send_de_lo),a
        ld      a,d
        ld      (test_dll_send_de_hi),a

        ex      de,hl                   ; HL = staged buffer (ng_buf_tx)
        ld      de,test_src_64
        ld      b,64
.cmp:
        ld      a,(de)
        cp      (hl)
        jr      nz,.mismatch
        inc     hl
        inc     de
        djnz    .cmp
        ld      a,1
        ld      (test_dll_send_match),a
        jr      .done
.mismatch:
        xor     a
        ld      (test_dll_send_match),a
.done:
        ld      de,64
        xor     a
        ret

; UNET_FN_RECV: A=channel, DE=buffer, IX=max, IY=timeout -> A, DE=received,
; IX=flags. Always answers "Hi" with RXF_MORE set (bit 1), so the caller
; can be asserted to have passed the flags/length through unmangled.
fake_dll_recv:
        ex      de,hl                   ; HL = caller's buffer (ng_buf_rx)
        ld      de,test_recv_reply
        ld      a,(de)
        ld      (hl),a
        inc     hl
        inc     de
        ld      a,(de)
        ld      (hl),a
        ld      de,2
        ld      ix,2
        xor     a
        ret

; UNET_FN_CONNECT: A=channel, DE=host ASCIIZ (ng_buf_host), IX=port ASCIIZ
; (ng_buf_port) -> A. Records whether both match the compiled-in defaults.
fake_dll_connect:
        ex      de,hl                   ; HL = host ptr
        ld      de,connect_default_host
        call    fake_streq
        jr      nz,.mismatch
        push    ix
        pop     hl                      ; HL = port ptr
        ld      de,connect_default_port
        call    fake_streq
        jr      nz,.mismatch
        ld      a,1
        ld      (test_dll_connect_match),a
        xor     a
        ret
.mismatch:
        xor     a
        ld      (test_dll_connect_match),a
        xor     a
        ret

; Compare ASCIIZ HL and DE. Z if equal (matches to the NUL), NZ on the
; first mismatching byte. Clobbers AF, HL, DE.
fake_streq:
        ld      a,(de)
        cp      (hl)
        ret     nz
        or      a
        ret     z
        inc     hl
        inc     de
        jr      fake_streq

fake_dll_unused:
        ld      a,#66
        scf
        ret

        assert  $ < #8000
        ds      #8000-$,0

        include "im2_s1.asm"
        include "text640.asm"
        include "buffers.asm"

        DEFINE  LIBMAN_MAX_LIBS 1
        DEFINE  LIBMAN_DIAGNOSTICS
        DEFINE  LIBMAN_NO_LEGACY_API
        include "libman.asm"
        include "net_gate.asm"

        end     start
