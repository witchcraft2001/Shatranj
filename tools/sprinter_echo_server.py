#!/usr/bin/env python3
"""TCP-echo peer for the S3 net stand (asm/sprinter/echo_s3.asm, hotkey 'C').

Accepts one connection at a time and echoes back every byte received,
unchanged. This is the second observation point for a soak run (the first
is echo_s3.asm's own on-screen rolling tx/rx sums): every connection,
disconnect, and received chunk is logged with its byte count and a hex
dump of the first 32 bytes, so a tester can cross-check what the Sprinter
stand's screen claims to have sent/received against what actually crossed
the wire.

Follows the sprinter-rtl8019a/tools/dev/dual_server.py pattern (argparse,
log() to stderr, plain blocking sockets) but is deliberately simpler: one
peer, one job (echo), no protocol-specific timing games.
"""

from __future__ import annotations

import argparse
import socket
import sys
import threading


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def hex_prefix(data: bytes, limit: int = 32) -> str:
    return data[:limit].hex()


def handle_connection(conn: socket.socket, address, chunk_size: int) -> None:
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    log(f"connected from {address[0]}:{address[1]}")
    total = 0
    try:
        while True:
            data = conn.recv(chunk_size)
            if not data:
                break
            total += len(data)
            log(
                f"chunk: {len(data)} bytes (total {total}), "
                f"first {min(len(data), 32)}B hex={hex_prefix(data)}"
            )
            conn.sendall(data)
    except (BrokenPipeError, ConnectionResetError, OSError) as error:
        log(f"connection error: {error}")
    finally:
        conn.close()
        log(f"disconnected {address[0]}:{address[1]} (echoed {total} bytes total)")


def serve(host: str, port: int, chunk_size: int, stop_event=None) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(1)
    server.settimeout(0.5 if stop_event is not None else None)
    log(f"sprinter echo server: listening on {host}:{port}")
    try:
        while stop_event is None or not stop_event.is_set():
            try:
                conn, address = server.accept()
            except socket.timeout:
                continue
            handle_connection(conn, address, chunk_size)
    finally:
        server.close()


# ---------------------------------------------------------------------------
# Self-test: real loopback client against a real server thread, no mocks --
# this tool's only job is moving bytes correctly, which a mock cannot prove.
# ---------------------------------------------------------------------------

def self_test() -> None:
    import time

    stop_event = threading.Event()
    port = 0
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    port = server.getsockname()[1]
    server.close()

    thread = threading.Thread(
        target=serve, args=("127.0.0.1", port, 4096, stop_event), daemon=True
    )
    thread.start()
    time.sleep(0.2)  # let the listener come up

    try:
        client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client.settimeout(5.0)
        client.connect(("127.0.0.1", port))

        probes = [b"<SQ:0001:SHTRJ>\n", b"", b"x" * 300, bytes(range(256))]
        for probe in probes:
            if not probe:
                continue
            client.sendall(probe)
            received = bytearray()
            while len(received) < len(probe):
                block = client.recv(4096)
                if not block:
                    raise SystemExit(
                        "[ERR] sprinter_echo_server self-test: connection "
                        "closed early"
                    )
                received.extend(block)
            if bytes(received) != probe:
                raise SystemExit(
                    "[ERR] sprinter_echo_server self-test: echoed bytes "
                    f"do not match (sent {len(probe)}, got {len(received)})"
                )

        # A second, sequential connection must also be served correctly
        # (the accept loop must not wedge after the first client closes).
        client.close()
        client2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client2.settimeout(5.0)
        client2.connect(("127.0.0.1", port))
        client2.sendall(b"second connection")
        received = client2.recv(4096)
        if received != b"second connection":
            raise SystemExit(
                "[ERR] sprinter_echo_server self-test: second connection "
                "not echoed correctly"
            )
        client2.close()
    finally:
        stop_event.set()
        thread.join(timeout=2.0)

    print("[OK] sprinter_echo_server self-test")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=7777)
    parser.add_argument("--chunk-size", type=int, default=4096)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if not (0 < args.port < 65536):
        parser.error("--port must be between 1 and 65535")
    if args.chunk_size <= 0:
        parser.error("--chunk-size must be positive")

    try:
        serve(args.host, args.port, args.chunk_size)
    except KeyboardInterrupt:
        log("stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
