; z80 unit test for asm/sprinter/echo_s3.asm's pure accounting arithmetic:
; echo_tx_account/echo_rx_account (rolling byte sums + short-send/RXF_LOST
; counters). Both are pure CPU logic with no DSS/accelerator involvement,
; so -- like t_bench_poll.asm's bench_frames_reset/bench_poll -- they are
; fully verifiable under z88dk-ticks.
;
; Includes the real chain (font_hex, gfx_core, text640, bench_s2, im2_s1,
; libman, net_gate, echo_s3) so every symbol resolves exactly as it does in
; the resident image (t_bench_poll.asm's precedent for pulling in the full
; chain rather than hand-stubbing dozens of unrelated symbols). Nothing
; this test calls ever executes a DSS RST instruction (echo_tx_account/
; echo_rx_account are pure arithmetic), so unlike t_net_gate.asm this file
; needs no fake RST #10 stub at all.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

; im2_s1.asm's exit_stand/fatal_stack_overflow reference these; neither is
; ever reached by this test (same precedent as t_frame_wait.asm/
; t_im2_table.asm/t_net_gate.asm).
HDR: DS 256,0
svmod_safe: ret

; bench_s2.asm's bench_window_begin references rtc_present/rtc_sample/
; rtc_valid/rtc_second (video_s1.asm, not included here -- its rtc_sample
; RSTs into DSS, which the harness cannot service). Neither this test nor
; echo_tx_account/echo_rx_account ever calls bench_window_begin; a
; placeholder satisfies the symbol references (t_bench_poll.asm precedent).
rtc_present: DB 0
rtc_valid:   DB 0
rtc_second:  DB 0
rtc_sample:  ret

start:
        ld      sp,#e800
        call    t_begin

        ; --- echo_tx_account: a clean full-length send (BC=ECHO_MSG_LEN)
        ; sums its bytes and does not bump the short-send counter.
        ld      hl,0
        ld      (echo_tx_sum),hl
        ld      (echo_short_send_count),hl
        ld      hl,tx_chunk
        ld      bc,ECHO_MSG_LEN
        ASSERT  TX_CHUNK_LEN = ECHO_MSG_LEN
        call    echo_tx_account
        ld      hl,(echo_tx_sum)
        ld      de,TX_CHUNK_SUM
        or      a
        sbc     hl,de
        ld      a,1
        call    t_expect_z
        ld      hl,(echo_short_send_count)
        ld      a,h
        or      l
        ld      a,2
        call    t_expect_z

        ; --- echo_tx_account: a short (truncated) send still sums what
        ; actually went out, and bumps the short-send counter.
        ld      hl,(echo_tx_sum)
        ld      de,TX_CHUNK_HEAD5_SUM
        add     hl,de
        push    hl                      ; expected new sum
        ld      hl,tx_chunk
        ld      bc,5
        call    echo_tx_account
        pop     de
        ld      hl,(echo_tx_sum)
        or      a
        sbc     hl,de
        ld      a,3
        call    t_expect_z
        ld      hl,(echo_short_send_count)
        ld      de,1
        or      a
        sbc     hl,de
        ld      a,4
        call    t_expect_z

        ; --- echo_tx_account: a zero-length "send" (DE=0 from ng_send) is
        ; also a short send and contributes nothing to the sum.
        ld      hl,(echo_tx_sum)
        push    hl
        ld      hl,tx_chunk
        ld      bc,0
        call    echo_tx_account
        pop     de
        ld      hl,(echo_tx_sum)
        or      a
        sbc     hl,de
        ld      a,5
        call    t_expect_z
        ld      hl,(echo_short_send_count)
        ld      de,2
        or      a
        sbc     hl,de
        ld      a,6
        call    t_expect_z

        ; --- echo_rx_account: a clean chunk sums its bytes and, with
        ; RXF_LOST clear, does not bump the loss counter.
        ld      hl,0
        ld      (echo_rx_sum),hl
        ld      (echo_rxf_lost_count),hl
        xor     a
        ld      (echo_last_rxflags),a
        ld      hl,rx_chunk_a
        ld      bc,RX_CHUNK_A_LEN
        call    echo_rx_account
        ld      hl,(echo_rx_sum)
        ld      de,RX_CHUNK_A_SUM
        or      a
        sbc     hl,de
        ld      a,7
        call    t_expect_z
        ld      hl,(echo_rxf_lost_count)
        ld      a,h
        or      l
        ld      a,8
        call    t_expect_z

        ; --- echo_rx_account: a second, split chunk (a packet cut across
        ; two RECV calls) continues the rolling sum across calls.
        ld      hl,(echo_rx_sum)
        ld      de,RX_CHUNK_B_SUM
        add     hl,de
        push    hl
        ld      hl,rx_chunk_b
        ld      bc,RX_CHUNK_B_LEN
        call    echo_rx_account
        pop     de
        ld      hl,(echo_rx_sum)
        or      a
        sbc     hl,de
        ld      a,9
        call    t_expect_z

        ; --- echo_rx_account: an empty chunk (A=NERR_OK,DE=0 poll-idle
        ; result) is a legitimate no-op, not a loss.
        ld      hl,(echo_rx_sum)
        push    hl
        ld      hl,rx_chunk_a
        ld      bc,0
        call    echo_rx_account
        pop     de
        ld      hl,(echo_rx_sum)
        or      a
        sbc     hl,de
        ld      a,10
        call    t_expect_z
        ld      hl,(echo_rxf_lost_count)
        ld      a,h
        or      l
        ld      a,11
        call    t_expect_z

        ; --- echo_rx_account: RXF_LOST set bumps the loss counter, on top
        ; of still accounting the bytes actually received.
        ld      a,4                     ; bit 2 = RXF_LOST
        ld      (echo_last_rxflags),a
        ld      hl,(echo_rx_sum)
        ld      de,RX_CHUNK_A_SUM
        add     hl,de
        push    hl
        ld      hl,rx_chunk_a
        ld      bc,RX_CHUNK_A_LEN
        call    echo_rx_account
        pop     de
        ld      hl,(echo_rx_sum)
        or      a
        sbc     hl,de
        ld      a,12
        call    t_expect_z
        ld      hl,(echo_rxf_lost_count)
        ld      de,1
        or      a
        sbc     hl,de
        ld      a,13
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

; Plain counting bytes, not a real echo message -- these two routines are
; pure arithmetic over whatever bytes they are given, so the exact content
; does not matter, only that the expected sums below are easy to verify by
; hand. tx_chunk is deliberately sized to ECHO_MSG_LEN (the real fixed
; probe-message length) via the ASSERT above, so the "clean full send"
; scenario tests the real boundary, not a stale local constant.
tx_chunk: DB 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
TX_CHUNK_LEN EQU $ - tx_chunk
TX_CHUNK_SUM EQU 136                   ; 1+2+...+16
TX_CHUNK_HEAD5_SUM EQU 15              ; 1+2+3+4+5

rx_chunk_a: DB #10,#10,#10,#10,#10
RX_CHUNK_A_LEN EQU $ - rx_chunk_a
RX_CHUNK_A_SUM EQU 5*#10               ; #50

rx_chunk_b: DB #20,#20,#20
RX_CHUNK_B_LEN EQU $ - rx_chunk_b
RX_CHUNK_B_SUM EQU 3*#20               ; #60

        include "font_hex.asm"
        include "gfx_core.asm"
        include "text640.asm"
        include "bench_s2.asm"
        include "im2_s1.asm"

        DEFINE  LIBMAN_MAX_LIBS 1
        DEFINE  LIBMAN_DIAGNOSTICS
        DEFINE  LIBMAN_NO_LEGACY_API
        include "libman.asm"
        include "net_gate.asm"
        include "echo_s3.asm"

        end     start
