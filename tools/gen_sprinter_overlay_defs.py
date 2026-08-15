#!/usr/bin/env python3
"""Bridge the resident C image's symbol table into z88dk-linkable defc's.

Mirrors tools/gen_overlay_defs.py's role for the ZX/Next overlay ABI, and
tools/gen_sprinter_platform_defs.py's role for the sjasmplus platform
primitives -- but the source here is build/sprinter/resident_c.map (z88dk's
own map format, "_NAME = $ADDR ; ..."), and the symbols are C functions/data
the resident C image (src/sprinter/main.c + src/common/protocol/*.c) already
links once. Overlay C sources (src/spectrum/overlay/*_ovl.c, shared
byte-for-byte with ZX/Next) call some of that same portable common/ code --
control_ovl.c calls netchess_after_prefix and references the
NETCHESS_PROTO_* string constants, for instance. Duplicating game_protocol.c
+ mqtt_session_protocol.c into every overlay's own 2 KiB slot would waste
most of the slot on the same bytes repeated 15 times; this tool lets each
overlay EXTERN the resident's one copy instead, the same way
overlay_loader_sprinter.asm EXTERNs ovl_copy_slot from platform_defs.asm.

The output is a pure function of the input .map file (no timestamps), so
reruns are byte-identical -- same contract as the other two gen_sprinter_*
tools.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Curated allowlist: only these resident C symbols are exposed to overlay
# C sources. Adding a new cross-boundary call means adding its name here --
# same discipline as PLATFORM_SYMBOLS/REQUIRED_SYMBOLS elsewhere.
OVERLAY_RESIDENT_SYMBOLS = [
    # game_protocol.c / mqtt_session_protocol.c -- control_ovl.c's protocol
    # classifier (SPECTRUM_OVL_CONTROL=14u) needs both the string-prefix
    # matcher and the token constants it matches against.
    "netchess_after_prefix",
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
    # board.c (S5 substep 3b, RULES(0)/BOARD(1) port): the BOARD overlay's
    # snapshot-save entry (entry_board_sprinter.asm, hand-ported inline asm
    # mirroring entry_board.asm:24-43) reads/writes these three globals
    # directly, the same way it does on ZX/Next via entry_board.asm's own
    # EXTERNs.
    "side_to_move",
    "castle_rights",
    "ep_square",
    # FILEUI (S6 plan step 4): fileui_ovl.c (the overlay entry) reads/
    # writes fileui.c's own resident state (linked into the resident C
    # image alongside main.c -- SPRINTER_RESIDENT_C_SRC) -- the same
    # cross-boundary shape board.c's side_to_move/castle_rights/ep_square
    # above already use. Its render trio comes through here too: since S7
    # step 4 those three live in the WIN3 cold page, but what a caller
    # links against is the eight-byte WIN1 stub gen_sprinter_cold_thunks.py
    # generates, which IS in resident_c.map -- and calling through it is
    # what lets a WIN3-resident overlay reach WIN3-resident painters at all
    # (the stub saves the overlay's own page and restores it before
    # returning, so only one WIN3 page is ever mapped at a time).
    "spectrum_fileui_count",
    "spectrum_fileui_used_mask",
    "spectrum_render_fileui_frame",
    "spectrum_render_ikkle_at",
    "spectrum_render_fileui_select",
    # S7: SAVELOAD/FILEUI call this between esx_* I/O steps so a live
    # DIRECT session keeps servicing traffic while blocked on disk I/O
    # (was dss_fileio.asm's S6-era no-op; now unet_link.c's real
    # implementation, WIN1 -- nc_pump underneath).
    "spectrum_net_background_drain",
    # S8 step 8d: the NET overlay's MQTT connect flow (src/sprinter/
    # net_mqtt_ui_sprinter.c) builds its own CONNECT/SUBSCRIBE packets and
    # topic strings, needing the same portable codec/formatting primitives
    # unet_link.c (WIN1) already uses for PUBLISH -- src/spectrum/platform/
    # text.c's builders and src/spectrum/transport/mqtt_min.c's packet
    # encoders/type reader.
    "spectrum_append_text",
    "spectrum_append_u16",
    "spectrum_mqtt_subscribe",
    "spectrum_mqtt_type",
    # config/session.c globals the connect flow reads directly (room code,
    # broker host/port, local color/role, host_color_ready, the MQTT
    # session-id nonce) -- same cross-boundary shape board.c's side_to_move
    # etc. above already use.
    "netchesszx_mqtt_code",
    "netchesszx_mqtt_host",
    "netchesszx_mqtt_port",
    "netchesszx_local_color",
    "netchesszx_session_role",
    "netchesszx_host_color_ready",
    "netchesszx_mqtt_session_id",
    # S8 step 8e: the NET screen's own ENTER handler configures the session
    # (role/transport/host_color the user picked) before dispatching either
    # connect flow -- same call session_sprinter.c's DIRECT path already
    # makes, now also reachable from this overlay.
    "netchesszx_session_configure",
    # net_frame.c's MQTT stream reassembler (WIN2 blob) -- reaches this
    # overlay the SAME way spectrum_net_background_drain above already
    # does: resident_c.bin links netframe_defs.asm directly, so these
    # PUBLIC nc_mqtt_* defc's (pointing into the WIN2 blob) appear in
    # resident_c.map too, transitively. Do NOT also link netframe_defs.asm
    # into this overlay's own build -- see the Makefile's own comment on
    # SPRINTER_OVL_NET_BIN for why that duplicate-defines every
    # game_protocol.c string constant both files bridge.
    "nc_mqtt_pump",
    "nc_mqtt_take",
    "nc_mqtt_packet",
    "nc_mqtt_consume",
    # nc_mqtt_reset is needed here for a reason the other four are not:
    # unet_link.c's spectrum_net_mqtt_start() (WIN1) calls it before
    # dispatching this overlay, but the NET screen calls net_mqtt_connect_
    # start_ovl() DIRECTLY (same overlay image, no WIN1 round trip), so that
    # wrapper -- and therefore the only reset of the accumulator and of the
    # nc_fatal latch SHARED with the DIRECT line splitter -- was skipped on
    # the screen's own path entirely (2026-08-15).
    "nc_mqtt_reset",
    # mqtt_session_wire.c's topic-suffix builders and unet_link.c's own
    # publish_presence/publish_setup (both WIN1 resident since S8 step 8c)
    # -- the NET overlay's connect flow needs all six for subscribe/publish
    # topics and to arm presence once activated.
    "spectrum_net_mqtt_in_suffix",
    "spectrum_net_mqtt_in_ack_suffix",
    "spectrum_net_mqtt_peer_presence_suffix",
    "spectrum_net_mqtt_presence_suffix",
    "spectrum_net_mqtt_publish_presence",
    "spectrum_net_mqtt_publish_setup",
    # Clears WIN1's per-link MQTT state (broker-keepalive counters above all)
    # for a fresh broker session. Called from the overlay rather than only
    # from spectrum_net_mqtt_start because the NET screen dispatches
    # net_mqtt_connect_start_ovl directly and never runs that function.
    "spectrum_net_mqtt_link_reset",
    # The connect flow's own failure cells. They live in WIN1 (unet_link.c),
    # not in this overlay's BSS, because session_sprinter.c has to read them
    # too now that the frame loop dispatches activate_side/probe_seat -- and
    # an overlay's BSS is unreadable the moment its page is swapped out.
    "net_mqtt_fail_step",
    "net_mqtt_fail_cf",
    "net_mqtt_fail_status",
    "net_mqtt_fail_detail",
]

# Second, independent allowlist -- the entry points tests/sprinter/z80/
# t_net_mqtt_read.asm calls in the SHIPPED resident image (it INCBINs
# build/sprinter/resident.bin at $4000 and calls in by .map address, exactly
# as t_net_frame_blob.asm already does for the WIN2 blob). Kept apart from
# OVERLAY_RESIDENT_SYMBOLS above because the two lists answer different
# questions: that one is "what may an overlay link against" (a shipping
# contract), this one is "what does the harness poke at" (a test fixture).
# Adding a name here costs nothing at runtime and must never be taken as
# permission for overlay code to call it.
RESIDENT_TEST_SYMBOLS = [
    "spectrum_net_read_payload",
    "spectrum_net_payload_flags",
    "spectrum_net_background_drain",
    "netchesszx_transport",
    "netchesszx_session_role",
    "netchesszx_local_color",
    "netchesszx_mqtt_code",
    "netchesszx_session_poll",
    "netchesszx_session_peer_ready_state",
    "netchesszx_host_color_ready",
    "netchesszx_mqtt_session_id",
]

GENERATED_BANNER = (
    "Generated by tools/gen_sprinter_overlay_defs.py from the resident C "
    "image's .map file. Do not edit by hand."
)

# z88dk map lines: "_name    = $ADDR ; addr, public, ...". C symbols always
# carry the leading underscore z88dk adds; the allowlist below omits it (to
# read the same as the C source) and this parser strips it back off so both
# sides agree on one canonical (unprefixed) key.
MAP_LINE = re.compile(r"^_(\S+)\s+=\s+\$([0-9A-Fa-f]+)\s*;")


class OverlayDefsError(Exception):
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
        raise OverlayDefsError(
            "missing resident symbol(s) (add to SPRINTER_RESIDENT_C_SRC or "
            "drop from OVERLAY_RESIDENT_SYMBOLS): " + ", ".join(missing)
        )
    lines = [f";; {GENERATED_BANNER}",
             ";; z88dk-z80asm syntax (consumed by overlay C sources linked "
             "separately from the resident, e.g. entry_control_sprinter.asm)",
             ""]
    for name in names:
        addr = symbols[name]
        lines.append(f"PUBLIC _{name}")
        lines.append(f"defc _{name} = ${addr:04X}")
    lines.append("")
    return "\n".join(lines)


def render_sjasmplus(symbols: dict[str, int], names: list[str]) -> str:
    """Same addresses, sjasmplus EQU syntax, for the z80 test harness.

    tests/sprinter/z80/t_net_mqtt_read.asm INCBINs the REAL spliced resident
    image (build/sprinter/resident.bin, WIN1+WIN2 exactly as SHATRANJ.EXE
    carries it) and drives its MQTT read path by calling these addresses.
    Same reasoning as gen_sprinter_netframe_defs.py's own sjasmplus mode:
    host gcc tests prove the algorithm, not the bytes that ship, and this
    port has now lost several MAME rounds to that gap.
    """
    missing = [name for name in names if name not in symbols]
    if missing:
        raise OverlayDefsError(
            "missing resident symbol(s): " + ", ".join(missing)
        )
    lines = [f";; {GENERATED_BANNER}",
             ";; sjasmplus syntax (consumed by tests/sprinter/z80/"
             "t_net_mqtt_read.asm)",
             ""]
    for name in names:
        lines.append(f"res_{name}: EQU ${symbols[name]:04X}")
    lines.append("")
    return "\n".join(lines)


def _clean_fixture() -> str:
    return (
        "_spectrum_net_read_payload      = $6D67 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_read_payload::0::0:6\n"
        "_spectrum_net_payload_flags     = $6EA4 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_payload_flags::0::0:6\n"
        "_netchesszx_transport           = $78D2 ; addr, public, , "
        "src_spectrum_config_session_c, data_compiler, "
        "src/spectrum/config/session.c:6\n"
        "_netchesszx_session_poll        = $5F98 ; addr, public, , "
        "src_spectrum_session_poll_c, code_compiler, "
        "src/spectrum/session/poll.c::netchesszx_session_poll::0::0:82\n"
        "_netchesszx_session_peer_ready_state = $78D5 ; addr, public, , "
        "src_spectrum_config_session_c, bss_compiler, "
        "src/spectrum/config/session.c:9\n"
        "_netchess_after_prefix          = $4259 ; addr, public, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::netchess_after_prefix::0::0:37\n"
        "_netchess_mqtt_session_parse_u16_token = $4688 ; addr, public, , "
        "src_common_protocol_mqtt_session_protocol_c, code_compiler, "
        "src/common/protocol/mqtt_session_protocol.c::"
        "netchess_mqtt_session_parse_u16_token::0::0:5\n"
        "_NETCHESS_PROTO_ACK_PREFIX      = $49D9 ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:12\n"
        "_NETCHESS_PROTO_NACK_PREFIX     = $49DE ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:13\n"
        "_NETCHESS_PROTO_MOVE_PREFIX     = $49E4 ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:14\n"
        "_NETCHESS_PROTO_CHAT_PREFIX     = $49EA ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:15\n"
        "_NETCHESS_PROTO_DRAW            = $49F0 ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:16\n"
        "_NETCHESS_PROTO_CANCEL_DRAW     = $49F5 ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:17\n"
        "_NETCHESS_PROTO_CANCEL_RESET    = $4A01 ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:18\n"
        "_NETCHESS_PROTO_ACK_RESIGN      = $4A0E ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:19\n"
        "_NETCHESS_PROTO_GAME_START      = $4A19 ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:20\n"
        "_NETCHESS_PROTO_NACK_RESET      = $4A24 ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:21\n"
        "_NETCHESS_PROTO_BYE             = $4A2F ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:22\n"
        "_NETCHESS_PROTO_TAKEBACK_PREFIX = $4A33 ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:23\n"
        "_NETCHESS_PROTO_ACK_PING        = $4A3D ; addr, public, , "
        "src_common_protocol_game_protocol_c, rodata_compiler, "
        "src/common/protocol/game_protocol.c:24\n"
        "_side_to_move                   = $4B01 ; addr, public, , "
        "src_spectrum_board_board_c, bss_compiler, "
        "src/spectrum/board/board.c:51\n"
        "_castle_rights                  = $4B02 ; addr, public, , "
        "src_spectrum_board_board_c, bss_compiler, "
        "src/spectrum/board/board.c:52\n"
        "_ep_square                      = $4B03 ; addr, public, , "
        "src_spectrum_board_board_c, bss_compiler, "
        "src/spectrum/board/board.c:53\n"
        "_spectrum_fileui_count          = $4B40 ; addr, public, , "
        "src_spectrum_fileui_fileui_c, bss_compiler, "
        "src/spectrum/fileui/fileui.c:19\n"
        "_spectrum_fileui_used_mask      = $4B41 ; addr, public, , "
        "src_spectrum_fileui_fileui_c, bss_compiler, "
        "src/spectrum/fileui/fileui.c:20\n"
        "_spectrum_render_fileui_frame   = $4B60 ; addr, public, , "
        "asm_sprinter_zcc_cold_thunks_asm, code_user, "
        "build/sprinter/generated/cold_thunks.asm:1\n"
        "_spectrum_render_ikkle_at       = $4B68 ; addr, public, , "
        "asm_sprinter_zcc_cold_thunks_asm, code_user, "
        "build/sprinter/generated/cold_thunks.asm:1\n"
        "_spectrum_render_fileui_select  = $4B70 ; addr, public, , "
        "asm_sprinter_zcc_cold_thunks_asm, code_user, "
        "build/sprinter/generated/cold_thunks.asm:1\n"
        "_spectrum_net_background_drain  = $4B50 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_background_drain::0::0:6\n"
        "_spectrum_append_text           = $4B80 ; addr, public, , "
        "src_spectrum_platform_text_c, code_compiler, "
        "src/spectrum/platform/text.c::spectrum_append_text::0::0:6\n"
        "_spectrum_append_u16            = $4B90 ; addr, public, , "
        "src_spectrum_platform_text_c, code_compiler, "
        "src/spectrum/platform/text.c::spectrum_append_u16::0::0:6\n"
        "_spectrum_mqtt_subscribe        = $4BA0 ; addr, public, , "
        "src_spectrum_transport_mqtt_min_c, code_compiler, "
        "src/spectrum/transport/mqtt_min.c::spectrum_mqtt_subscribe::0::0:6\n"
        "_spectrum_mqtt_type             = $4BB0 ; addr, public, , "
        "src_spectrum_transport_mqtt_min_c, code_compiler, "
        "src/spectrum/transport/mqtt_min.c::spectrum_mqtt_type::0::0:6\n"
        "_netchesszx_mqtt_code           = $4BC0 ; addr, public, , "
        "src_spectrum_config_session_c, bss_compiler, "
        "src/spectrum/config/session.c:66\n"
        "_netchesszx_mqtt_host           = $4BD0 ; addr, public, , "
        "src_spectrum_config_session_c, data_compiler, "
        "src/spectrum/config/session.c:64\n"
        "_netchesszx_mqtt_port           = $4BE0 ; addr, public, , "
        "src_spectrum_config_session_c, data_compiler, "
        "src/spectrum/config/session.c:65\n"
        "_netchesszx_local_color         = $4BE2 ; addr, public, , "
        "src_spectrum_config_session_c, bss_compiler, "
        "src/spectrum/config/session.c:8\n"
        "_netchesszx_session_role        = $4BE3 ; addr, public, , "
        "src_spectrum_config_session_c, bss_compiler, "
        "src/spectrum/config/session.c:6\n"
        "_netchesszx_host_color_ready    = $4BE4 ; addr, public, , "
        "src_spectrum_config_session_c, bss_compiler, "
        "src/spectrum/config/session.c:10\n"
        "_netchesszx_mqtt_session_id     = $4BE5 ; addr, public, , "
        "src_spectrum_config_session_c, data_compiler, "
        "src/spectrum/config/session.c:17\n"
        "_netchesszx_session_configure   = $4BE6 ; addr, public, , "
        "src_spectrum_config_session_c, code_compiler, "
        "src/spectrum/config/session.c::netchesszx_session_configure::0::0:6\n"
        "_nc_mqtt_pump                   = $9FA1 ; addr, public, , "
        "asm_sprinter_zcc_netframe_defs_asm, code_user, "
        "build/sprinter/generated/netframe_defs.asm:1\n"
        "_nc_mqtt_take                   = $9FB0 ; addr, public, , "
        "asm_sprinter_zcc_netframe_defs_asm, code_user, "
        "build/sprinter/generated/netframe_defs.asm:1\n"
        "_nc_mqtt_packet                 = $9FC0 ; addr, public, , "
        "asm_sprinter_zcc_netframe_defs_asm, code_user, "
        "build/sprinter/generated/netframe_defs.asm:1\n"
        "_nc_mqtt_consume                = $9FD0 ; addr, public, , "
        "asm_sprinter_zcc_netframe_defs_asm, code_user, "
        "build/sprinter/generated/netframe_defs.asm:1\n"
        "_nc_mqtt_reset                  = $9FE0 ; addr, public, , "
        "asm_sprinter_zcc_netframe_defs_asm, code_user, "
        "build/sprinter/generated/netframe_defs.asm:1\n"
        "_spectrum_net_mqtt_in_suffix    = $4BF0 ; addr, public, , "
        "src_spectrum_transport_mqtt_session_wire_c, code_compiler, "
        "src/spectrum/transport/mqtt_session_wire.c::spectrum_net_mqtt_in_suffix::0::0:6\n"
        "_spectrum_net_mqtt_in_ack_suffix = $4C00 ; addr, public, , "
        "src_spectrum_transport_mqtt_session_wire_c, code_compiler, "
        "src/spectrum/transport/mqtt_session_wire.c::spectrum_net_mqtt_in_ack_suffix::0::0:6\n"
        "_spectrum_net_mqtt_peer_presence_suffix = $4C10 ; addr, public, , "
        "src_spectrum_transport_mqtt_session_wire_c, code_compiler, "
        "src/spectrum/transport/mqtt_session_wire.c::spectrum_net_mqtt_peer_presence_suffix::0::0:6\n"
        "_spectrum_net_mqtt_presence_suffix = $4C20 ; addr, public, , "
        "src_spectrum_transport_mqtt_session_wire_c, code_compiler, "
        "src/spectrum/transport/mqtt_session_wire.c::spectrum_net_mqtt_presence_suffix::0::0:6\n"
        "_spectrum_net_mqtt_link_reset   = $4C28 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_mqtt_link_reset::0::0:6\n"
        "_net_mqtt_fail_step             = $4C50 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, bss_compiler, "
        "src/sprinter/transport/unet_link.c::net_mqtt_fail_step::0::0:6\n"
        "_net_mqtt_fail_cf               = $4C51 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, bss_compiler, "
        "src/sprinter/transport/unet_link.c::net_mqtt_fail_cf::0::0:6\n"
        "_net_mqtt_fail_status           = $4C52 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, bss_compiler, "
        "src/sprinter/transport/unet_link.c::net_mqtt_fail_status::0::0:6\n"
        "_net_mqtt_fail_detail           = $4C53 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, bss_compiler, "
        "src/sprinter/transport/unet_link.c::net_mqtt_fail_detail::0::0:6\n"
        "_spectrum_net_mqtt_publish_presence = $4C30 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_mqtt_publish_presence::0::0:6\n"
        "_spectrum_net_mqtt_publish_setup = $4C40 ; addr, public, , "
        "src_sprinter_transport_unet_link_c, code_compiler, "
        "src/sprinter/transport/unet_link.c::spectrum_net_mqtt_publish_setup::0::0:6\n"
        "i_15                            = $4259 ; addr, local, , "
        "src_common_protocol_game_protocol_c, code_compiler, "
        "src/common/protocol/game_protocol.c::netchess_after_prefix::0::0:37\n"
    )


def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        map_path = Path(tmp) / "clean.map"
        map_path.write_text(_clean_fixture(), encoding="ascii")
        symbols = parse_map(map_path)

        if symbols.get("netchess_after_prefix") != 0x4259:
            raise SystemExit("[ERR] overlay-defs self-test: function symbol not parsed")
        if symbols.get("NETCHESS_PROTO_ACK_PREFIX") != 0x49D9:
            raise SystemExit("[ERR] overlay-defs self-test: data symbol not parsed")
        # z88dk's compiler-local labels (i_15, no leading underscore) must
        # not crash the parse or leak into the allowlist-checked symbol set.
        if "i_15" in symbols:
            raise SystemExit("[ERR] overlay-defs self-test: local label wrongly captured")

        out1 = render(symbols, OVERLAY_RESIDENT_SYMBOLS)
        out2 = render(symbols, OVERLAY_RESIDENT_SYMBOLS)
        if out1 != out2:
            raise SystemExit("[ERR] overlay-defs self-test: rendering is not deterministic")
        if "PUBLIC _netchess_after_prefix" not in out1:
            raise SystemExit("[ERR] overlay-defs self-test: underscored name missing")
        if "defc _netchess_after_prefix = $4259" not in out1:
            raise SystemExit("[ERR] overlay-defs self-test: address mismatch")
        if "defc _NETCHESS_PROTO_ACK_PREFIX = $49D9" not in out1:
            raise SystemExit("[ERR] overlay-defs self-test: data symbol address mismatch")

        try:
            render(symbols, OVERLAY_RESIDENT_SYMBOLS + ["totally_missing"])
        except OverlayDefsError as exc:
            if "totally_missing" not in str(exc):
                raise SystemExit(
                    "[ERR] overlay-defs self-test: wrong missing-symbol diagnostic"
                )
        else:
            raise SystemExit(
                "[ERR] overlay-defs self-test: missing symbol was not rejected"
            )

        sj = render_sjasmplus(symbols, RESIDENT_TEST_SYMBOLS)
        if "res_spectrum_net_read_payload: EQU $6D67" not in sj:
            raise SystemExit(
                "[ERR] overlay-defs self-test: sjasmplus mode address mismatch"
            )
        if sj != render_sjasmplus(symbols, RESIDENT_TEST_SYMBOLS):
            raise SystemExit(
                "[ERR] overlay-defs self-test: sjasmplus mode not deterministic"
            )

    print("[OK] Sprinter overlay-defs self-test")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map", type=Path, help="resident_c.map to read")
    parser.add_argument("--out", type=Path, help="overlay_defs.asm to write")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--mode",
        choices=["defc", "sjasmplus"],
        default="defc",
        help="output syntax: z88dk defc (the overlay builds, "
             "OVERLAY_RESIDENT_SYMBOLS) or sjasmplus EQU (the z80 resident "
             "test harness, RESIDENT_TEST_SYMBOLS)",
    )
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if not args.map or not args.out:
        raise SystemExit(
            "gen_sprinter_overlay_defs: --map and --out are required unless --self-test"
        )

    symbols = parse_map(args.map)
    try:
        if args.mode == "sjasmplus":
            text = render_sjasmplus(symbols, RESIDENT_TEST_SYMBOLS)
        else:
            text = render(symbols, OVERLAY_RESIDENT_SYMBOLS)
    except OverlayDefsError as exc:
        print(f"[ERR] {args.map}: {exc}", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text, encoding="ascii")
    print(f"[OK] {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
