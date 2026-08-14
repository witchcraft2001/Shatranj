#ifndef SHATRANJ_SPRINTER_TRANSPORT_NET_FRAME_H
#define SHATRANJ_SPRINTER_TRANSPORT_NET_FRAME_H

/*
 * Portable core of the Sprinter DIRECT wire-framing layer (S7, port.md
 * section 3.7): RX byte ring -> line splitter -> fixed-depth line queue,
 * built and linked as its own WIN2 C-blob (fixed_layout.json's
 * NET_FRAME_C region) so it can be called from src/sprinter/transport/
 * unet_link.c (WIN1) while a blocking libman l_call has WIN1 mapped to
 * the DLL. The same .c also builds unmodified under gcc for
 * tests/sprinter/host/test_net_frame.c (S7 step 2) -- no target-only
 * headers here, only <stdint.h>.
 *
 * Populated incrementally: nc_smoke below is step 1's build-pipeline
 * proof (crt0, Makefile splice, defs generator, net-section gate); the
 * real framing state machine is added in step 2.
 */

#include <stdint.h>

/* Build-pipeline smoke test only (S7 step 1): proves the WIN2 C-blob
 * assembles, links at its fixed address, and is callable from WIN1 (via
 * the generated defs.asm) and from the host test runner (via a direct
 * TU link) with the same source and the same answer. */
uint8_t nc_smoke(uint8_t x);

/*
 * Portable DIRECT line-framing core (S7 step 2): a byte-oriented ring is
 * not needed -- nc_feed() consumes each byte immediately, so the only
 * state carried between calls is the in-progress line (nc_line_buf/
 * nc_line_pos) and the completed-line queue below.
 *
 * NC_LINE_MAX mirrors src/spectrum/transport/link.h's
 * SPECTRUM_LINK_PAYLOAD_MAX (48) deliberately, not by coincidence: nc_
 * queue slots are sized for exactly one link.h payload (47 chars + NUL).
 * NC_LINK_DOWN/NC_NO_LINE mirror link.h's read_payload() return
 * convention (-2 = link down, -3 = no data yet / SPECTRUM_LINK_READ_
 * TIMEOUT) so src/sprinter/transport/unet_link.c (step 3) can return
 * nc_line_pop()'s result unmodified.
 */
#define NC_LINE_MAX 48u
#define NC_QUEUE_DEPTH 3u
#define NC_LINK_DOWN (-2)
#define NC_NO_LINE (-3)

/* Resets all framing/queue/fatal-latch state. Call once before any other
 * nc_feed/nc_line_pop/nc_mark_* call -- the flat resident image is loaded
 * fresh every boot, but this WIN2 C-blob has no reachable entry point of
 * its own (asm/sprinter/zcc/net_core_crt0.asm never runs crt0_init for
 * real), so nothing else zeroes these statics. */
void nc_init(void);

/* Feeds `len` freshly-received bytes into the line splitter: '\n'
 * completes a line (enqueued unless empty, oversize, or the queue is
 * full -- see nc_line_pop), '\r' is ignored, everything else accumulates
 * into the in-progress line. A line reaching NC_LINE_MAX-1 characters
 * without a '\n' is marked oversize and its remaining bytes (up to and
 * including the terminating '\n') are discarded as one unit -- the next
 * line starts clean. A partial line with no terminating '\n' persists
 * across calls (may span more than one nc_feed() -- "split across TCP
 * segments" is the normal case, not an error). */
void nc_feed(const uint8_t *data, uint8_t len);

/* Pops the oldest queued line into `out` (NUL-terminated, truncated to
 * out_cap-1 chars if `out` is smaller than the stored line -- defensive
 * only, never actually hit by a caller sized to NC_LINE_MAX).
 * Returns: >=0 the copied line length; NC_NO_LINE if the queue is empty
 * and the link is not latched fatal (keep polling); NC_LINK_DOWN if the
 * queue is empty AND nc_mark_closed()/nc_mark_lost() was called -- the
 * queue always drains first, so a peer FIN/RXF_LOST with buffered lines
 * ahead of it is not lost. */
int16_t nc_line_pop(char *out, uint8_t out_cap);

/* Latch a fatal condition (peer FIN / RXF_LOST). Idempotent, and
 * deliberately indistinguishable to nc_line_pop() -- link.h's contract
 * only has one LINK_DOWN signal (-2); which of the two occurred belongs
 * in the caller's own diagnostics (e.g. ng_lasterr_fetch), not here. */
void nc_mark_closed(void);
void nc_mark_lost(void);

/* Number of complete lines currently queued (test/diagnostic use). */
uint8_t nc_queue_count(void);

#ifdef NETCHESSZX_SPRINTER
/*
 * Target-only glue (S7 step 3): one non-blocking ng_recv poll (via
 * net_gate.asm's ng_c_recv_poll -- see that file's "C-callable wrappers"
 * banner), fed into nc_feed(); repeats once if the first poll's flags
 * said more was already buffered (RXF_MORE, echo_s3.asm's proven two-
 * poll pattern from S3). Marks the link fatal (nc_mark_closed/
 * nc_mark_lost) on a peer FIN or a lost/overrun frame. Not compiled into
 * the host test build: it calls net_gate.asm's C bridge, which does not
 * exist there, and host tests exercise nc_feed()/nc_line_pop() directly
 * with scripted byte sequences instead of a real backend.
 */
void nc_pump(void);

/* Same shape as nc_pump() above, but feeds nc_mqtt_feed() instead of
 * nc_feed() and caps each ng_c_recv_poll() request to the MQTT stream's
 * actual free room (net_gate.asm's ng_c_recv_max cell) rather than the
 * DLL's full 255-byte ceiling -- unlike ZX's UART ring, a Sprinter
 * ng_recv() poll cannot be asked to leave unread bytes for next time, so
 * asking for more than nc_mqtt_feed() has room to keep would lose them
 * outright (S8 step 7, port.md section 3.7). See nc_mqtt_feed()'s own
 * comment for the second line of defense this pairs with. */
void nc_mqtt_pump(void);
#endif

/*
 * MQTT byte-stream reassembler (S8 step 7, port.md section 3.7): a second,
 * independent state machine alongside nc_feed()/nc_line_pop()'s DIRECT
 * line splitter above -- MQTT is a length-prefixed byte stream, not
 * line-oriented, so it cannot reuse '\n'-splitting at all. Shape mirrors
 * src/spectrum/transport/net.c's mqtt_take_stream_packet()/
 * mqtt_consume_stream_packet() (the proven ZX/Next reassembler): a fixed
 * accumulator is fed raw bytes; nc_mqtt_take() resyncs past any leading
 * garbage (bytes that cannot start a real MQTT fixed header), decodes the
 * 1- or 2-byte varint remaining-length, and either says "not enough yet"
 * (0), "malformed or oversize -- the whole accumulator was discarded" (-1),
 * or copies one complete packet out to the packet scratch buffer and
 * returns its length. Same #ifdef'd fixed-vs-local storage split as
 * nc_pump()'s ng_* externs: on Sprinter the accumulator and packet scratch
 * are the fixed low-RAM cells fixed_layout.json reserved in S8 step 1
 * (LOWRAM_MQTT_STREAM/LOWRAM_MQTT_PACKET) so unet_link.c (WIN1) and the
 * future MQTT bring-up code (WIN3 cold page, S8 step 8) can reach a
 * reassembled packet without a window swap -- same reasoning as
 * LOWRAM_RENDER_SHARED; under the host test build they are ordinary
 * static arrays, since nothing outside this TU needs to see them there.
 */
#define NC_MQTT_STREAM_MAX 223u

/* Clears the accumulator AND the fatal latch nc_mark_closed()/
 * nc_mark_lost() set (shared with the DIRECT path -- nc_pump_sink() below
 * marks it fatal regardless of which sink is active) -- the MQTT-path
 * counterpart to nc_init(), for a session that never touches the DIRECT
 * line splitter at all. Call once before any other nc_mqtt_* call. */
void nc_mqtt_reset(void);

/* Appends up to `len` bytes to the accumulator, silently dropping
 * whatever does not fit (NC_MQTT_STREAM_MAX - current length) -- the last
 * line of defense against overrun; nc_mqtt_pump() (Sprinter target only)
 * is the first line, capping how many bytes ng_c_recv_poll() is even
 * asked for. A host-test caller driving this directly has no such
 * upstream cap, so this bound must hold on its own. */
void nc_mqtt_feed(const uint8_t *data, uint8_t len);

/* Resyncs past leading garbage, decodes the fixed-header remaining-length
 * varint, and returns: 0 if the accumulator does not yet hold a complete
 * packet (keep feeding); -1 if the header was malformed (a 2-byte varint
 * continuation byte with its own top bit set, or too large a value) or
 * the decoded packet would exceed SPECTRUM_MQTT_PACKET_MAX -- either way
 * the WHOLE accumulator is discarded, matching mqtt_take_stream_packet()'s
 * "resync from nothing" recovery rather than trying to salvage a
 * corrupt length; otherwise the packet's total length (header + payload),
 * with that many bytes now sitting in the packet scratch buffer, valid
 * until the next nc_mqtt_take() call. Idempotent: calling it again before
 * nc_mqtt_consume() re-copies and re-returns the same packet, it does not
 * remove it from the accumulator. */
int16_t nc_mqtt_take(void);

/* Pointer to the packet scratch buffer nc_mqtt_take() last copied a
 * complete packet into -- valid only after a positive nc_mqtt_take()
 * return, for exactly that many bytes. Exists for callers/tests that need
 * to read the reassembled bytes themselves (spectrum_mqtt_type()/
 * spectrum_mqtt_parse_publish() take a pointer, not this accessor). */
const uint8_t *nc_mqtt_packet(void);

/* Removes the `total` bytes of the most recent successful nc_mqtt_take()
 * from the front of the accumulator, sliding any trailing bytes (an
 * already-arrived start of the next packet) down to offset 0. Caller's
 * responsibility to pass the exact value nc_mqtt_take() returned --
 * unlike nc_line_pop(), there is no queue bookkeeping to catch a mismatch. */
void nc_mqtt_consume(uint8_t total);

#endif /* SHATRANJ_SPRINTER_TRANSPORT_NET_FRAME_H */
