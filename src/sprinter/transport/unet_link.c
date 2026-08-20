/*
 * link.h contract over uNet (S7, port.md section 3.7; MQTT half added S8
 * step 8c). Mechanics (libman/net_gate.asm/the DLL call convention) are
 * already proven by the S3 echo stand; this file is only the contract
 * adapter. DIRECT's role is hardcoded to JOIN, permanently -- not a
 * placeholder pending a future port: uNet has no listen/accept at all, so
 * this file does not implement link.h's spectrum_net_listen/spectrum_net_
 * wait_pc_connect/spectrum_net_preflight_run/spectrum_net_connect_host/
 * spectrum_net_last_ip/spectrum_net_sync_time at all (their only callers,
 * via the spectrum_link_* macros, are in app.c, not linked into this port --
 * see the comment above spectrum_net_direct_peer_mark_valid below). Sprinter
 * can only ever dial out, and the listening side of any DIRECT session (Qt
 * Host, ZX CREATE) is always the session HOST (the NET screen's own
 * net_ui_try_connect() pins the role
 * for exactly this reason). Its host/port used to always resolve from the
 * NETHOST/NETPORT env vars; since S9's NETWORK SETUP pass those are only
 * the seed for an editable pair of fields on the NET screen
 * (src/sprinter/net_ui_sprinter.c) -- MQTT's broker/room are chosen the
 * same screen, role too, added S8 step 8e.
 *
 * Every call into net_gate.asm crosses into WIN2-resident code/state that
 * survives a blocking libman l_call with WIN1 mapped to the DLL (R5); this
 * file never talks to the DLL or libman directly, only through net_gate's
 * ng_ / ng_c_ funnel (bridged by tools/gen_sprinter_platform_defs.py) and
 * net_frame.c's nc_ line-framing core (bridged by tools/gen_sprinter_
 * netframe_defs.py).
 */
#include "spectrum/transport/link.h"
#include "sprinter/transport/net_frame.h"
#include "common/protocol/game_protocol.h"
#include "spectrum/overlay/overlay.h"
#include "spectrum/transport/mqtt_min.h"
#include "spectrum/config/session.h"
#include "spectrum/platform/text.h"

/* Bridged from net_gate.asm. Declared here (not through a target header)
 * for the same reason net_frame.c's nc_pump() declares its own externs:
 * the linker resolves these against the generated platform_defs.asm. */
extern void ng_close(void);
extern void ng_shutdown(void);
extern void ng_lasterr_fetch(void);
extern void ng_c_connect_at(void);
extern void ng_c_send(void);
extern uint8_t ng_v_last_cf;
extern char *ng_c_send_ptr;
extern uint8_t ng_c_send_len;
extern uint8_t ng_v_call_status;
extern uint8_t ng_v_call_cf;
extern char *ng_c_connect_host;
extern char *ng_c_connect_port;

/* mqtt_session_wire.c (S8 step 8c, same WIN1 image now -- SPRINTER_RESIDENT_
 * C_SRC). Declared here rather than via spectrum/transport/net.h, which is
 * ZX/Next's own transport header (pulls in ESP-AT declarations that mean
 * nothing on Sprinter) -- same "short, portable-shaped #include list"
 * reasoning as the net_gate.asm externs above. */
extern const char *spectrum_net_mqtt_out_suffix(void);
extern const char *spectrum_net_mqtt_out_ack_suffix(void);
extern const char *spectrum_net_mqtt_presence_suffix(void);
extern const char *spectrum_net_mqtt_presence_payload(void);
extern void spectrum_net_mqtt_setup_payload(char *out) NETCHESSZX_FASTCALL;

extern void frame_wait(void);

/* Defined later in this file; forward-declared so net_send_raw (below) can
 * call it without relying on an implicit declaration -- sccz80 does not
 * reliably diagnose those, and this file has already paid once for a
 * silent calling-convention mismatch (see spectrum_gui_set_board_view's own
 * history, render_shim.asm). */
void spectrum_net_background_drain(void);

/* unet.inc's NERR_OK/NERR_BUSY/NERR_SEND, needed numerically here (see
 * net_frame.c's own NC_UNET_* comment for why these are duplicated rather
 * than shared via a target header: keeping this file's real #include list
 * short and portable-shaped matters more than avoiding two small literal
 * copies). */
#define NC_UNET_NERR_OK 0u
#define NC_UNET_NERR_SEND 5u
#define NC_UNET_NERR_BUSY 13u
#define NC_LINK_DOWN_RC (-2)

/* docs/UNETRTL.md's documented recovery for a busy TCP channel: drain RX
 * (frees the receive queue SEND was blocked behind), wait a frame, retry.
 * 50 attempts is a hard backstop, not an expected count -- on a healthy
 * link this loop runs once. Exhausting it means the peer stopped
 * acknowledging entirely; send_text() reports failure and the session
 * layer (step 4) treats that as connection loss, per link.h's contract. */
#define NC_SEND_BUSY_RETRY_MAX 50u

/* Bounded resend budget for NERR_SEND, which the RTL DLL returns for TWO
 * distinct outcomes that share the one code (unetrtl.asm's MAP_TCP_SEND_FAIL
 * folds both into NERR_SEND):
 *   - F_BAD_SEG, the full-duplex race: peer data crossed our SEND, so the
 *     cumulative ACK had not yet reached our target when SEND's own bounded
 *     ACK wait returned. This is INSTANT and TRANSIENT -- the DLL rolled the
 *     TCP sequence back (tcp_lib.asm SEND's .UNACKED_DATA -> .RESTORE_SEQ)
 *     and retained the peer bytes as ACK_WAIT_RX_PENDING, so the very next
 *     RECV (our drain) delivers them AND clears the pending state, after
 *     which a resend fills the SAME de-duplicated sequence hole and lands.
 *   - F_TIMEOUT, a genuinely unresponsive peer: four 1s retransmits with no
 *     ACK. SLOW (~4s) and usually fatal.
 * A capture move is exactly when the peer is mid-reply, so the F_BAD_SEG
 * race is common there -- and misreading it as fatal dropped a healthy link
 * with "Link down: publish" (human tester, 2026-08-19). One drain clears the
 * whole pending queue (docs/UNETRTL.md: a single RECV drains every available
 * segment), so the race clears in one resend; this small budget covers a
 * short peer burst while still bounding the wall-clock a truly dead link can
 * cost before net_send_raw gives up (<= (1+MAX) * ~4s). */
#define NC_SEND_RESEND_RETRY_MAX 3u

static uint8_t net_link_activity;
static char net_payload_scratch[SPECTRUM_LINK_PAYLOAD_MAX];
/* TX staging, deliberately NOT net_payload_scratch. link.h's ownership
 * contract: "send_text(), send_ping(), and background_drain() ... must not
 * destroy a queued RX payload before read_payload() copies it" -- and
 * main.c's net_poll_once() hands net_payload_scratch straight to
 * netchesszx_session_poll() as the RX destination. With one shared buffer
 * every ACK/NACK/ACK PING answer would overwrite the very line being
 * processed; that it does not misbehave today is luck of ordering (each
 * caller happens to copy what it needs into locals before replying), and
 * S8's retry ladder and RESTORE chunking are exactly the code that would
 * end that luck. 48 bytes of WIN1 BSS is the whole price. ZX pays the same
 * one differently: there send_text stages in the UART buffer and
 * payload_scratch() borrows the INACTIVE backend's storage (net.c), which
 * is the same rule expressed in the shape that platform allows. */
static char net_tx_line[SPECTRUM_LINK_PAYLOAD_MAX];
/* Set by direct_peer_mark_valid(); consumed by the session/ping layer
 * once step 4 wires it in (not yet -- link.h has no getter for this, only
 * the setter, matching ZX's own shape of a plain state flag the session
 * layer reaches into directly rather than through the link.h surface). */
static uint8_t net_peer_valid;

/* --- MQTT half (S8 step 8c) --------------------------------------------
 * Sprinter's own WIN1 budget is generous enough (unlike ZX's) that
 * publish_presence/publish_setup build and send their packet right here,
 * with no MQTT_TX overlay (id 4, overlay.h) at all -- see the S8 step 8
 * plan's own "Инвариант размещения" for why that is safe: net_mqtt_tx_
 * packet below is a WIN1 intermediate buffer, exactly like net_tx_line
 * above, safe for the same reason (ng_c_send copies out of it before
 * l_call maps the DLL over WIN1). start/activate_side/probe_seat stay
 * overlay dispatches (src/sprinter/net_mqtt_ui_sprinter.c, NET overlay
 * entries 0/1/3) because they are one-shot, user-paced connect-time
 * flows -- the same reasoning net_join_ui_ovl's DIRECT flow already
 * follows, not a byte-budget necessity like ZX's MQTT_TX split. */
static uint16_t net_mqtt_next_id = 1u;
/* 4 bytes ahead of the packet body (spectrum_mqtt_publish/PINGREQ always
 * write starting at NET_MQTT_TX_BODY, +4) for an optional prefixed PUBACK --
 * see net_mqtt_send_body below. */
static uint8_t net_mqtt_tx_packet[4u + SPECTRUM_MQTT_PACKET_MAX];
#define NET_MQTT_TX_BODY (net_mqtt_tx_packet + 4u)
static uint8_t net_mqtt_flags;
static spectrum_mqtt_broker_keepalive_t net_mqtt_broker_keepalive;
/* Packet id of a PUBACK not yet on the wire, 0 = none pending. Set by
 * net_mqtt_puback(), cleared by net_mqtt_send_body() once it actually goes
 * out (see that function's own banner for why PUBACK is deferred at all). */
static uint16_t net_mqtt_puback_pending;

/* Which layer decided the MQTT link was down. NOT diagnostics for their own
 * sake: netchesszx_session_poll() collapses four different failures into one
 * NETCHESSZX_SESSION_POLL_DISCONNECTED return, and it is shared with
 * ZX/Next so it cannot be taught to say more. Without this byte, "Link down"
 * on screen is compatible with the socket having closed, the broker having
 * stopped answering PINGREQ, uNet having refused a send, and the PEER having
 * gone quiet -- four different bugs in four different places. Read by
 * session_sprinter.c's net_poll_once and spelled out on the notice line. */
uint8_t net_mqtt_down_reason;

/* Set by either busy-retry ladder below when it exhausts its whole budget on
 * NERR_BUSY: the packet never went out, but nothing about the link is broken
 * -- uNet's own answer for BUSY is "nothing was sent, try again". link.h's
 * send contract has no third value for that (ZX's UART cannot be busy, so
 * "did not send" there really does mean the link is gone), so it travels
 * beside the return value instead. Cleared at the top of every ladder, so a
 * reader sees the outcome of the send it just made and not an older one.
 * Read by session_sprinter.c's net_send_failed, which re-arms the retransmit
 * timer on this instead of dropping the session -- pressing D for a draw
 * offer and getting "Link down" a couple of seconds later, with the peer
 * showing the offer dialog the whole time, is exactly this case (second MAME
 * round, 2026-08-16). */
uint8_t net_send_busy;

/* Which step of the NET overlay's MQTT sequence gave up, and what uNet made
 * of it. Written by net_mqtt_ui_sprinter.c's mqtt_ovl_fail (see that file
 * for what each step number means and why the ng_v_* snapshot matters), read
 * by the NET screen AND, since the frame loop began dispatching
 * activate_side/probe_seat, by session_sprinter.c. They live here rather
 * than in the overlay's own BSS for exactly that second reader: the overlay
 * page is not mapped once its entry returns, so its BSS is unreadable to
 * every caller outside it. WIN1 is the only storage both can see. */
uint8_t net_mqtt_fail_step;
uint8_t net_mqtt_fail_cf;
uint8_t net_mqtt_fail_status;
/* Which subscribe within a multi-topic step, 1-based (0 = not a subscribe).
   The step alone cannot separate "the channel was already unusable when
   activate_side started" from "the first subscribe's own answer broke the
   next one" -- and those are different bugs. */
uint8_t net_mqtt_fail_detail;

#define NET_MQTT_DOWN_NONE 0u
#define NET_MQTT_DOWN_STREAM 1u     /* nc_mqtt_take latched: peer closed / RX lost */
#define NET_MQTT_DOWN_KEEPALIVE 2u  /* broker missed SPECTRUM_MQTT_KEEPALIVE_MISSES_MAX */
#define NET_MQTT_DOWN_PINGREQ 3u    /* uNet refused the PINGREQ send itself */
#define NET_MQTT_DOWN_PUBLISH 4u    /* a PUBLISH could not be sent at all */

/* Inbound PUBLISHes accepted since the link came up, and how many of those
 * were on the game pair (w2b/b2w). Saturating, so a long game does not wrap
 * them back to a number that reads like silence.
 *
 * These two answer the one question the ping ladder cannot: when the session
 * layer reports the peer lost, is the PEER quiet, or are WE deaf on the game
 * topics? Both look identical from poll.c -- nothing arrived -- but they are
 * different bugs. A rising total with a game count stuck at zero means meta
 * and presence are flowing while the w2b/b2w subscriptions are not; a total
 * stuck at zero means nothing is reaching us at all; both rising means the
 * peer really did go quiet. */
uint8_t net_mqtt_rx_count;
uint8_t net_mqtt_rx_game_count;

/* Session PUBLISHes thrown away by the NET overlay's SUBACK wait
 * (net_mqtt_ui_sprinter.c's mqtt_ovl_wait_type), which discards every packet
 * that is not the type it is waiting for. That helper's own banner states
 * the assumption it was written under -- "no game session is live at any
 * point this helper is used" -- and S8 step 8f broke it by dispatching
 * activate_side/probe_seat from the frame loop. Those discards are not
 * recoverable: the helper never PUBACKs them, and this client connects with
 * a clean session, so the broker has no obligation to redeliver before a
 * reconnect. A non-zero count here means real session traffic was eaten
 * during a subscribe -- exactly the kind of loss that looks from above like
 * a peer that never spoke. Measured rather than assumed. */
uint8_t net_mqtt_ovl_dropped;

/* Every per-link piece of MQTT state this file owns, cleared for a fresh
 * broker session.
 *
 * The keepalive counters are the reason this exists. They are file statics,
 * so they carry across connect attempts inside one run of the program: an
 * attempt that ended with misses already at the limit makes the NEXT
 * attempt's very first idle poll report SPECTRUM_MQTT_KEEPALIVE_LOST, which
 * surfaces as "connected, then Link down immediately" on a link that has
 * done nothing wrong. spectrum_net_mqtt_start() below could not cover this
 * on its own: the NET screen (net_ui_sprinter.c's net_ui_mqtt_connect)
 * dispatches net_mqtt_connect_start_ovl directly, so that path never runs
 * spectrum_net_mqtt_start at all -- which is why the overlay calls this
 * itself, right after the CONNACK is accepted. */
void spectrum_net_mqtt_link_reset(void)
{
    spectrum_mqtt_broker_keepalive_reset(&net_mqtt_broker_keepalive);
    net_mqtt_down_reason = NET_MQTT_DOWN_NONE;
    net_mqtt_fail_detail = 0u;
    net_mqtt_rx_count = 0u;
    net_mqtt_rx_game_count = 0u;
    net_mqtt_ovl_dropped = 0u;
    net_mqtt_next_id = 1u;
    net_mqtt_flags = 0u;
    net_mqtt_puback_pending = 0u;
}

static uint16_t net_mqtt_alloc_id(void)
{
    uint16_t id = net_mqtt_next_id++;

    if (net_mqtt_next_id == 0u) {
        net_mqtt_next_id = 1u;
    }
    return id;
}

/* "netchesszx/v1/<room>/<suffix>" -- byte-identical shape to ZX's own
 * mqtt_tx_ovl.c::mqtt_tx_topic, built from the portable spectrum_append_
 * text (src/spectrum/platform/text.c, same WIN1 image now). */
static void net_mqtt_topic(char *out, const char *suffix)
{
    char *p;

    p = spectrum_append_text(out, "netchesszx/v1/");
    p = spectrum_append_text(p, netchesszx_mqtt_code);
    p = spectrum_append_text(p, "/");
    (void)spectrum_append_text(p, suffix);
}

/* Sends one packet through the DLL. Common to MQTT and DIRECT with a
 * busy-retry ladder (docs/UNETRTL.md's documented recovery for a busy TCP
 * channel: drain RX, wait a frame, retry) -- this used to be two
 * near-identical copies, this one and spectrum_net_send_text's own
 * DIRECT-only ladder, unified during the S9 MQTT-lag fix (2026-08-19) both
 * to save WIN1 bytes and because a bug fixed in one used to need fixing
 * twice.
 *
 * This path used to be a single ng_c_send() that reported NERR_BUSY as
 * failure. That held while every MQTT publish happened at connect time,
 * paced by the NET screen's own modal loop with an idle TX side. It stopped
 * holding when S8 step 8f began publishing from the frame loop: presence and
 * setup now go out immediately after four back-to-back SUBSCRIBEs, with the
 * SUBACKs still streaming in, which is precisely when uNet reports BUSY. A
 * transient BUSY then surfaced as "Activate side failed" -- a healthy link
 * reported as a dead one.
 *
 * Spelled out rather than `(!cf && status == OK) ? 1u : 0u` -- sccz80
 * miscompiles a ternary whose condition contains && or ||, always taking the
 * false branch (tools/check_sccz80_codegen.py is the gate). */
static uint8_t net_send_raw(const uint8_t *packet, uint8_t len)
{
    uint8_t retry;
    uint8_t resend = 0u;

    net_send_busy = 0u;
    for (retry = 0u; retry < NC_SEND_BUSY_RETRY_MAX; ++retry) {
        /* Drain BEFORE the send, not only after a refusal. UNETRTL.md is
         * explicit: "The consumer must drain pending data before another
         * SEND on the same channel" -- the DLL retains a payload-bearing
         * ACK in the channel's own 536-byte queue while SEND waits, and a
         * SEND issued with that queue occupied cannot complete its
         * stop-and-wait handshake. spectrum_net_background_drain() picks
         * nc_mqtt_pump() or nc_pump() by transport -- exactly the RECV each
         * side needs, and on the NERR_SEND retry path below it is also what
         * consumes the peer's ACK_WAIT_RX_PENDING bytes and clears that
         * state so the resend can complete. */
        spectrum_net_background_drain();
        ng_c_send_ptr = (char *)packet;
        ng_c_send_len = len;
        ng_c_send();
        if (ng_v_call_cf) {
            return 0u;
        }
        if (ng_v_call_status == NC_UNET_NERR_OK) {
            return 1u;
        }
        if (ng_v_call_status == NC_UNET_NERR_SEND) {
            /* NOT necessarily fatal -- see NC_SEND_RESEND_RETRY_MAX's banner.
             * The RTL DLL folds the transient full-duplex race (F_BAD_SEG:
             * peer data crossed our SEND) and a real dead link (F_TIMEOUT)
             * into this one code, and rolls the TCP sequence back for both,
             * so a drained resend is safe and de-duplicated by the peer. The
             * drain at the top of the next iteration delivers the pending
             * peer bytes and clears ACK_WAIT_RX_PENDING; the resend then
             * fills the same sequence hole. Bounded so a genuinely dead peer
             * (repeated F_TIMEOUT) still falls through to the fatal branch
             * instead of retrying forever. */
            if (resend < NC_SEND_RESEND_RETRY_MAX) {
                ++resend;
                frame_wait();
                continue;
            }
        } else if (ng_v_call_status == NC_UNET_NERR_BUSY) {
            /* Nothing but a frame wait here, deliberately. The first version
             * of this ladder called key_poll() on every retry, meaning to
             * "keep the latch current" while the main loop was blocked -- it
             * did the exact opposite. key_code is ONE slot: each call took
             * another event out of DSS's 16-entry SBUF and overwrote the
             * previous one, so a BUSY stretch during typing destroyed up to
             * NC_SEND_BUSY_RETRY_MAX keypresses that would otherwise have sat
             * safely in SBUF until the frame loop got back to them. That is
             * the "chat still swallows characters, cursor keys and SPACE get
             * lost" report from the second MAME round (2026-08-16), and it is
             * why the symptom tracked MQTT rather than DIRECT: BUSY is common
             * once presence/PUBACK/PING publishes run from the frame loop,
             * and rare on the DIRECT stream. key_poll() is now latch-
             * preserving as well (im2_s1.asm), so this is belt and braces --
             * but there is still nothing for a poll to do here when no
             * dispatcher can run. */
            frame_wait();
            continue;
        }
        /* Genuinely fatal: NERR_CLOSED (peer reset), NERR_HW (NIC failure),
         * or a NERR_SEND that survived the bounded resend budget above (a
         * peer that really has stopped acknowledging, not the full-duplex
         * race). A send that never landed is why the session layer will
         * decide the peer is gone; without this the notice blames the peer
         * for our own failure to speak. Harmless when this runs for a DIRECT
         * send: net_mqtt_down_reason is only read through the MQTT-gated
         * net_link_down_why, and link_reset clears it on every fresh MQTT
         * connect. */
        net_mqtt_down_reason = NET_MQTT_DOWN_PUBLISH;
        return 0u;
    }
    /* Every retry came back BUSY. Nothing went out and nothing is wrong with
     * the link -- uNet's own answer says "try again". Reported apart from a
     * real failure so the session layer can re-arm its retransmit timer
     * instead of declaring the peer gone (session_sprinter.c's
     * net_send_failed). */
    net_send_busy = 1u;
    return 0u;
}

/* Sends the len bytes already staged at NET_MQTT_TX_BODY, prefixing them
 * with a pending PUBACK's 4 bytes if one is waiting (net_mqtt_puback below).
 *
 * WHY DEFER PUBACK AT ALL. Every inbound QoS1 PUBLISH used to trigger an
 * immediate, standalone PUBACK send -- 4 bytes the broker has nothing to
 * piggyback a reply on, so its TCP ACK comes back on the broker OS's own
 * delayed-ACK timer (typically 40-200ms) instead of immediately. That stall
 * sat inside net_send_raw's blocking SEND, on the critical path of every
 * single inbound message -- exactly the "lag" MQTT had and DIRECT never did
 * (DIRECT's PINGs get a real reply with data, so its ACKs are never
 * standalone). MQTT 3.1.1 places no time bound on PUBACK delivery, so
 * piggybacking it onto whatever this client next sends anyway -- ACK PING,
 * ACK MOVE, a PUBLISH of our own, or worst case the next PINGREQ -- costs
 * nothing and avoids the stall (S9 MQTT-lag fix, 2026-08-19). Worst-case
 * PUBACK delay is one PINGREQ interval (SPECTRUM_MQTT_KEEPALIVE_POLL_TICKS,
 * ~10s of idle), well inside every broker's own in-session PUBLISH retry
 * (mosquitto 1.x 20s, EMQX 30s; 2.x/HiveMQ do not retry within a session at
 * all). */
static uint8_t net_mqtt_send_body(uint8_t len)
{
    uint8_t ok;

    if (net_mqtt_puback_pending != 0u) {
        net_mqtt_tx_packet[0] = 0x40u;
        net_mqtt_tx_packet[1] = 0x02u;
        net_mqtt_tx_packet[2] = (uint8_t)(net_mqtt_puback_pending >> 8);
        net_mqtt_tx_packet[3] = (uint8_t)net_mqtt_puback_pending;
        ok = net_send_raw(net_mqtt_tx_packet, (uint8_t)(len + 4u));
        if (ok) {
            net_mqtt_puback_pending = 0u;
        }
        return ok;
    }
    if (len == 0u) {
        return 1u;
    }
    return net_send_raw(NET_MQTT_TX_BODY, len);
}

static uint8_t net_mqtt_publish_suffix(const char *suffix,
                                       const char *payload,
                                       uint8_t retain)
{
    char topic[SPECTRUM_MQTT_TOPIC_MAX + 1u];
    uint8_t len;

    net_mqtt_topic(topic, suffix);
    len = spectrum_mqtt_publish(NET_MQTT_TX_BODY, SPECTRUM_MQTT_PACKET_MAX,
                                net_mqtt_alloc_id(), topic, payload, retain);
    if (len == 0u) {
        return 0u;
    }
    return net_mqtt_send_body(len);
}

/* QoS1 PUBACK -- packet_id==0 (QoS0) is a deliberate no-op, matching
 * mqtt_min.c's own spectrum_mqtt_parse_publish() contract (*packet_id
 * stays 0 unless the incoming PUBLISH itself was QoS1). Does not send
 * anything itself: latches the id for net_mqtt_send_body to prefix onto
 * this client's next outgoing packet (see that function's own banner for
 * why). */
static void net_mqtt_puback(uint16_t packet_id)
{
    if (packet_id == 0u) {
        return;
    }
    if (net_mqtt_puback_pending != 0u) {
        /* Collision: an older PUBACK is still waiting to piggyback (two
         * PUBLISHes arrived before this client sent anything of its own).
         * Flush it on its own now rather than silently dropping it -- it
         * still has to reach the broker -- and let this one take the slot. */
        (void)net_mqtt_send_body(0u);
    }
    net_mqtt_puback_pending = packet_id;
}

static int16_t net_mqtt_keepalive_tick(void)
{
    uint8_t event = spectrum_mqtt_broker_keepalive_timeout(
        &net_mqtt_broker_keepalive);

    if (event == SPECTRUM_MQTT_KEEPALIVE_NONE) {
        return SPECTRUM_LINK_READ_TIMEOUT;
    }
    if (event == SPECTRUM_MQTT_KEEPALIVE_LOST) {
        net_mqtt_down_reason = NET_MQTT_DOWN_KEEPALIVE;
        return NC_LINK_DOWN_RC;
    }
    NET_MQTT_TX_BODY[0] = SPECTRUM_MQTT_PINGREQ_HEADER;
    NET_MQTT_TX_BODY[1] = 0u;
    /* Through the same ladder and PUBACK-coalescing path as every other
     * send (it used to be a bare, unladdered ng_c_send() -- a transient
     * BUSY on the keepalive send used to read as "Link down: send" on a
     * perfectly healthy link). BUSY is not treated as a failure here: the
     * ladder already retried NC_SEND_BUSY_RETRY_MAX times and net_send_busy
     * says so; the next keepalive tick simply tries again. */
    if (!net_mqtt_send_body(2u) && !net_send_busy) {
        net_mqtt_down_reason = NET_MQTT_DOWN_PINGREQ;
        return NC_LINK_DOWN_RC;
    }
    return SPECTRUM_LINK_READ_TIMEOUT;
}

/* Pump whatever uNet has queued into the reassembler, take one packet if a
 * whole one is ready; one non-blocking poll, plus ONE frame_wait if that
 * poll found nothing -- ZX's own WAIT_POLL=2 (net.c's mqtt_fill_stream)
 * minus the one frame main.c's own poll loop already waits between calls,
 * same accounting as spectrum_net_read_payload below. This used to have NO
 * frame_wait at all, which ran the MQTT frame loop roughly twice the rate
 * DIRECT/ZX run at: PING/PINGREQ (paced in wall-clock ticks, ping.c/
 * SPECTRUM_MQTT_KEEPALIVE_POLL_TICKS) fired twice as often per second, which
 * doubled the rate of the blocking sends that go with them -- part of why
 * MQTT lagged and DIRECT did not (S9 MQTT-lag fix, 2026-08-19). */
static int16_t net_mqtt_read_payload(char *payload, uint8_t payload_cap)
{
    int16_t total;
    int16_t got;
    uint16_t packet_id;
    uint8_t flags;

    net_mqtt_flags = 0u;
    nc_mqtt_pump();
    total = nc_mqtt_take();
    if (total == 0) {
        frame_wait();
        nc_mqtt_pump();
        total = nc_mqtt_take();
    }
    if (total == (int16_t)NC_LINK_DOWN_RC) {
        net_mqtt_down_reason = NET_MQTT_DOWN_STREAM;
        return NC_LINK_DOWN_RC;
    }
    if (total <= 0) {
        return net_mqtt_keepalive_tick();
    }
    spectrum_mqtt_broker_keepalive_reset(&net_mqtt_broker_keepalive);
    net_link_activity = 1u;

    if (spectrum_mqtt_type(nc_mqtt_packet(), (uint8_t)total) !=
        SPECTRUM_MQTT_PUBLISH) {
        nc_mqtt_consume((uint8_t)total);
        return SPECTRUM_LINK_READ_TIMEOUT;
    }

    got = spectrum_mqtt_parse_publish(nc_mqtt_packet(), (uint8_t)total,
                                      payload, payload_cap,
                                      &packet_id, &flags);
    nc_mqtt_consume((uint8_t)total);
    net_mqtt_puback(packet_id);
    if (got < 0) {
        return SPECTRUM_LINK_READ_TIMEOUT;
    }
    net_mqtt_flags = flags;
    if (net_mqtt_rx_count != 255u) {
        ++net_mqtt_rx_count;
    }
    if ((flags & SPECTRUM_LINK_PAYLOAD_GAME_ROUTE) &&
        net_mqtt_rx_game_count != 255u) {
        ++net_mqtt_rx_game_count;
    }
    return 0;
}


/* Outbound routing, byte-for-byte the same four-way split ZX/Next make in
 * mqtt_tx_ovl.c's mqtt_tx_send_text_ovl -- and the reason this port's first
 * live MQTT game never started.
 *
 * Everything used to go to the game topic (w2b/b2w). On DIRECT that is
 * correct by construction, since there is only one channel; on MQTT the
 * room has four, and which one a message goes to IS the protocol
 * (docs/wire-contract.md's topic table). Two consequences, both seen in
 * MAME on 2026-08-15:
 *
 *   - "ACK GAME START" belongs on `meta`, where the host waits for it. Sent
 *     to the game topic it is simply never seen: the host sat on "waiting
 *     opponent ACK" forever with a healthy link and a guest that had already
 *     answered.
 *   - every other "ACK ..." belongs on the ack topic, which is what the peer
 *     subscribes to for replies. Sent to the game topic, ACK MOVE / ACK PING
 *     vanish the same way -- which is also why the session's own PING ladder
 *     eventually reported the peer lost ("Link down: peer ping") on a link
 *     that was carrying our packets perfectly well.
 *
 * NACK deliberately does NOT match the "ACK " test (the prefix compare is
 * anchored at the start) and goes to the game topic -- same as ZX. */
static uint8_t net_mqtt_send_text(const char *text) NETCHESSZX_FASTCALL
{
    if (netchess_after_prefix(text, "ACK GAME START")) {
        return net_mqtt_publish_suffix("meta", text, 0u);
    }
    if (netchess_after_prefix(text, "ACK ")) {
        return net_mqtt_publish_suffix(spectrum_net_mqtt_out_ack_suffix(),
                                       text, 0u);
    }
    if (netchess_after_prefix(text, netchesszx_text_game_start)) {
        return net_mqtt_publish_suffix("meta", text, 0u);
    }
    return net_mqtt_publish_suffix(spectrum_net_mqtt_out_suffix(), text, 0u);
}

void spectrum_net_start_uart(void)
{
    /* Nothing to pre-warm: uNet's "UART" lives entirely inside the DLL,
     * brought up by net_preflight_ovl()'s ng_up() (net_mqtt_ui_sprinter.c).
     * This hook's real job is resetting local framing/activity state before
     * a fresh attempt. */
    nc_init();
    net_link_activity = 0u;
    net_peer_valid = 0u;
}

/* link.h also declares spectrum_net_listen/spectrum_net_wait_pc_connect/
 * spectrum_net_preflight_run/spectrum_net_connect_host/spectrum_net_last_ip/
 * spectrum_net_sync_time. None of them are implemented here (S9 MQTT-lag
 * pass, 2026-08-19, a ~60-byte WIN1 budget valve for that fix): every one of
 * their spectrum_link_* aliases is called only from app.c, which is not
 * linked into the Sprinter build -- this port's own main.c/session_
 * sprinter.c/net_ui_sprinter.c/net_mqtt_ui_sprinter.c call ng_up()/
 * ng_c_connect_at()/net_preflight_ovl() directly instead (net_gate.asm
 * stays the funnel; t_net_core exercises it there). Host role itself is
 * still out of reach on this port regardless -- uNet has no listen/accept
 * at all (port.md section 3.7) -- so spectrum_net_listen/wait_pc_connect
 * would have stayed 0u-returning stubs even implemented. */

void spectrum_net_direct_peer_mark_valid(void)
{
    net_peer_valid = 1u;
}

int16_t spectrum_net_read_payload(char *payload, uint8_t payload_cap)
{
    int16_t rc;

    if (netchesszx_transport_is_mqtt()) {
        return net_mqtt_read_payload(payload, payload_cap);
    }

    /* Empty queue: one non-blocking poll, then ONE frame wait if it still
     * found nothing, then a second poll -- ZX's own WAIT_POLL=2 pacing
     * (net.c's mqtt_fill_stream; direct_ovl.c's direct_read_payload_ovl
     * follows the same constant) minus the one frame main.c's own poll loop
     * already waits between calls, so the total per idle iteration matches
     * ZX's two. This used to wait twice in here (three total per idle
     * iteration), making the DIRECT frame loop tick 1.5x slower than spec
     * -- brought down to match net_mqtt_read_payload's own one-wait pacing
     * above (S9 MQTT-lag fix, 2026-08-19). A queue that
     * already has data skips this entirely, same as ZX's own
     * `direct_rx_count == 0u` guard. */
    if (nc_queue_count() == 0u) {
        nc_pump();
        if (nc_queue_count() == 0u) {
            frame_wait();
            nc_pump();
        }
    }

    rc = nc_line_pop(payload, payload_cap);
    if (rc >= 0) {
        net_link_activity = 1u;
    }
    return rc;
}

uint8_t spectrum_net_send_text(const char *text) NETCHESSZX_FASTCALL
{
    uint8_t len;

    if (netchesszx_transport_is_mqtt()) {
        return net_mqtt_send_text(text);
    }

    /* SPECTRUM_LINK_PAYLOAD_MAX-1 (47), not -2 (46): net_tx_line is
       SPECTRUM_LINK_PAYLOAD_MAX (48) bytes, and the loop below always
       appends one '\n' after the copied text, so up to 47 copied chars +
       1 '\n' = 48 fits exactly. The -2 bound silently dropped a maximal
       CHAT message's last character on DIRECT (only) -- "CHAT " + the
       42-char NETCHESSZX_CHAT_MESSAGE_TEXT_MAX is 47 chars, one past the
       old 46-char ceiling (S9 chat pass, 2026-08-16). Nothing else this
       port sends is longer than 46 (the RESTORE chunk header+payload is
       35), so this was unreachable before CHAT existed. */
    len = 0u;
    while (text[len] != '\0' && len < (SPECTRUM_LINK_PAYLOAD_MAX - 1u)) {
        net_tx_line[len] = text[len];
        ++len;
    }
    net_tx_line[len] = '\n';
    ++len;

    /* net_send_raw() drains before every attempt (spectrum_net_background_
     * drain(), transport-dispatched) -- this used to run its own separate
     * ladder plus an extra drain up front; both were unified into
     * net_send_raw during the S9 MQTT-lag fix (2026-08-19), the same fix
     * that removed net_mqtt_send_raw's identical twin. */
    return net_send_raw((const uint8_t *)net_tx_line, len);
}

uint8_t spectrum_net_send_ping(void)
{
    return spectrum_net_send_text(NETCHESS_PROTO_PING);
}

char *spectrum_net_payload_scratch(void)
{
    return net_payload_scratch;
}

uint8_t spectrum_net_link_activity(void)
{
    uint8_t activity = net_link_activity;

    net_link_activity = 0u;
    return activity;
}

uint8_t spectrum_net_payload_flags(void)
{
    /* DIRECT never sets retained/route flags -- those are MQTT-only
     * concepts. net_mqtt_flags is set by net_mqtt_read_payload() above,
     * the same "last read's flags" contract net_link_activity uses for
     * activity (link.h: payload_flags() describes the payload the most
     * recent read_payload() call produced). */
    return netchesszx_transport_is_mqtt() ? net_mqtt_flags : 0u;
}

void spectrum_net_background_drain(void)
{
    if (netchesszx_transport_is_mqtt()) {
        nc_mqtt_pump();
        return;
    }
    nc_pump();
}

/* link.h also declares spectrum_net_last_ip/spectrum_net_sync_time -- not
 * implemented here, same S9 MQTT-lag-pass budget valve and same reasoning
 * as spectrum_net_listen and friends above (their spectrum_link_* aliases
 * are only called from app.c, not linked into this port). Sprinter already
 * has a hardware RTC (BIOS_CMOS_TEST, sampled by trampoline.asm into
 * rtc_present -- platform_primitives.asm's RTC_PRESENT banner) rather than
 * ZX's ESP-AT NTP path, so sync_time would have had nothing to do anyway. */

/* S8 step 8a/8b: thin WIN1 wrapper dispatching the NET overlay's own
 * DIRECT-join/config screen (src/sprinter/net_ui_sprinter.c, moved off the
 * WIN3 cold page onto its own WIN3 page -- that file's own header has the
 * full rationale). Same shape as restore.c/saveload.c/fileui.c's own thin
 * wrappers around spectrum_overlay_exec_cached: the whole body is the
 * dispatch, no local state of its own. Replaces the cold-page-native
 * spectrum_net_join_ui() session_sprinter.c used to call same-page before
 * this move -- gen_sprinter_cold_defs.py's COLD_RESIDENT_SYMBOLS bridges
 * that caller to this WIN1 symbol now. */
uint8_t spectrum_net_join_ui(void)
{
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_NET_CONNECT,
                                        SPECTRUM_OVL_NET_CONNECT_SCREEN);
}

/* --- link.h's MQTT half (S8 step 8c) ------------------------------------
 * start/activate_side/probe_seat dispatch the NET overlay's own MQTT
 * connect-lifecycle entries (src/sprinter/net_mqtt_ui_sprinter.c, entries
 * 0/1/3 -- see entry_net_sprinter.asm); publish_presence/publish_setup
 * build and send their packet inline above (net_mqtt_publish_suffix).
 * publish_offline (link.h's sixth MQTT entry) is NOT here -- src/spectrum/
 * transport/mqtt_session_wire.c already implements it portably, calling
 * back into publish_presence/publish_setup below, the same way it does on
 * ZX/Next. */
uint8_t spectrum_net_mqtt_start(void)
{
    nc_mqtt_reset();
    spectrum_net_mqtt_link_reset();
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_MQTT_CONNECT,
                                        SPECTRUM_OVL_MQTT_CONNECT_START);
}

uint8_t spectrum_net_mqtt_activate_side(void)
{
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_MQTT_CONNECT,
                                        SPECTRUM_OVL_MQTT_CONNECT_ACTIVATE);
}

uint8_t spectrum_net_mqtt_probe_seat(void)
{
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_MQTT_CONNECT,
                                        SPECTRUM_OVL_MQTT_CONNECT_PROBE_SEAT);
}

uint8_t spectrum_net_mqtt_publish_presence(void)
{
    return net_mqtt_publish_suffix(spectrum_net_mqtt_presence_suffix(),
                                   spectrum_net_mqtt_presence_payload(), 1u);
}

uint8_t spectrum_net_mqtt_publish_setup(uint8_t mode) NETCHESSZX_FASTCALL
{
    char setup[32];

    if (mode == SPECTRUM_LINK_MQTT_SETUP_CLEAR) {
        return net_mqtt_publish_suffix("meta", "", 1u);
    }
    spectrum_net_mqtt_setup_payload(setup);
    return net_mqtt_publish_suffix(
        "meta", setup,
        (uint8_t)(mode == SPECTRUM_LINK_MQTT_SETUP_RETAINED));
}
