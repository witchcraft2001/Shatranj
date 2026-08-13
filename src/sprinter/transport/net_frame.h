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
#endif

#endif /* SHATRANJ_SPRINTER_TRANSPORT_NET_FRAME_H */
