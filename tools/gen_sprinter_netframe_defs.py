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
    # budget crisis, same reasoning) -- only this one entry point was live
    # under NETCHESSZX_DIRECT_ONLY; main.c's own net_parse_u16 uses it
    # directly, and tools/gen_sprinter_overlay_defs.py's existing bridge
    # for it (CONTROL overlay) needs no change -- see Makefile's own
    # comment on SPRINTER_NET_FRAME_C_SRC for why.
    "netchess_mqtt_session_parse_u16_token",
    # S8 step 8c (DIRECT_ONLY dropped for this build): the other three
    # mqtt_session_protocol.c entry points, now real here instead of
    # compiled out. src/spectrum/session/mqtt.c (WIN1 resident) is their
    # only caller -- directly (parse_side) and through mqtt.h's parse_host_
    # payload/parse_join_payload macros (parse_host/parse_join).
    "netchess_mqtt_session_parse_side",
    "netchess_mqtt_session_parse_host",
    "netchess_mqtt_session_parse_join",
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
    # S8 step 6 moved src/sprinter/transport/unet_link.c here outright (it
    # only called ng_*/nc_*/game_protocol.c, nothing WIN1-only); S8 step 8a
    # moved it BACK to WIN1 (mqtt_min.c, its new MQTT-half dependency, fits
    # only there -- see Makefile's SPRINTER_NET_FRAME_C_SRC comment). Its 15
    # spectrum_net_* entry points are bridged the OTHER way now: tools/
    # gen_sprinter_cold_defs.py's COLD_RESIDENT_SYMBOLS (session_sprinter.c,
    # on the cold page, calls them) and tools/gen_sprinter_overlay_defs.py's
    # OVERLAY_RESIDENT_SYMBOLS (the NET overlay, S8 step 8b, calls them).
    # What THIS list bridges instead, since step 8a, is the reverse
    # direction unet_link.c always needed: its own calls into this blob's
    # nc_mqtt_* reassembler (net_frame.c, S7 step 7) from WIN1.
    "nc_mqtt_reset",
    "nc_mqtt_feed",
    "nc_mqtt_take",
    "nc_mqtt_packet",
    "nc_mqtt_consume",
    "nc_mqtt_pump",
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
        "_nc_mqtt_reset                         = $A160 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_mqtt_reset::0::0:6\n"
        "_nc_mqtt_feed                          = $A170 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_mqtt_feed::0::0:6\n"
        "_nc_mqtt_take                          = $A180 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_mqtt_take::0::0:6\n"
        "_nc_mqtt_packet                        = $A190 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_mqtt_packet::0::0:6\n"
        "_nc_mqtt_consume                       = $A1A0 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_mqtt_consume::0::0:6\n"
        "_nc_mqtt_pump                          = $A1B0 ; addr, public, , "
        "src_sprinter_transport_net_frame_c, code_compiler, "
        "src/sprinter/transport/net_frame.c::nc_mqtt_pump::0::0:6\n"
        "_netchess_mqtt_session_parse_u16_token = $A250 ; addr, public, , "
        "src_common_protocol_mqtt_session_protocol_c, code_compiler, "
        "src/common/protocol/mqtt_session_protocol.c::"
        "netchess_mqtt_session_parse_u16_token::0::0:6\n"
        "_netchess_mqtt_session_parse_side      = $A260 ; addr, public, , "
        "src_common_protocol_mqtt_session_protocol_c, code_compiler, "
        "src/common/protocol/mqtt_session_protocol.c::"
        "netchess_mqtt_session_parse_side::0::0:6\n"
        "_netchess_mqtt_session_parse_host      = $A270 ; addr, public, , "
        "src_common_protocol_mqtt_session_protocol_c, code_compiler, "
        "src/common/protocol/mqtt_session_protocol.c::"
        "netchess_mqtt_session_parse_host::0::0:6\n"
        "_netchess_mqtt_session_parse_join      = $A280 ; addr, public, , "
        "src_common_protocol_mqtt_session_protocol_c, code_compiler, "
        "src/common/protocol/mqtt_session_protocol.c::"
        "netchess_mqtt_session_parse_join::0::0:6\n"
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
