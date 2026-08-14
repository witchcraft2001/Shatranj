#!/usr/bin/env python3
"""Bridge net_frame.c's WIN2 C-blob symbol table into z88dk-linkable defc's.

net_frame.c (src/sprinter/transport/net_frame.c, S7/port.md section 3.7) is
built as its own independent zcc program -- asm/sprinter/zcc/net_core_crt0.
asm at a fixed ORG (fixed_layout.json's NET_FRAME_C region), spliced into
the flat resident image by tools/make_sprinter_resident.py the same way
platform_primitives.bin already is. Its compiled address is therefore only
known from ITS OWN .map file, not from anything the WIN1 resident C build
(src/sprinter/main.c + friends) can see directly.

This tool is the mirror of tools/gen_sprinter_overlay_defs.py (which bridges
resident_c.map -> overlay C sources) and tools/gen_sprinter_platform_defs.py
(which bridges platform_primitives.sym -> resident C): here the source is
net_frame_c.map (z88dk's own map format, same shape as resident_c.map) and
the consumer is the WIN1 resident C build itself -- src/sprinter/transport/
unet_link.c calls nc_* functions across this same "fixed address, no
shared link unit" boundary net_gate.asm's ng_* routines already cross (via
gen_sprinter_platform_defs.py), just compiled by zcc instead of sjasmplus.

The output is a pure function of the input .map file (no timestamps), so
reruns are byte-identical -- same contract as the other two gen_sprinter_*
tools.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Curated allowlist: only these net_frame.c symbols are exposed to the WIN1
# resident C build. Adding a new cross-boundary call means adding its name
# here -- same discipline as OVERLAY_RESIDENT_SYMBOLS/PLATFORM_SYMBOLS
# elsewhere. nc_smoke is step 1's build-pipeline proof; step 2 adds the
# portable line-framing core's real entry points (src/sprinter/transport/
# unet_link.c, step 3, calls these directly -- nc_pump itself, the target-
# only backend glue around ng_recv, is added in step 3, not here).
NETFRAME_RESIDENT_SYMBOLS = [
    "nc_smoke",
    "nc_init",
    "nc_feed",
    "nc_line_pop",
    "nc_mark_closed",
    "nc_mark_lost",
    "nc_queue_count",
    # step 3: the ng_recv-polling glue itself, called from WIN1's
    # background_drain (src/sprinter/transport/unet_link.c).
    "nc_pump",
    # S8 step 4 (WIN1 budget relief): keepalive_protocol.c/direct_session_
    # protocol.c moved into this same zcc build (Makefile's
    # SPRINTER_NET_FRAME_C_SRC); src/spectrum/session/{event,direct}.c
    # (still resident) reach these seven entry points through this bridge
    # instead of a direct C link.
    "spectrum_keepalive_is_ping",
    "spectrum_keepalive_is_ack_ping",
    "netchess_direct_is_hello",
    "netchess_direct_parse_guest_hello",
    "netchess_direct_parse_host_hello",
    "netchess_direct_parse_start_white_owner",
    "netchess_direct_hello",
    # S8 step 5 (WIN1 budget relief, round 2): game_protocol.c moved here
    # outright (not duplicated -- Makefile's own comment on
    # SPRINTER_NET_FRAME_C_SRC explains why duplicating it, as step 4 did
    # for keepalive/direct_session_protocol, would have cost far more of
    # this blob's budget than it saved in WIN1's). Every resident caller
    # (src/sprinter/main.c, src/common/protocol/game_protocol_extra.c)
    # reaches these through this same bridge now. A defc bridge costs
    # nothing at runtime either way -- WIN2 is always mapped, so calling a
    # WIN2 function from WIN1 is a plain CALL to a fixed address, exactly
    # as cheap as calling resident code (unlike the WIN3 cold page's
    # save/restore/OUT trampoline).
    "netchess_after_prefix",
    "netchess_proto_copy_digits",
    "netchess_proto_copy_rest",
    "netchess_proto_parse_move",
    "netchess_proto_parse_chat",
    # mqtt_session_protocol.c (moved with game_protocol.c in step 6's
    # budget crisis, same reasoning) -- only this one entry point is live
    # under NETCHESSZX_DIRECT_ONLY; main.c's own net_parse_u16 uses it
    # directly, and tools/gen_sprinter_overlay_defs.py's existing bridge
    # for it (CONTROL overlay) needs no change -- see Makefile's own
    # comment on SPRINTER_NET_FRAME_C_SRC for why.
    "netchess_mqtt_session_parse_u16_token",
    "NETCHESS_PROTO_ACK_PREFIX",
    "NETCHESS_PROTO_NACK_PREFIX",
    "NETCHESS_PROTO_MOVE_PREFIX",
    "NETCHESS_PROTO_CHAT_PREFIX",
    "NETCHESS_PROTO_DRAW",
    "NETCHESS_PROTO_CANCEL_DRAW",
    "NETCHESS_PROTO_CANCEL_RESET",
    "NETCHESS_PROTO_ACK_RESIGN",
    "NETCHESS_PROTO_GAME_START",
    "NETCHESS_PROTO_NACK_RESET",
    "NETCHESS_PROTO_BYE",
    "NETCHESS_PROTO_TAKEBACK_PREFIX",
    "NETCHESS_PROTO_ACK_PING",
    # S8 step 6 (WIN1 budget relief, round 3): src/sprinter/transport/
    # unet_link.c moved here outright -- it only ever called ng_*
    # (net_gate.asm, WIN2 asm, already linked via platform_defs.asm), nc_*
    # (this same build) and game_protocol.c (this same build since step
    # 5), nothing WIN1-only. session/{ping,direct,outgoing}.c were ALSO
    # tried (their only WIN1-only dependency was unet_link.c's
    # spectrum_link_* surface, a #define alias for these spectrum_net_*
    # names, link.h) but reverted -- see SPRINTER_NET_FRAME_C_SRC's own
    # Makefile comment, this blob's ~4 KiB ceiling could not hold them
    # plus what they pulled in behind them (platform/text.c, all of
    # config/session.c). Every resident caller of link.h's contract
    # (src/sprinter/main.c, session/{event,poll,ping,direct,outgoing}.c,
    # all resident) reaches these 15 through this bridge.
    "spectrum_net_start_uart",
    "spectrum_net_listen",
    "spectrum_net_connect_host",
    "spectrum_net_wait_pc_connect",
    "spectrum_net_direct_peer_mark_valid",
    "spectrum_net_read_payload",
    "spectrum_net_send_text",
    "spectrum_net_send_ping",
    "spectrum_net_payload_scratch",
    "spectrum_net_link_activity",
    "spectrum_net_payload_flags",
    "spectrum_net_background_drain",
    "spectrum_net_preflight_run",
    "spectrum_net_last_ip",
    "spectrum_net_sync_time",
]

GENERATED_BANNER = (
    "Generated by tools/gen_sprinter_netframe_defs.py from net_frame.c's "
    "own .map file. Do not edit by hand."
)

# z88dk map lines: "_name    = $ADDR ; addr, public, ...". C symbols always
# carry the leading underscore z88dk adds; the allowlist above omits it (to
# read the same as the C source) and this parser strips it back off so both
# sides agree on one canonical (unprefixed) key.
MAP_LINE = re.compile(r"^_(\S+)\s+=\s+\$([0-9A-Fa-f]+)\s*;")


class NetframeDefsError(Exception):
    pass


def parse_map(path: Path) -> dict[str, int]:
    symbols: dict[str, int] = {}
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = MAP_LINE.match(line.strip())
            if match:
                symbols[match.group(1)] = int(match.group(2), 16)
    return symbols


def render(symbols: dict[str, int], names: list[str]) -> str:
    missing = [name for name in names if name not in symbols]
    if missing:
        raise NetframeDefsError(
            "missing net_frame.c symbol(s) (add to src/sprinter/transport/"
            "net_frame.c or drop from NETFRAME_RESIDENT_SYMBOLS): "
            + ", ".join(missing)
        )
    lines = [f";; {GENERATED_BANNER}",
             ";; z88dk-z80asm syntax (consumed by the WIN1 resident C "
             "build, e.g. src/sprinter/transport/unet_link.c)",
             ""]
    for name in names:
        addr = symbols[name]
        lines.append(f"PUBLIC _{name}")
        lines.append(f"defc _{name} = ${addr:04X}")
    lines.append("")
    return "\n".join(lines)


def _clean_fixture() -> str:
    return (
        "_nc_smoke                       = $9D00 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_smoke::0::0:6\n"
        "i_2                             = $9D00 ; addr, local, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_smoke::0::0:6\n"
        "_nc_init                        = $9D10 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_init::0::0:6\n"
        "_nc_feed                        = $9D30 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_feed::0::0:6\n"
        "_nc_line_pop                    = $9D80 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_line_pop::0::0:6\n"
        "_nc_mark_closed                 = $9DC0 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_mark_closed::0::0:6\n"
        "_nc_mark_lost                   = $9DC8 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_mark_lost::0::0:6\n"
        "_nc_queue_count                 = $9DD0 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_queue_count::0::0:6\n"
        "_nc_pump                        = $9FA1 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_pump::0::21:143\n"
        "_spectrum_keepalive_is_ping     = $9FC0 ; addr, public, , "
        "src_spectrum_transport_keepalive_protocol_c, code_compiler, "
        "src/spectrum/transport/keepalive_protocol.c::"
        "spectrum_keepalive_is_ping::0::0:6\n"
        "_spectrum_keepalive_is_ack_ping = $9FD0 ; addr, public, , "
        "src_spectrum_transport_keepalive_protocol_c, code_compiler, "
        "src/spectrum/transport/keepalive_protocol.c::"
        "spectrum_keepalive_is_ack_ping::0::0:6\n"
        "_netchess_direct_is_hello       = $9FE0 ; addr, public, , "
        "src_common_protocol_direct_session_protocol_c, code_compiler, "
        "src/common/protocol/direct_session_protocol.c::"
        "netchess_direct_is_hello::0::0:6\n"
        "_netchess_direct_parse_guest_hello = $9FF0 ; addr, public, , "
        "src_common_protocol_direct_session_protocol_c, code_compiler, "
        "src/common/protocol/direct_session_protocol.c::"
        "netchess_direct_parse_guest_hello::0::0:6\n"
        "_netchess_direct_parse_host_hello = $A000 ; addr, public, , "
        "src_common_protocol_direct_session_protocol_c, code_compiler, "
        "src/common/protocol/direct_session_protocol.c::"
        "netchess_direct_parse_host_hello::0::0:6\n"
        "_netchess_direct_parse_start_white_owner = $A010 ; addr, public, , "
        "src_common_protocol_direct_session_protocol_c, code_compiler, "
        "src/common/protocol/direct_session_protocol.c::"
        "netchess_direct_parse_start_white_owner::0::0:6\n"
        "_netchess_direct_hello          = $A020 ; addr, public, , "
        "src_common_protocol_direct_session_protocol_c, code_compiler, "
        "src/common/protocol/direct_session_protocol.c::"
        "netchess_direct_hello::0::0:6\n"
        "_netchess_after_prefix           = $A030 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::netchess_after_prefix::0::0:6\n"
        "_netchess_proto_copy_digits      = $A040 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::netchess_proto_copy_digits::0::0:6\n"
        "_netchess_proto_copy_rest        = $A050 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::netchess_proto_copy_rest::0::0:6\n"
        "_netchess_proto_parse_move       = $A060 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::netchess_proto_parse_move::0::0:6\n"
        "_netchess_proto_parse_chat       = $A070 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::netchess_proto_parse_chat::0::0:6\n"
        "_NETCHESS_PROTO_ACK_PREFIX       = $A090 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_ACK_PREFIX::0::0:6\n"
        "_NETCHESS_PROTO_NACK_PREFIX      = $A0A0 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_NACK_PREFIX::0::0:6\n"
        "_NETCHESS_PROTO_MOVE_PREFIX      = $A0B0 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_MOVE_PREFIX::0::0:6\n"
        "_NETCHESS_PROTO_CHAT_PREFIX      = $A0C0 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_CHAT_PREFIX::0::0:6\n"
        "_NETCHESS_PROTO_DRAW             = $A0D0 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_DRAW::0::0:6\n"
        "_NETCHESS_PROTO_CANCEL_DRAW      = $A0E0 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_CANCEL_DRAW::0::0:6\n"
        "_NETCHESS_PROTO_CANCEL_RESET     = $A0F0 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_CANCEL_RESET::0::0:6\n"
        "_NETCHESS_PROTO_ACK_RESIGN       = $A100 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_ACK_RESIGN::0::0:6\n"
        "_NETCHESS_PROTO_GAME_START       = $A110 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_GAME_START::0::0:6\n"
        "_NETCHESS_PROTO_NACK_RESET       = $A120 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_NACK_RESET::0::0:6\n"
        "_NETCHESS_PROTO_BYE              = $A130 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_BYE::0::0:6\n"
        "_NETCHESS_PROTO_TAKEBACK_PREFIX  = $A140 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::"
        "NETCHESS_PROTO_TAKEBACK_PREFIX::0::0:6\n"
        "_NETCHESS_PROTO_ACK_PING         = $A150 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::NETCHESS_PROTO_ACK_PING::0::0:6\n"
        "_spectrum_net_start_uart               = $A160 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_start_uart::0::0:6\n"
        "_spectrum_net_listen                   = $A170 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_listen::0::0:6\n"
        "_spectrum_net_connect_host             = $A180 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_connect_host::0::0:6\n"
        "_spectrum_net_wait_pc_connect          = $A190 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_wait_pc_connect::0::0:6\n"
        "_spectrum_net_direct_peer_mark_valid   = $A1A0 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_direct_peer_mark_valid::0::0:6\n"
        "_spectrum_net_read_payload             = $A1B0 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_read_payload::0::0:6\n"
        "_spectrum_net_send_text                = $A1C0 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_send_text::0::0:6\n"
        "_spectrum_net_send_ping                = $A1D0 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_send_ping::0::0:6\n"
        "_spectrum_net_payload_scratch          = $A1E0 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_payload_scratch::0::0:6\n"
        "_spectrum_net_link_activity            = $A1F0 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_link_activity::0::0:6\n"
        "_spectrum_net_payload_flags            = $A200 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_payload_flags::0::0:6\n"
        "_spectrum_net_background_drain         = $A210 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_background_drain::0::0:6\n"
        "_spectrum_net_preflight_run            = $A220 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_preflight_run::0::0:6\n"
        "_spectrum_net_last_ip                  = $A230 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_last_ip::0::0:6\n"
        "_spectrum_net_sync_time                = $A240 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_sync_time::0::0:6\n"
        "_netchess_mqtt_session_parse_u16_token = $A250 ; addr, public, , "
        "src_common_protocol_mqtt_session_protocol_c, code_compiler, "
        "src/common/protocol/mqtt_session_protocol.c::"
        "netchess_mqtt_session_parse_u16_token::0::0:6\n"
    )


def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        map_path = Path(tmp) / "clean.map"
        map_path.write_text(_clean_fixture(), encoding="ascii")
        symbols = parse_map(map_path)

        if symbols.get("nc_smoke") != 0x9D00:
            raise SystemExit("[ERR] netframe-defs self-test: function symbol not parsed")
        if "i_2" in symbols:
            raise SystemExit("[ERR] netframe-defs self-test: local label wrongly captured")

        out1 = render(symbols, NETFRAME_RESIDENT_SYMBOLS)
        out2 = render(symbols, NETFRAME_RESIDENT_SYMBOLS)
        if out1 != out2:
            raise SystemExit("[ERR] netframe-defs self-test: rendering is not deterministic")
        if "PUBLIC _nc_smoke" not in out1:
            raise SystemExit("[ERR] netframe-defs self-test: underscored name missing")
        if "defc _nc_smoke = $9D00" not in out1:
            raise SystemExit("[ERR] netframe-defs self-test: address mismatch")

        try:
            render(symbols, NETFRAME_RESIDENT_SYMBOLS + ["totally_missing"])
        except NetframeDefsError as exc:
            if "totally_missing" not in str(exc):
                raise SystemExit(
                    "[ERR] netframe-defs self-test: wrong missing-symbol diagnostic"
                )
        else:
            raise SystemExit(
                "[ERR] netframe-defs self-test: missing symbol was not rejected"
            )

    print("[OK] Sprinter netframe-defs self-test")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map", type=Path, help="net_frame_c.map to read")
    parser.add_argument("--out", type=Path, help="netframe_defs.asm to write")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if not args.map or not args.out:
        raise SystemExit(
            "gen_sprinter_netframe_defs: --map and --out are required unless --self-test"
        )

    symbols = parse_map(args.map)
    try:
        text = render(symbols, NETFRAME_RESIDENT_SYMBOLS)
    except NetframeDefsError as exc:
        print(f"[ERR] {args.map}: {exc}", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text, encoding="ascii")
    print(f"[OK] {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
