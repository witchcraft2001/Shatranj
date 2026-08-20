#!/usr/bin/env python3
"""Guard the Spectrum/Next transport buffer-ownership contract."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def fail(msg: str) -> None:
    raise SystemExit(f"[ERR] transport contract: {msg}")


def fn_body(source: str, name: str) -> str:
    match = re.search(
        rf"{name}\s*\([^)]*\)(?:\s+[_A-Za-z]\w*)*\s*\{{(?P<body>.*?)\n\}}",
        source,
        re.S,
    )
    if not match:
        fail(f"missing {name}()")
    return match.group("body")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args()

    root = Path(args.root)
    app_c = (root / "src/spectrum/app/app.c").read_text(encoding="utf-8")
    net_c = (root / "src/spectrum/transport/net.c").read_text(encoding="utf-8")
    link_h = (root / "src/spectrum/transport/link.h").read_text(encoding="utf-8")

    if "Transport contract shared by Spectrum and Next" not in link_h:
        fail("missing link.h ownership contract")
    scratch_body = fn_body(net_c, "spectrum_net_payload_scratch")
    if "netchesszx_transport_is_mqtt()" not in scratch_body:
        fail("payload_scratch() must select storage by active transport")
    if "direct_rx_payload" not in scratch_body:
        fail("MQTT payload scratch must use inactive DIRECT storage")
    if "SPECTRUM_MQTT_PACKET_SCRATCH" not in scratch_body:
        fail("DIRECT payload scratch must use inactive MQTT storage")
    if "direct_rx_payload2" in scratch_body:
        fail("payload_scratch() aliases the MQTT queued-publish buffer")

    drain_body = fn_body(net_c, "mqtt_drain_uart_budget")
    full_check = drain_body.find("mqtt_stream_len >= MQTT_STREAM_MAX")
    uart_read = drain_body.find("spectrum_uart_read()")
    if full_check < 0 or uart_read < 0 or full_check > uart_read:
        fail("MQTT stream capacity must be checked before consuming UART")

    stream_body = fn_body(net_c, "mqtt_enter_stream_mode")
    if "!spectrum_uart_send_string(\"AT+CIPSEND\")" not in stream_body:
        fail("MQTT stream entry must propagate AT+CIPSEND TX failure")
    if "!spectrum_uart_send_crlf()" not in stream_body:
        fail("MQTT stream entry must propagate CRLF TX failure")

    chat_body = fn_body(app_c, "send_local_chat")
    if "NETCHESSZX_NEXT" in chat_body:
        fail("send_local_chat() must stay client-agnostic")
    if "spectrum_link_payload_scratch()" not in chat_body:
        fail("send_local_chat() must use link scratch storage")

    check_sprinter(root)

    print("[OK] transport contract: active-backend buffers stay isolated")


def check_sprinter(root: Path) -> None:
    """The same ownership contract as above, in Sprinter's own shape.

    Sprinter has no second backend to borrow storage from (uNet/DIRECT is
    the only one), so the "payload_scratch never aliases the active path"
    rule cannot be expressed as "use the inactive backend's buffer" the way
    net.c expresses it. Here it means: the scratch handed to callers and the
    buffer send_text() stages a line into must be two different arrays --
    main.c's net_poll_once() passes the scratch straight to
    netchesszx_session_poll() as the RX destination, and that call answers
    PING and ACKs moves while the caller still holds the payload.
    """
    link = (root / "src/sprinter/transport/unet_link.c").read_text(encoding="utf-8")

    scratch_body = fn_body(link, "spectrum_net_payload_scratch")
    if "net_payload_scratch" not in scratch_body:
        fail("Sprinter payload_scratch() must return net_payload_scratch")
    if "net_tx_line" in scratch_body:
        fail("Sprinter payload_scratch() must not hand out the TX staging buffer")

    send_body = fn_body(link, "spectrum_net_send_text")
    if "net_payload_scratch" in send_body:
        fail("Sprinter send_text() must not stage into the caller-facing scratch")
    if "net_tx_line" not in send_body:
        fail("Sprinter send_text() must stage into its own TX buffer")

    drain_body = fn_body(link, "spectrum_net_background_drain")
    if "nc_line_pop" in drain_body:
        fail("Sprinter background_drain() must not consume the RX queue")

    read_body = fn_body(link, "spectrum_net_read_payload")
    # Tick compatibility with ZX's own WAIT_POLL=2 (net.c's mqtt_fill_stream):
    # an empty poll costs exactly ONE frame wait in here, plus the one
    # main.c's own poll loop already waits between calls, for two total --
    # and the queue is checked before either poll so a queue with data costs
    # none. Was 2 here (3 total) until the S9 MQTT-lag fix (2026-08-19),
    # which also brought net_mqtt_read_payload up to the same one-wait
    # pacing below -- before that fix MQTT waited zero, ticking at roughly
    # twice DIRECT's rate.
    if read_body.count("frame_wait()") != 1:
        fail("Sprinter read_payload() must wait exactly one frame when idle")
    if read_body.find("nc_queue_count()") > read_body.find("nc_pump()"):
        fail("Sprinter read_payload() must check the queue before pumping")
    if read_body.find("nc_line_pop") < read_body.rfind("frame_wait()"):
        fail("Sprinter read_payload() must pop after the pacing wait")

    mqtt_read_body = fn_body(link, "net_mqtt_read_payload")
    if mqtt_read_body.count("frame_wait()") != 1:
        fail("Sprinter MQTT read_payload() must wait exactly one frame when idle")

    if link.count("ng_c_send();") != 1:
        fail(
            "Sprinter must send through a single ng_c_send() call site "
            "(net_send_raw) -- a second copy means the busy-retry ladder "
            "drifted apart again"
        )

    puback_body = fn_body(link, "net_mqtt_puback")
    if "net_mqtt_puback_pending" not in puback_body:
        fail(
            "Sprinter PUBACK must be deferred (net_mqtt_puback_pending), "
            "not sent immediately -- an immediate standalone PUBACK stalls "
            "on the broker's delayed-ACK timer"
        )

    activity_body = fn_body(link, "spectrum_net_link_activity")
    if "net_link_activity = 0u" not in activity_body:
        fail("Sprinter link_activity() must be consume-on-read")

    check_sprinter_frame_tick(root)
    check_sprinter_mqtt_routing(root, link)


def check_sprinter_frame_tick(root: Path) -> None:
    """gui.c's tick counts its own calls, so it must see one call per REAL frame.

    spectrum_gui_tick() drives the GAME/TURN timers and the notice countdown
    off clock_frames -- 50 calls == one second -- which is only true if it is
    called once per 50 Hz frame. ZX/Next satisfy that structurally: every
    frame they wait is waited through spectrum_net_runtime_wait_frame*(),
    which is frame_wait and gui_tick together, wherever the wait happens.

    Sprinter cannot: its frame loop calls the tick once per ITERATION, and an
    iteration burns a variable number of frames (the read path waits one, the
    send ladder waits more, and a blocking uNet SEND can sit inside the DLL
    for seconds with no frame_wait at all). So main.c must tick once per frame
    that really elapsed, measured from the ISR's own frame_counter.

    This is guarded because the coupling is invisible and has already bitten:
    the S9 pacing fix above changed an MQTT iteration from one frame to two,
    and the GAME/TURN clocks silently ran at half speed (2026-08-19). Anyone
    "simplifying" this back to a bare per-iteration tick reintroduces exactly
    that, and no other gate would notice.
    """
    main_c = (root / "src/sprinter/main.c").read_text(encoding="utf-8")

    if main_c.count("spectrum_gui_tick();") != 1:
        fail(
            "Sprinter main.c must call spectrum_gui_tick() from exactly one "
            "site (the real-frame catch-up loop)"
        )
    # Structural, not proximity-based: the tick must be the body of the
    # elapsed-frames loop. Checking only that frame_counter appears "somewhere
    # above" passes for a bare per-iteration tick that merely leaves the delta
    # arithmetic sitting unused next to it -- which is the exact regression
    # this guards, so that weaker form is worthless here.
    if not re.search(
        r"while\s*\(\s*frames_elapsed--\s*!=\s*0u\s*\)\s*\{\s*"
        r"spectrum_gui_tick\(\);\s*\}",
        main_c,
    ):
        fail(
            "Sprinter main.c must drive spectrum_gui_tick() once per REAL "
            "elapsed frame -- the call must be the body of "
            "`while (frames_elapsed-- != 0u)`, with frames_elapsed the "
            "frame_counter delta since gui_tick_last_frame. A per-iteration "
            "tick makes the GAME/TURN timers run slow: an iteration is a "
            "variable number of frames on this port"
        )
    if "frame_counter" not in main_c or "gui_tick_last_frame" not in main_c:
        fail(
            "Sprinter main.c must measure elapsed frames from the ISR's "
            "frame_counter against gui_tick_last_frame"
        )


def check_sprinter_mqtt_routing(root: Path, link: str) -> None:
    """Which MQTT topic an outbound message goes to IS the protocol.

    docs/wire-contract.md gives a room four topics, and ZX/Next's
    mqtt_tx_ovl.c splits outbound text four ways between them. Sprinter has
    to make the identical split -- architecture decision #0006: a divergence
    means one implementation is wrong, never that a target is special.

    This is not a hypothetical. Until 2026-08-15 Sprinter published
    EVERYTHING to the game topic, which is correct by construction on DIRECT
    (one channel) and silently wrong on MQTT. "ACK GAME START" never reached
    the host's `meta` subscription, so a host that had a healthy link and a
    guest already answering sat on "waiting opponent ACK" forever; every
    other ACK missed the ack topic the same way, and the session's own PING
    ladder then reported the peer lost. Nothing failed, nothing logged --
    the packets simply went somewhere nobody was listening.

    Compared as decisions, not as text: each rule is (what the payload is
    tested for, which topic expression it must be published to), read out of
    both files and required to agree in content and in ORDER -- "ACK GAME
    START" has to be tested before the broader "ACK " or it would never be
    reached.
    """
    tx_ovl = (root / "src/spectrum/overlay/mqtt_tx_ovl.c").read_text(encoding="utf-8")

    def routing(source: str, name: str) -> list[tuple[str, str]]:
        body = fn_body(source, name)
        rules: list[tuple[str, str]] = []
        for test, topic in re.findall(
            r'netchess_after_prefix\(text,\s*([^)]+?)\)\)\s*\{\s*return\s+'
            r'\w+\(\s*([^,]+?),',
            body,
            re.S,
        ):
            rules.append((test.strip(), topic.strip()))
        tail = re.search(r"return\s+\w+\(\s*([^,]+?),\s*text", body[body.rfind("}"):], re.S)
        if not tail:
            fail(f"{name}() must end with a default topic route")
        rules.append(("<default>", tail.group(1).strip()))
        return rules

    zx = routing(tx_ovl, "mqtt_tx_send_text_ovl")
    sprinter = routing(link, "net_mqtt_send_text")
    if zx != sprinter:
        fail(
            "Sprinter MQTT topic routing diverges from ZX/Next.\n"
            f"       ZX (mqtt_tx_ovl.c):       {zx}\n"
            f"       Sprinter (unet_link.c):   {sprinter}"
        )


if __name__ == "__main__":
    main()
