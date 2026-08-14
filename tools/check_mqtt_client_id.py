#!/usr/bin/env python3
"""Guard the broker-only MQTT ClientId contract on PC and Spectrum."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"[ERR] MQTT ClientId contract: {message}")


def equ(source: str, name: str) -> int:
    match = re.search(rf"^{name}\s+EQU\s+(\d+)\s*$", source, re.MULTILINE)
    if not match:
        fail(f"missing {name}")
    return int(match.group(1))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args()
    root = Path(args.root)

    asm = (root / "asm/overlay/mqtt_connect/entry_mqtt_connect.asm").read_text(
        encoding="utf-8"
    )
    session_h = (root / "src/spectrum/config/session.h").read_text(encoding="utf-8")
    pc = (root / "src/pc/client/main_window.cpp").read_text(encoding="utf-8")

    room_match = re.search(r"#define NETCHESSZX_MQTT_CODE_MAX\s+(\d+)u", session_h)
    if not room_match:
        fail("missing Spectrum room limit")
    room_max = int(room_match.group(1))
    if (
        "#define NETCHESSZX_SESSION_ROLE_HOST 0u" not in session_h
        or "#define NETCHESSZX_SESSION_ROLE_JOIN 1u" not in session_h
    ):
        fail("Spectrum H/J role encoding no longer matches session roles")
    fixed = equ(asm, "mqtt_client_id_fixed")
    if fixed + room_max > 23:
        fail("Spectrum ClientId exceeds the portable 23-byte limit")
    remaining = equ(asm, "mqtt_remaining_base")
    packet = equ(asm, "mqtt_packet_base")
    if remaining != fixed + 40 or packet != remaining + 2:
        fail("Spectrum CONNECT lengths do not match the ClientId layout")
    if 'DEFB 0, 4, "MQTT", 4, $06' not in asm:
        fail("Spectrum retry identity requires CONNECT Clean Session")

    try:
        client_body = asm.split("mqtt_client_id_begin:", 1)[1].split(
            "mqtt_client_id_end:", 1
        )[0]
    except IndexError:
        fail("missing Spectrum ClientId builder bounds")
    for token in (
        "ld a, 'Z'",
        "ld a, 'X'",
        "add a, a",
        "add a, 'H'",
        "_netchesszx_mqtt_code",
        "_netchesszx_session_role",
        "ld hl, ($5c78)",
        "ld a, h",
        "ld h, l",
        "ld b, 2",
    ):
        if token not in client_body:
            fail(f"Spectrum ClientId builder misses {token}")
    if (
        "_netchesszx_local_color" in client_body
        or "_mqtt_next_id" in client_body
        or "'-'" in client_body
    ):
        fail("Spectrum ClientId depends on color, packet-id, or punctuation")
    if (
        client_body.count("call mqtt_conn_hex_digit") != 2
        or "mqtt_conn_hex_digit:\n    and $0f\n    add a, '0'" not in asm
    ):
        fail("Spectrum nonce must emit four hexadecimal digits")

    if "SHATRANJ-CLIENT-" in pc:
        fail("PC ClientId still depends on room/side")
    if 'QStringLiteral("PC%1%2")' not in pc:
        fail("missing portable PC ClientId formatter")
    if "mqttClientIdFor(pcIsHost_, mqttClientNonce_)" not in pc:
        fail("PC CONNECT does not use the instance nonce")

    check_sprinter(root, room_max)

    print(
        f"[OK] MQTT ClientId contract: PC 19 bytes; Spectrum <= {fixed + room_max}"
    )


def check_sprinter(root: Path, room_max: int) -> None:
    """Sprinter (S8 step 8d) builds the same CONNECT packet in C instead of
    Z80 (asm/overlay/mqtt_connect/entry_mqtt_connect.asm's own reason for
    hand-written asm -- fitting ZX's 2 KiB copy slot -- does not apply to
    Sprinter's own WIN3 overlay page). Same wire contract, different
    source shape: this is an ADDITIVE check alongside the ZX/asm one above,
    not a replacement -- no existing assertion above becomes conditional."""
    src = (
        root / "src/sprinter/net_mqtt_ui_sprinter.c"
    ).read_text(encoding="utf-8")

    fixed_match = re.search(r"room_len \+ (\d+)u\)\)?;\s*/\* ClientId len lo", src)
    if not fixed_match:
        fail("Sprinter ClientId length formula not found")
    fixed = int(fixed_match.group(1))
    if fixed + room_max > 23:
        fail("Sprinter ClientId exceeds the portable 23-byte limit")

    remaining_match = re.search(
        r"room_len \* 2u \+ (\d+)u\); /\* remaining length", src
    )
    packet_match = re.search(r"return \(uint8_t\)\(room_len \* 2u \+ (\d+)u\);", src)
    if not remaining_match or not packet_match:
        fail("Sprinter CONNECT length formulas not found")
    remaining = int(remaining_match.group(1))
    packet = int(packet_match.group(1))
    if remaining != fixed + 40 or packet != remaining + 2:
        fail("Sprinter CONNECT lengths do not match the ClientId layout")

    if "0x10u;" not in src or "0x06u;" not in src:
        fail("Sprinter CONNECT packet type/flags byte missing")
    if "'M'; *p++ = 'Q'; *p++ = 'T'; *p++ = 'T';" not in src:
        fail("Sprinter CONNECT protocol name missing")

    try:
        client_body = src.split("*p++ = 'Z'; *p++ = 'X';", 1)[1].split(
            "*p++ = 0u;", 1
        )[0]
    except IndexError:
        fail("missing Sprinter ClientId builder bounds")
    if "netchesszx_session_role * 2u + 'H'" not in client_body:
        fail("Sprinter ClientId role-char formula missing")
    if (
        "netchesszx_local_color" in client_body
        or "mqtt_ovl_next_id" in client_body
        or "'-'" in client_body
    ):
        fail("Sprinter ClientId depends on color, packet-id, or punctuation")
    if client_body.count("mqtt_ovl_hex_digit(") != 4:
        fail("Sprinter nonce must emit four hexadecimal digits")


if __name__ == "__main__":
    main()
