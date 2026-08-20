; z80 unit test for the S9 MQTT-lag fix (2026-08-19): a human tester found
; MQTT chat typing and board-cursor navigation laggy and dropping keys while
; DIRECT was smooth. Source reading found three converging causes, two of
; which are covered here (the third, SETOPT CANCELKEYS, is an asm-only
; change in net_gate.asm with nothing this harness can observe):
;
;   1. Every inbound QoS1 PUBLISH used to trigger an IMMEDIATE, standalone
;      PUBACK send -- 4 bytes the broker has nothing to piggyback a reply
;      on, so its TCP ACK comes back on the broker's own delayed-ACK timer
;      (40-200ms) instead of immediately, and that stall sat inside a
;      blocking SEND on the critical path of every inbound message. FIXED:
;      net_mqtt_puback() now only latches the id (net_mqtt_puback_pending);
;      net_mqtt_send_body() prefixes it onto whatever this client next sends
;      anyway (an ACK, a PUBLISH, or worst case the next PINGREQ).
;   2. net_mqtt_read_payload() had NO frame_wait() pacing at all when idle,
;      running the MQTT frame loop at roughly twice DIRECT's rate -- which
;      doubled the rate of PING/PINGREQ traffic and the blocking sends that
;      go with it. FIXED: one frame_wait() on an empty poll, matching ZX's
;      own WAIT_POLL=2 (minus the one frame main.c's own loop already
;      waits) -- and spectrum_net_read_payload (DIRECT) was brought DOWN
;      from two waits to the same one, since it had drifted the other way.
;
; WHAT THIS RUNS. The real WIN1+WIN2 resident image (build/sprinter/
; resident.bin -- net_send_raw, net_mqtt_puback, net_mqtt_read_payload,
; spectrum_net_read_payload, spectrum_net_send_text, all byte-identical to
; what SHATRANJ.EXE ships) INCBINed at #4000 and called directly, the same
; "run the shipped bytes" discipline t_menu_flip.asm/t_net_frame_blob.asm
; already use here -- see t_menu_flip.asm's own banner for why source
; reading alone is not trusted on this port. Three net_gate.asm entry
; points are patched to test stubs (3-byte `jp`, same technique t_menu_flip
; uses to stub saveload_full_redraw, just with a live body instead of a
; bare RET): ng_c_recv_poll (delivers scripted MQTT PUBLISH bytes or
; nothing), ng_c_send (logs what would go out and answers OK/BUSY on
; script), and frame_wait (counts calls instead of actually blocking --
; without this a single scenario's 250-tick keepalive window would need to
; simulate 250 real frame waits, and this test needs three such windows).
; Nothing below the net_gate.asm funnel (libman, the DLL, the DSS ISR) is
; exercised -- t_net_core.asm's own banner draws the same line.
;
; z88dk classic calling convention (__smallc, confirmed the same way
; t_net_frame_blob.asm confirms it: by reading a real compiled multi-arg
; call site rather than trusting the ABI table): arguments pushed
; left-to-right, first argument deepest, caller cleans the stack, return
; value in HL (uint8_t results land in L).
;
; WHAT THIS CANNOT COVER: SETOPT CANCELKEYS removal (net_gate.asm, no C-
; visible effect to assert on) and real broker timing (delayed-ACK, RTT) --
; both are MAME/hardware-only, tracked in docs/sprinter-testnotes/S9.md.

        device  noslot64k
        org     0
        jp      start
        ds      #0100-$,0

        include "harness.inc"
        include "fixed_layout.inc"
        include "resident_test_defs.inc"
        include "platform_test_defs.inc"

NETCHESSZX_TRANSPORT_DIRECT EQU 0
NETCHESSZX_TRANSPORT_MQTT   EQU 1
TEST_NERR_OK    EQU 0
TEST_NERR_SEND  EQU 5
TEST_NERR_BUSY  EQU 13
TEST_READ_TIMEOUT EQU -3       ; SPECTRUM_LINK_READ_TIMEOUT / NC_NO_LINE
TEST_LINK_DOWN    EQU -2       ; NC_LINK_DOWN_RC / NC_LINK_DOWN

TEST_SP EQU #3F00

start:
        ld      sp,TEST_SP
        call    t_begin

        ; --- Patch the three net_gate.asm/im2_s1.asm entry points this
        ; test drives, each a 3-byte `jp stub` over the routine's real
        ; first instruction (all >=3 bytes: `ld hl,(nn)`/`ld iy,nn`/
        ; `call nn`) -- never re-entered, so the partial original
        ; instruction left behind is dead bytes, not a hazard.
        ld      a,#C3                   ; JP opcode
        ld      (plat_ng_c_recv_poll),a
        ld      hl,stub_recv_poll
        ld      (plat_ng_c_recv_poll+1),hl

        ld      a,#C3
        ld      (plat_ng_c_send),a
        ld      hl,stub_send
        ld      (plat_ng_c_send+1),hl

        ld      a,#C3
        ld      (plat_frame_wait),a
        ld      hl,stub_frame_wait
        ld      (plat_frame_wait+1),hl

        ; Deterministic short room code -- avoids depending on whatever
        ; garbage a raw INCBIN leaves in netchesszx_mqtt_code's BSS slot
        ; (this harness never runs crt0's BSS clear). Only its LENGTH
        ; matters to anything asserted below (keeps the built topic short
        ; and bounded); its content is never itself checked.
        ld      a,'R'
        ld      (res_netchesszx_mqtt_code),a
        ld      a,'1'
        ld      (res_netchesszx_mqtt_code+1),a
        xor     a
        ld      (res_netchesszx_mqtt_code+2),a

        xor     a
        ld      (recv_script_len),a
        ld      (send_fail_countdown),a
        ld      hl,0
        ld      (recv_poll_count),hl
        ld      (frame_wait_count),hl
        ld      (send_call_count),hl
        ld      a,TEST_NERR_OK
        ld      (send_script_status),a

; =====================================================================
; Scenario 1: MQTT idle read pacing -- one frame_wait, two recv polls,
; no send, SPECTRUM_LINK_READ_TIMEOUT back.
; =====================================================================
        ld      a,NETCHESSZX_TRANSPORT_MQTT
        ld      (res_netchesszx_transport),a
        call    res_spectrum_net_mqtt_link_reset

        ld      hl,(frame_wait_count)
        ld      (snap_fw),hl
        ld      hl,(recv_poll_count)
        ld      (snap_recv),hl
        ld      hl,(send_call_count)
        ld      (snap_send),hl

        call    do_mqtt_read
        ld      de,TEST_READ_TIMEOUT
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,1
        call    t_expect_z

        ld      hl,(frame_wait_count)
        ld      de,(snap_fw)
        or      a
        sbc     hl,de
        dec     hl
        ld      a,h
        or      l
        ld      a,2
        call    t_expect_z              ; exactly one frame_wait

        ld      hl,(recv_poll_count)
        ld      de,(snap_recv)
        or      a
        sbc     hl,de
        dec     hl
        dec     hl
        ld      a,h
        or      l
        ld      a,3
        call    t_expect_z              ; exactly two recv polls

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,4
        call    t_expect_z              ; no send while idle

; =====================================================================
; Scenario 2: an inbound QoS1 PUBLISH (id 7, payload "hi") is delivered
; to the caller and PUBACKed -- but not sent yet (deferred).
; =====================================================================
        ld      hl,(send_call_count)
        ld      (snap_send),hl

        ld      hl,publish_id7_bytes
        ld      (recv_script_ptr),hl
        ld      a,9
        ld      (recv_script_len),a
        call    do_mqtt_read
        ld      a,h
        or      l
        ld      a,5
        call    t_expect_z              ; success

        ld      a,(mqtt_payload_out+0)
        cp      'h'
        ld      a,6
        call    t_expect_z
        ld      a,(mqtt_payload_out+1)
        cp      'i'
        ld      a,7
        call    t_expect_z
        ld      a,(mqtt_payload_out+2)
        or      a
        ld      a,8
        call    t_expect_z

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,9
        call    t_expect_z              ; PUBACK deferred, nothing sent

; =====================================================================
; Scenario 3: sending "ACK PING" now piggybacks the pending PUBACK (id 7)
; as a 4-byte prefix ahead of the PUBLISH -- one send, not two.
; =====================================================================
        ld      hl,(send_call_count)
        ld      (snap_send),hl

        ld      hl,ack_ping_str
        push    hl
        call    res_spectrum_net_send_text
        pop     de

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        dec     hl
        ld      a,h
        or      l
        ld      a,10
        call    t_expect_z              ; exactly one send

        ld      a,(send_log_buf+0)
        cp      #40
        ld      a,11
        call    t_expect_z
        ld      a,(send_log_buf+1)
        cp      #02
        ld      a,12
        call    t_expect_z
        ld      a,(send_log_buf+2)
        cp      #00
        ld      a,13
        call    t_expect_z
        ld      a,(send_log_buf+3)
        cp      7
        ld      a,14
        call    t_expect_z

; =====================================================================
; Scenario 4: two more PUBLISHes (id 8, then id 9) arrive before this
; client sends anything else. The first (8) is deferred with nothing to
; piggyback on yet; the second (9) collides with it, so id 8's PUBACK is
; flushed on its own (4 bytes, no piggyback) and id 9 takes the slot.
; =====================================================================
        ld      hl,(send_call_count)
        ld      (snap_send),hl

        ld      hl,publish_id8_bytes
        ld      (recv_script_ptr),hl
        ld      a,9
        ld      (recv_script_len),a
        call    do_mqtt_read
        ld      a,h
        or      l
        ld      a,15
        call    t_expect_z

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,16
        call    t_expect_z              ; id 8 deferred, nothing sent yet

        ld      hl,(send_call_count)
        ld      (snap_send),hl

        ld      hl,publish_id9_bytes
        ld      (recv_script_ptr),hl
        ld      a,9
        ld      (recv_script_len),a
        call    do_mqtt_read
        ld      a,h
        or      l
        ld      a,17
        call    t_expect_z

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        dec     hl
        ld      a,h
        or      l
        ld      a,18
        call    t_expect_z              ; id 8's PUBACK flushed on its own

        ld      a,(send_log_len)
        cp      4
        ld      a,19
        call    t_expect_z
        ld      a,(send_log_buf+0)
        cp      #40
        ld      a,20
        call    t_expect_z
        ld      a,(send_log_buf+1)
        cp      #02
        ld      a,21
        call    t_expect_z
        ld      a,(send_log_buf+2)
        cp      #00
        ld      a,22
        call    t_expect_z
        ld      a,(send_log_buf+3)
        cp      8
        ld      a,23
        call    t_expect_z

; =====================================================================
; Scenario 5: 250 more idle polls (id 9 still pending) trip the broker-
; keepalive PINGREQ -- which must go out with id 9's PUBACK prefixed
; ahead of it, same coalescing path as any other send.
; =====================================================================
        ld      bc,249
loop5:
        push    bc
        call    do_mqtt_read
        pop     bc
        dec     bc
        ld      a,b
        or      c
        jr      nz,loop5

        ld      hl,(send_call_count)
        ld      (snap_send),hl

        call    do_mqtt_read
        ld      de,TEST_READ_TIMEOUT
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,24
        call    t_expect_z

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        dec     hl
        ld      a,h
        or      l
        ld      a,25
        call    t_expect_z              ; exactly one send: the PINGREQ

        ld      a,(send_log_len)
        cp      6
        ld      a,26
        call    t_expect_z
        ld      a,(send_log_buf+0)
        cp      #40
        ld      a,27
        call    t_expect_z
        ld      a,(send_log_buf+1)
        cp      #02
        ld      a,28
        call    t_expect_z
        ld      a,(send_log_buf+2)
        cp      #00
        ld      a,29
        call    t_expect_z
        ld      a,(send_log_buf+3)
        cp      9
        ld      a,30
        call    t_expect_z
        ld      a,(send_log_buf+4)
        cp      #c0
        ld      a,31
        call    t_expect_z
        ld      a,(send_log_buf+5)
        cp      #00
        ld      a,32
        call    t_expect_z

; =====================================================================
; Scenario 6: a second keepalive window where the DLL keeps answering
; BUSY (the busy-retry ladder exhausts NC_SEND_BUSY_RETRY_MAX) must NOT
; be reported as the link going down -- BUSY means "try again", not
; "gone" (docs/UNETRTL.md); only a genuine miss run reaches the misses
; ceiling and reports NC_LINK_DOWN_RC.
; =====================================================================
        ld      a,TEST_NERR_BUSY
        ld      (send_script_status),a

        ld      bc,249
loop6:
        push    bc
        call    do_mqtt_read
        pop     bc
        dec     bc
        ld      a,b
        or      c
        jr      nz,loop6

        call    do_mqtt_read
        ld      de,TEST_READ_TIMEOUT
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,33
        call    t_expect_z              ; still READ_TIMEOUT, not LINK_DOWN

        ld      a,TEST_NERR_OK
        ld      (send_script_status),a

; =====================================================================
; Scenario 7: spectrum_net_mqtt_link_reset() must clear a pending PUBACK
; -- the next send must NOT carry a stale prefix.
; =====================================================================
        call    res_spectrum_net_mqtt_link_reset

        ld      hl,(send_call_count)
        ld      (snap_send),hl

        ld      hl,ack_ping_str
        push    hl
        call    res_spectrum_net_send_text
        pop     de

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        dec     hl
        ld      a,h
        or      l
        ld      a,34
        call    t_expect_z              ; exactly one send

        ld      a,(send_log_buf+0)
        cp      #32                     ; bare PUBLISH header, no PUBACK prefix
        ld      a,35
        call    t_expect_z

; =====================================================================
; Scenario 8: DIRECT parity -- same one-wait idle pacing, plain line
; send with no MQTT framing at all.
; =====================================================================
        xor     a
        ld      (res_netchesszx_transport),a   ; NETCHESSZX_TRANSPORT_DIRECT
        call    res_spectrum_net_start_uart

        ld      hl,(frame_wait_count)
        ld      (snap_fw),hl
        ld      hl,(recv_poll_count)
        ld      (snap_recv),hl

        ld      hl,direct_payload_out
        push    hl
        ld      hl,40
        push    hl
        call    res_spectrum_net_read_payload
        pop     de
        pop     de
        ld      de,TEST_READ_TIMEOUT
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,36
        call    t_expect_z

        ld      hl,(frame_wait_count)
        ld      de,(snap_fw)
        or      a
        sbc     hl,de
        dec     hl
        ld      a,h
        or      l
        ld      a,37
        call    t_expect_z              ; exactly one frame_wait

        ld      hl,(recv_poll_count)
        ld      de,(snap_recv)
        or      a
        sbc     hl,de
        dec     hl
        dec     hl
        ld      a,h
        or      l
        ld      a,38
        call    t_expect_z              ; exactly two recv polls

        ld      hl,(send_call_count)
        ld      (snap_send),hl

        ld      hl,ping_str
        push    hl
        call    res_spectrum_net_send_text
        pop     de
        ld      a,l
        cp      1
        ld      a,39
        call    t_expect_z              ; send reported success

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        dec     hl
        ld      a,h
        or      l
        ld      a,40
        call    t_expect_z              ; exactly one send

        ld      a,(send_log_len)
        cp      5
        ld      a,41
        call    t_expect_z
        ld      a,(send_log_buf+0)
        cp      'P'
        ld      a,42
        call    t_expect_z
        ld      a,(send_log_buf+1)
        cp      'I'
        ld      a,43
        call    t_expect_z
        ld      a,(send_log_buf+2)
        cp      'N'
        ld      a,44
        call    t_expect_z
        ld      a,(send_log_buf+3)
        cp      'G'
        ld      a,45
        call    t_expect_z
        ld      a,(send_log_buf+4)
        cp      #0a
        ld      a,46
        call    t_expect_z

; =====================================================================
; Scenario 9: THE FULL-DUPLEX RACE. The RTL DLL returns NERR_SEND for
; F_BAD_SEG (peer data crossed our SEND before its ACK landed) exactly
; as it does for a real dead-link timeout. net_send_raw must DRAIN and
; RESEND on NERR_SEND (up to NC_SEND_RESEND_RETRY_MAX), not treat it as
; fatal -- that transient race dropped a healthy MQTT game on a capture
; move (human tester, 2026-08-19). Script two NERR_SEND answers then OK:
; the send must still succeed, having called ng_c_send three times.
; =====================================================================
        ld      hl,(send_call_count)
        ld      (snap_send),hl

        ld      a,2
        ld      (send_fail_countdown),a     ; 2x NERR_SEND, then OK
        ld      hl,ping_str
        push    hl
        call    res_spectrum_net_send_text
        pop     de
        ld      a,l
        cp      1
        ld      a,47
        call    t_expect_z                  ; resent, then succeeded

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        ld      de,3
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,48
        call    t_expect_z                  ; exactly 3 ng_c_send calls

; =====================================================================
; Scenario 10: a peer that never catches up -- NERR_SEND forever. The
; bounded resend budget must give up (fatal, return 0) rather than
; retry endlessly OR fall into the 50-deep BUSY ladder: 1 initial send +
; NC_SEND_RESEND_RETRY_MAX (3) resends = exactly 4 ng_c_send calls.
; =====================================================================
        ld      hl,(send_call_count)
        ld      (snap_send),hl

        ld      a,250
        ld      (send_fail_countdown),a     ; effectively forever
        ld      hl,ping_str
        push    hl
        call    res_spectrum_net_send_text
        pop     de
        ld      a,l
        or      a
        ld      a,49
        call    t_expect_z                  ; reported failure

        ld      hl,(send_call_count)
        ld      de,(snap_send)
        or      a
        sbc     hl,de
        ld      de,4
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,50
        call    t_expect_z                  ; exactly 4 sends (1 + 3 resends)

        xor     a
        ld      (send_fail_countdown),a     ; leave the stub clean

        call    t_end
        halt

; --- helpers --------------------------------------------------------------

; spectrum_net_read_payload(mqtt_payload_out, 40) -- two-argument classic
; call, first argument deepest. Returns HL.
do_mqtt_read:
        ld      hl,mqtt_payload_out
        push    hl
        ld      hl,40
        push    hl
        call    res_spectrum_net_read_payload
        pop     de
        pop     de
        ret

; --- net_gate.asm / im2_s1.asm stubs ---------------------------------------

; Replaces ng_c_recv_poll. One-shot: delivers recv_script_len bytes from
; (recv_script_ptr) into ng_buf_rx with RXF_MORE clear (so nc_pump_sink's
; own internal retry loop never asks a second time), then clears the
; script so the next call reports an empty poll -- matching a real DLL
; that has nothing left queued once it has handed over what it had.
stub_recv_poll:
        ld      hl,(recv_poll_count)
        inc     hl
        ld      (recv_poll_count),hl

        xor     a
        ld      (plat_ng_v_call_cf),a
        ld      (plat_ng_v_call_status),a
        ld      hl,0
        ld      (plat_ng_v_call_flags),hl

        ld      a,(recv_script_len)
        or      a
        jr      z,.rp_empty
        ld      c,a
        ld      b,0
        ld      hl,(recv_script_ptr)
        ld      de,plat_ng_buf_rx
        ldir
        ld      a,(recv_script_len)
        ld      l,a
        ld      h,0
        ld      (plat_ng_v_call_len),hl
        xor     a
        ld      (recv_script_len),a
        ret
.rp_empty:
        ld      hl,0
        ld      (plat_ng_v_call_len),hl
        ret

; Replaces ng_c_send. Logs the packet (ng_c_send_ptr/len) into send_log_buf/
; send_log_len, counts the call, and answers a status: while send_fail_
; countdown is non-zero it returns NERR_SEND (and decrements), modelling the
; DLL's F_BAD_SEG full-duplex race that net_send_raw must drain-and-resend
; through; otherwise it returns send_script_status (NERR_OK or NERR_BUSY).
stub_send:
        ld      hl,(send_call_count)
        inc     hl
        ld      (send_call_count),hl

        ld      a,(plat_ng_c_send_len)
        ld      (send_log_len),a
        or      a
        jr      z,.sd_nocopy
        ld      c,a
        ld      b,0
        ld      hl,(plat_ng_c_send_ptr)
        ld      de,send_log_buf
        ldir
.sd_nocopy:
        ld      a,(send_fail_countdown)
        or      a
        jr      z,.sd_status
        dec     a
        ld      (send_fail_countdown),a
        ld      a,TEST_NERR_SEND
        ld      (plat_ng_v_call_status),a
        xor     a
        ld      (plat_ng_v_call_cf),a
        ret
.sd_status:
        ld      a,(send_script_status)
        ld      (plat_ng_v_call_status),a
        xor     a
        ld      (plat_ng_v_call_cf),a
        ret

; Replaces frame_wait. Counts instead of blocking -- this test drives three
; 250-idle-tick keepalive windows and cannot afford to simulate real frame
; timing for any of them.
stub_frame_wait:
        ld      hl,(frame_wait_count)
        inc     hl
        ld      (frame_wait_count),hl
        ret

; --- scripted MQTT PUBLISH packets -----------------------------------------
; Fixed header (QoS1, no DUP/RETAIN) + 1-byte topic "x" (irrelevant to every
; assertion here -- short only to keep the packet minimal) + 2-byte packet
; id + 2-byte payload "hi". 9 bytes total: 0x32 0x07 0x00 0x01 'x' idHi idLo
; 'h' 'i'.
publish_id7_bytes:
        db      #32,#07,#00,#01,#78,#00,#07,#68,#69
publish_id8_bytes:
        db      #32,#07,#00,#01,#78,#00,#08,#68,#69
publish_id9_bytes:
        db      #32,#07,#00,#01,#78,#00,#09,#68,#69

ack_ping_str:
        db      "ACK PING",0
ping_str:
        db      "PING",0

; --- scratch state ----------------------------------------------------------
recv_script_ptr:  dw 0
recv_script_len:  db 0

recv_poll_count:  dw 0
frame_wait_count: dw 0
send_call_count:  dw 0

snap_fw:   dw 0
snap_recv: dw 0
snap_send: dw 0

send_script_status: db 0
send_fail_countdown: db 0
send_log_len:        db 0
send_log_buf:         ds 80

mqtt_payload_out:   ds 48
direct_payload_out: ds 48

; The real WIN1+WIN2 resident image (#4000-#BFFF). Padded with "ds", not
; "org" -- --raw writes a flat file from address 0 and an "org" jump would
; leave the gap unwritten (t_menu_flip.asm/t_net_frame_blob.asm pad the
; same way for the same reason). No cold page is INCBINed: nothing on the
; MQTT/DIRECT read or send path this test drives calls into WIN3 at all.
        ds      #4000-$,0
        incbin  "resident.bin"
        assert  $ == #C000
