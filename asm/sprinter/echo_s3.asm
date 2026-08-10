; echo_s3.asm -- S3's TCP-echo mini-client, driven through net_gate.asm's
; funnel (port.md section 5/S3). WIN2-half only, prefix echo_.
;
; FSM: IDLE -> ('N', via resident_s1.asm's existing hotkey and net_gate's
; net_up_probe; echo_note_net_up reflects the outcome here) -> LOADED ->
; ('C', a blocking CONNECT behind a "CONNECT host:port ESC=CANCEL" notice;
; ESC/Ctrl+Z cancellation is handled entirely inside the DLL via ng_up's
; own SETOPT CANCELKEYS, nothing extra needed here) -> ECHO -> ('D', or a
; detected close/error) -> back to LOADED.
;
; Verification is a pair of rolling byte sums (tx vs rx), not a byte-for-
; byte comparator: a resync comparator is roughly three times the code for
; no more proof value (docs/sprinter-render-budget.md's own "measure, don't
; over-engineer" lesson, echoed here for the wire protocol). Equal sums on
; screen after the sends have had time to round-trip is the pass signal;
; tools/sprinter_echo_server.py's own log is the second observation point
; for a soak run.
;
; echo_tick (called every frame from resident_s1.asm's main_loop,
; unconditionally) polls RECV once, twice only if the first reply set
; RXF_MORE, and sends a fixed-format probe message once every
; ECHO_SEND_PERIOD_FRAMES frames. echo_draw_stats is called from within
; main_loop's EXISTING per-frame DI/WIN3 bracket (no bracket of its own --
; docs/sprinter-render-budget.md's S2 lesson: an extra DI/WIN3 span per
; frame is measurably expensive). Transition notices (connect/close/error)
; use their own one-shot DI/WIN3 bracket instead, exactly like net_gate.
; asm's net_up_probe -- they only fire on state changes, not every frame.

        IFNDEF SPRINTER_ECHO_S3_INC
        DEFINE SPRINTER_ECHO_S3_INC

        INCLUDE "dss.inc"
        INCLUDE "unet.inc"
        INCLUDE "render_layout.inc"

ECHO_STATE_IDLE   EQU 0
ECHO_STATE_LOADED EQU 1
ECHO_STATE_ECHO   EQU 2

ECHO_SEND_PERIOD_FRAMES EQU 50

; NETHOST/NETPORT env buffers. DSS ENVIRON has no destination-capacity
; argument (weatherc.asm's own documented risk, accepted the same way
; here): these are sized for realistic hostnames/IPs and ports, not
; hardened against an arbitrarily long value, and the "CONNECT ..." notice
; message below is sized assuming these bounds are respected.
ECHO_HOST_CAP EQU 24
ECHO_PORT_CAP EQU 6

ECHO_STATS_X    EQU 16
ECHO_TX_SUM_Y   EQU 48
ECHO_RX_SUM_Y   EQU 64
ECHO_SHORT_Y    EQU 80
ECHO_RXF_LOST_Y EQU 96

ECHO_NOTICE_X EQU PANEL_X
ECHO_NOTICE_Y EQU PANEL_NOTICE_Y

; ---------------------------------------------------------------------------
; State transitions driven by hotkeys / net_up_probe.
; ---------------------------------------------------------------------------

; Called from resident_s1.asm's hotkey 'N' handler, right after net_gate.
; asm's net_up_probe. Reflects ng_up's outcome into the echo FSM. Clobbers
; AF.
echo_note_net_up:
        ld      a,(ng_loaded)
        or      a
        jr      z,.not_loaded
        ld      a,(ng_up_reason)
        or      a
        jr      nz,.not_loaded
        ld      a,ECHO_STATE_LOADED
        ld      (echo_state),a
        ret
.not_loaded:
        xor     a
        ld      (echo_state),a
        ret

; Hotkey 'C': only valid from LOADED (from ECHO, press 'D' first -- the S3
; test protocol's own "D -> reconnect" sequence). Reads NETHOST/NETPORT,
; draws a blocking "CONNECT host:port ESC=CANCEL" notice, then blocks in
; ng_connect (main_loop itself is paused for the call's whole duration --
; port.md's documented CONNECT-blocks-up-to-20s risk).
echo_connect_probe:
        ld      a,(echo_state)
        cp      ECHO_STATE_LOADED
        ret     nz

        call    echo_read_net_config
        call    echo_draw_connecting

        ld      hl,echo_buf_host
        ld      de,echo_buf_port
        call    ng_connect
        jr      c,.fail
        or      a
        jr      nz,.fail

        call    echo_reset_counters
        ld      a,ECHO_STATE_ECHO
        ld      (echo_state),a
        ld      de,echo_msg_connected
        jp      echo_draw_notice

.fail:
        ld      de,echo_msg_connect_failed
        jp      echo_draw_notice

; Hotkey 'D': only valid from ECHO. Closes the channel and returns to
; LOADED (still network-initialised; 'C' reconnects without redoing 'N').
echo_disconnect_probe:
        ld      a,(echo_state)
        cp      ECHO_STATE_ECHO
        ret     nz
        call    ng_close
        ld      de,echo_msg_closed_by_user
        jp      echo_note_link_lost

; Hotkey 'L': fetch and show the DLL's last AT/driver response tail
; (unet.inc's LASTERR) -- available regardless of connection state, purely
; diagnostic.
echo_lasterr_probe:
        call    ng_lasterr_fetch
        ld      de,ng_buf_lasterr
        jp      echo_draw_notice

; Shared failure/close path: state -> LOADED, draws a notice. In:
; DE=notice message (preserved across the state write).
echo_note_link_lost:
        ld      a,ECHO_STATE_LOADED
        ld      (echo_state),a
        jp      echo_draw_notice

; ---------------------------------------------------------------------------
; Per-frame driver (resident_s1.asm's main_loop, unconditionally).
; ---------------------------------------------------------------------------

; No-op unless ECHO_STATE_ECHO. One RECV poll, a second only if the first
; reply set RXF_MORE; a SEND probe once every ECHO_SEND_PERIOD_FRAMES
; frames. Clobbers AF, BC, DE, HL, IX, IY.
echo_tick:
        ld      a,(echo_state)
        cp      ECHO_STATE_ECHO
        ret     nz

        call    echo_recv_poll
        ret     c                       ; link lost; already handled

        ld      a,(echo_send_counter)
        inc     a
        cp      ECHO_SEND_PERIOD_FRAMES
        jr      c,.store_counter
        xor     a
        call    echo_send_probe
.store_counter:
        ld      (echo_send_counter),a
        ret

; One or two RECV polls (second only if RXF_MORE was set on the first).
; CF=1 if the link was lost (state already moved to LOADED, notice drawn).
echo_recv_poll:
        ld      iy,0
        call    ng_recv
        jr      c,.lost_dispatch
        cp      NERR_CLOSED
        jr      z,.closed
        or      a
        jr      nz,.lost_dispatch
        call    .account

        ld      a,(echo_last_rxflags)
        bit     1,a                     ; RXF_MORE
        jr      z,.ok

        ld      iy,0
        call    ng_recv
        jr      c,.lost_dispatch
        cp      NERR_CLOSED
        jr      z,.closed
        or      a
        jr      nz,.lost_dispatch
        call    .account
.ok:
        or      a
        ret

.account:
        ld      a,ixl
        ld      (echo_last_rxflags),a
        push    de
        pop     bc
        ld      hl,ng_buf_rx
        jp      echo_rx_account

.closed:
        ld      de,echo_msg_closed
        call    echo_note_link_lost
        scf
        ret
.lost_dispatch:
        ld      de,echo_msg_recv_failed
        call    echo_note_link_lost
        scf
        ret

; Formats and sends one probe message; a failure is treated as link-lost
; (state -> LOADED, notice drawn), matching echo_recv_poll.
echo_send_probe:
        ld      hl,(echo_tx_seq)
        inc     hl
        ld      (echo_tx_seq),hl
        call    echo_format_message

        ld      hl,echo_msg_buf
        ld      b,ECHO_MSG_LEN
        call    ng_send
        jr      c,.fail
        or      a
        jr      nz,.fail

        push    de
        pop     bc
        ld      hl,echo_msg_buf
        jp      echo_tx_account

.fail:
        ld      de,echo_msg_send_failed
        jp      echo_note_link_lost

; Called from resident_s1.asm's main_loop, from WITHIN its existing
; per-frame DI/WIN3 bracket (already DI, WIN3=VRAM_ALIAS_OPAQUE,
; glyph_dest_base resting at buffer 0 -- no setup of its own). Draws the
; rolling sums and counters via font_hex.asm's draw_hex16. Clobbers AF,
; BC, DE, HL, IX.
echo_draw_stats:
        ld      ix,ECHO_STATS_X
        ld      c,ECHO_TX_SUM_Y
        ld      de,(echo_tx_sum)
        call    draw_hex16
        ld      ix,ECHO_STATS_X
        ld      c,ECHO_RX_SUM_Y
        ld      de,(echo_rx_sum)
        call    draw_hex16
        ld      ix,ECHO_STATS_X
        ld      c,ECHO_SHORT_Y
        ld      de,(echo_short_send_count)
        call    draw_hex16
        ld      ix,ECHO_STATS_X
        ld      c,ECHO_RXF_LOST_Y
        ld      de,(echo_rxf_lost_count)
        call    draw_hex16
        ret

; ---------------------------------------------------------------------------
; Accounting (pure arithmetic; tests/sprinter/z80/t_echo_stats.asm).
; ---------------------------------------------------------------------------

; Accumulate BC bytes at HL into the tx rolling sum (16-bit wrapping add)
; and the short-send counter. In: HL=source, BC=count actually sent (per
; ng_send's DE output -- may be less than ECHO_MSG_LEN, or 0). Clobbers
; AF, BC, DE, HL.
echo_tx_account:
        ld      a,c
        cp      ECHO_MSG_LEN
        jr      nz,.short
        ld      a,b
        or      a
        jr      z,.sum
.short:
        push    hl
        push    bc
        ld      hl,(echo_short_send_count)
        inc     hl
        ld      (echo_short_send_count),hl
        pop     bc
        pop     hl
.sum:
        ld      de,(echo_tx_sum)
.loop:
        ld      a,b
        or      c
        jr      z,.store
        ld      a,(hl)
        add     a,e
        ld      e,a
        jr      nc,.noc
        inc     d
.noc:
        inc     hl
        dec     bc
        jr      .loop
.store:
        ld      (echo_tx_sum),de
        ret

; Accumulate BC bytes at HL into the rx rolling sum (16-bit wrapping add)
; and the RXF_LOST counter (from echo_last_rxflags, set by the caller
; immediately before this call). In: HL=source, BC=count received (may be
; 0 -- a poll-idle result). Clobbers AF, BC, DE, HL.
echo_rx_account:
        ld      a,(echo_last_rxflags)
        bit     2,a                     ; RXF_LOST (UART overrun since last call)
        jr      z,.sum
        push    hl
        push    bc
        ld      hl,(echo_rxf_lost_count)
        inc     hl
        ld      (echo_rxf_lost_count),hl
        pop     bc
        pop     hl
.sum:
        ld      de,(echo_rx_sum)
.loop:
        ld      a,b
        or      c
        jr      z,.store
        ld      a,(hl)
        add     a,e
        ld      e,a
        jr      nc,.noc
        inc     d
.noc:
        inc     hl
        dec     bc
        jr      .loop
.store:
        ld      (echo_rx_sum),de
        ret

echo_reset_counters:
        xor     a
        ld      (echo_send_counter),a
        ld      hl,0
        ld      (echo_tx_sum),hl
        ld      (echo_rx_sum),hl
        ld      (echo_short_send_count),hl
        ld      (echo_rxf_lost_count),hl
        ld      (echo_tx_seq),hl
        ret

; ---------------------------------------------------------------------------
; Message formatting.
; ---------------------------------------------------------------------------

echo_msg_template:
        DB      "<SQ:0000:SHTRJ>",10
echo_msg_template_end:
ECHO_MSG_LEN EQU echo_msg_template_end - echo_msg_template

echo_msg_buf: DS ECHO_MSG_LEN,0

; HL=16-bit sequence number. Writes "<SQ:XXXX:SHTRJ>\n" into echo_msg_buf
; (ECHO_MSG_LEN bytes, no NUL -- ng_send takes an explicit length).
; Clobbers AF, BC, DE, HL.
echo_format_message:
        push    hl
        ld      hl,echo_msg_template
        ld      de,echo_msg_buf
        ld      bc,ECHO_MSG_LEN
        ldir
        pop     hl
        ld      a,h
        call    echo_byte_to_hex
        ld      a,d
        ld      (echo_msg_buf+4),a
        ld      a,e
        ld      (echo_msg_buf+5),a
        ld      a,l
        call    echo_byte_to_hex
        ld      a,d
        ld      (echo_msg_buf+6),a
        ld      a,e
        ld      (echo_msg_buf+7),a
        ret

; A=byte. Out: D=high-nibble ASCII hex digit, E=low-nibble ASCII hex
; digit. Clobbers AF, B.
echo_byte_to_hex:
        ld      b,a
        rrca
        rrca
        rrca
        rrca
        call    echo_nibble_to_hex
        ld      d,a
        ld      a,b
        call    echo_nibble_to_hex
        ld      e,a
        ret

; Low nibble of A -> ASCII hex digit in A. Clobbers AF.
echo_nibble_to_hex:
        and     #0F
        cp      10
        jr      c,.digit
        add     a,'A'-10
        ret
.digit:
        add     a,'0'
        ret

; ---------------------------------------------------------------------------
; NETHOST/NETPORT env config and drawing.
; ---------------------------------------------------------------------------

; Try DSS ENVIRON: HL=name (ASCIIZ), DE=dest. Out: CF=0 and dest filled
; (NUL-terminated) if found, CF=1 (dest untouched) otherwise. Clobbers AF.
echo_env_try:
        ld      b,DSS_ENV_GET
        ld      c,DSS_ENVIRON
        rst     RST_DSS
        ret     c
        or      a
        jr      z,.not_found
        or      a
        ret
.not_found:
        scf
        ret

; ASCIIZ HL -> DE (unbounded -- only ever called with this file's own
; short, fixed default strings, or DSS ENVIRON's own destination write
; already having NUL-terminated the source before a copy is even
; considered). Clobbers AF, HL, DE.
echo_strcpy:
        ld      a,(hl)
        ld      (de),a
        or      a
        ret     z
        inc     hl
        inc     de
        jr      echo_strcpy

; Fills echo_buf_host/echo_buf_port from NETHOST/NETPORT, falling back to
; 127.0.0.1/7777. Clobbers AF, HL, DE.
echo_read_net_config:
        ld      hl,echo_env_name_host
        ld      de,echo_buf_host
        call    echo_env_try
        jr      nc,.host_ok
        ld      hl,echo_default_host
        ld      de,echo_buf_host
        call    echo_strcpy
.host_ok:
        ld      hl,echo_env_name_port
        ld      de,echo_buf_port
        call    echo_env_try
        jr      nc,.port_ok
        ld      hl,echo_default_port
        ld      de,echo_buf_port
        call    echo_strcpy
.port_ok:
        ret

; DE=ASCIIZ message. Draws it at (ECHO_NOTICE_X, ECHO_NOTICE_Y). Own
; DI/WIN3 bracket and glyph_dest_base save/restore (net_gate.asm's
; net_up_probe pattern): safe to call from a hotkey dispatch or echo_tick
; regardless of which buffer is currently displayed. Clobbers AF, BC, DE,
; HL, IX.
echo_draw_notice:
        push    de
        call    resolve_buffers
        ld      hl,(front_base)
        ld      (glyph_dest_base),hl
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a

        ld      hl,(front_base)
        pop     de
        ld      ix,ECHO_NOTICE_X
        ld      c,ECHO_NOTICE_Y
        ld      a,1                     ; bg=0, fg=1 (white on black)
        call    text_print

        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        jp      restore_glyph_base
.saved_win3: DB 0

; Builds "CONNECT host:port ESC=CANCEL" into echo_connecting_msg (bounded
; by ECHO_HOST_CAP/ECHO_PORT_CAP so the total stays well inside text640.
; asm's TEXT_STAGE_MAX) and draws it via echo_draw_notice. Clobbers AF,
; BC, DE, HL, IX.
echo_draw_connecting:
        ld      hl,echo_prefix_connect
        ld      de,echo_connecting_msg
        call    echo_strcpy
        ld      hl,echo_buf_host
        call    echo_strcpy
        ld      hl,echo_colon_str
        call    echo_strcpy
        ld      hl,echo_buf_port
        call    echo_strcpy
        ld      hl,echo_suffix_esc
        call    echo_strcpy

        ld      de,echo_connecting_msg
        jp      echo_draw_notice

; ---------------------------------------------------------------------------
; State (WIN2-resident; tools/check_sprinter_net_sections.py pins the
; echo_ prefix to [#8000,#C000)).
; ---------------------------------------------------------------------------
echo_state: DB ECHO_STATE_IDLE

echo_tx_sum:            DW 0
echo_rx_sum:            DW 0
echo_short_send_count:  DW 0
echo_rxf_lost_count:    DW 0
echo_tx_seq:            DW 0
echo_send_counter:      DB 0
echo_last_rxflags:      DB 0

echo_env_name_host: DB "NETHOST",0
echo_env_name_port: DB "NETPORT",0
echo_default_host:  DB "127.0.0.1",0
echo_default_port:  DB "7777",0
echo_buf_host: DS ECHO_HOST_CAP,0
echo_buf_port: DS ECHO_PORT_CAP,0

echo_prefix_connect: DB "CONNECT ",0
echo_colon_str:      DB ":",0
echo_suffix_esc:      DB " ESC=CANCEL",0
; "CONNECT "(8) + host(<=23) + ":"(1) + port(<=5) + " ESC=CANCEL"(11) + NUL
; = 49 worst case; rounded up with margin, still well under text640.asm's
; TEXT_STAGE_MAX (64).
ECHO_CONNECTING_MSG_CAP EQU 56
echo_connecting_msg: DS ECHO_CONNECTING_MSG_CAP,0

echo_msg_connected:       DB "CONNECTED",0
echo_msg_connect_failed:  DB "CONNECT FAILED",0
echo_msg_closed:          DB "CLOSED BY PEER",0
echo_msg_closed_by_user:  DB "CLOSED",0
echo_msg_recv_failed:     DB "RECV ERROR",0
echo_msg_send_failed:     DB "SEND ERROR",0

        ENDIF
