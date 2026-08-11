#!/usr/bin/env python3
"""Enforce the S3 WIN1/WIN2 net-mechanics section split (port.md section 5).

During any blocking libman l_call, WIN1 is occupied by the loaded DLL AND
interrupts are enabled (the RTL backend re-enables EI internally; entering
l_call with EI is required -- ftpclient's precedent). Anything that must
survive such a call -- the frame-tick ISR state, net_gate's own state, the
overlay dispatch context -- must therefore live in the WIN2 half
([#8000,#C000)), which stays mapped throughout. This gate reads the
sjasmplus --sym output of the assembled platform primitives blob and checks
that split statically, so a symbol drifting back into WIN1 fails the build
instead of corrupting a loaded DLL's image at runtime the next time someone
touches it.

libman itself (extern/libman, pinned) is placed in the WIN2 half too (no
LIBMAN_WIN0), except LIBMAN.ll_path, which is `EQU 0xC000` by design (a
scratch WIN3 page constant used only while WIN3 is temporarily mapped there
during l_load, never resident code or state) and is allowlisted. LIBMAN.*
symbols valued below the resident's own base address (#4000) are the
module's internal manifest constants (LS_*, LR_*, DSS_OPEN, ...), not
addresses -- nothing in this flat resident image is ever placed below
#4000, so a value that low can only be a constant and is left unchecked.

The symbol table is the only place this information exists (`asm/sprinter/
*.asm` doesn't record final addresses), so this gate operates on --sym
output rather than scanning source text like check_sprinter_accel.py/
check_sprinter_win0.py -- but keeps their same shape: a pure, accumulating-
error check function plus a mandatory --self-test with a clean fixture and
several deliberately-broken ones, each checked for its specific diagnostic.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

SYM_LINE = re.compile(r"^([A-Za-z_][\w.]*):\s+EQU\s+0x([0-9A-Fa-f]{8})\s*$")

RESIDENT_BASE = 0x4000
WIN2_LOW = 0x8000
WIN2_HIGH = 0xC000  # exclusive

LIBMAN_PREFIX = "LIBMAN."
LIBMAN_ALLOWLIST = {"LIBMAN.ll_path"}

WIN2_REQUIRED_PREFIXES = ("ng_", "ovl_ctx")
WIN2_REQUIRED_EXACT = ("frame_flag", "im2_saved_i")

# Grows as each module is wired in (port.md section 5/S5 sequencing):
# frame_flag/im2_saved_i first (the defect this gate exists to pin down),
# then libman/net_gate (LIBMAN.l_call/ng_call/ng_v_depth). echo_tick (S3's
# echo-client stand) was required here through S4; the stand -- and the
# requirement -- were removed in S5 (plan D4, port.md section 3.10).
REQUIRED_PRESENT = (
    "frame_flag",
    "im2_saved_i",
    "LIBMAN.l_call",
    "ng_call",
    "ng_v_depth",
)
LIBMAN_MIN_SYMBOLS = 20


def parse_sym(text: str) -> tuple[dict[str, int], list[str]]:
    """Return (symbols, parse errors). A non-blank line that doesn't match
    the expected 'NAME: EQU 0xXXXXXXXX' shape is an error, not a skip -- a
    format change in sjasmplus's --sym output must fail loudly, not silently
    empty out the symbol table this gate relies on."""
    symbols: dict[str, int] = {}
    errors: list[str] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped:
            continue
        m = SYM_LINE.match(stripped)
        if not m:
            errors.append(f"line {lineno}: unparsable symbol-table line: {line!r}")
            continue
        symbols[m.group(1)] = int(m.group(2), 16)
    return symbols, errors


def _in_win2(addr: int) -> bool:
    return WIN2_LOW <= addr < WIN2_HIGH


def check_symbols(symbols: dict[str, int]) -> list[str]:
    errors: list[str] = []

    for name, addr in symbols.items():
        if name.startswith(LIBMAN_PREFIX):
            if name in LIBMAN_ALLOWLIST:
                continue
            if addr < RESIDENT_BASE:
                continue  # module-internal manifest constant, not an address
            if not _in_win2(addr):
                errors.append(
                    f"{name} at #{addr:04X}: LIBMAN symbol placed outside "
                    "the WIN2 half [#8000,#C000) (S3 net-section policy)"
                )
            continue

        is_required_prefixed = name in WIN2_REQUIRED_EXACT or any(
            name.startswith(p) for p in WIN2_REQUIRED_PREFIXES
        )
        if is_required_prefixed and not _in_win2(addr):
            errors.append(
                f"{name} at #{addr:04X}: must live in the WIN2 half "
                "[#8000,#C000) (S3 net-section policy)"
            )

    for required in REQUIRED_PRESENT:
        if required not in symbols:
            errors.append(
                f"required symbol missing from the symbol table: {required}"
            )

    libman_count = sum(1 for name in symbols if name.startswith(LIBMAN_PREFIX))
    if libman_count > 0:
        # Any LIBMAN.* symbol at all means the module claims to be wired
        # in; a real inclusion produces dozens of symbols, so a handful is
        # a sign of a broken/partial include, not just "not wired up yet"
        # (that case has zero LIBMAN.* symbols and skips this check).
        if libman_count < LIBMAN_MIN_SYMBOLS:
            errors.append(
                f"only {libman_count} LIBMAN.* symbols present (need >= "
                f"{LIBMAN_MIN_SYMBOLS}); libman.asm may not actually be included"
            )

    return errors


def check_sym_text(text: str) -> list[str]:
    symbols, errors = parse_sym(text)
    errors = list(errors)
    errors.extend(check_symbols(symbols))
    return errors


def check_sym_file(path: Path) -> list[str]:
    if not path.is_file():
        return [f"{path}: symbol file missing (build the resident with --sym first)"]
    return check_sym_text(path.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Self-test: a clean fixture must validate, and each fixture with exactly one
# invariant deliberately broken must be rejected (check_sprinter_accel.py /
# check_sprinter_win0.py pattern).
# ---------------------------------------------------------------------------

def _sym_line(name: str, addr: int) -> str:
    return f"{name}: EQU 0x{addr:08X}"


def _clean_lines() -> list[str]:
    lines = [
        # Unrelated WIN1-half code/labels must never be flagged.
        _sym_line("trampoline", 0x4100),
        _sym_line("svmod_safe", 0x8100),
        _sym_line("svmod_safe.saved_win1", 0x8110),
        # The defect this gate exists to catch, now fixed.
        _sym_line("frame_flag", 0x8191),
        _sym_line("im2_saved_i", 0x8192),
        # net_gate.asm state, correctly in WIN2.
        _sym_line("ng_call", 0x8200),
        _sym_line("ng_v_depth", 0x8210),
        _sym_line("ng_up", 0x8220),
        # Overlay dispatch code lives in WIN1 (future S5 location); only its
        # context buffer is required to live in WIN2.
        _sym_line("ovl_exec", 0x5000),
        _sym_line("ovl_ctx", 0x8400),
        # A LIBMAN module-internal constant (well below #4000): unchecked.
        _sym_line("LIBMAN.LS_NONE", 0x0000),
        _sym_line("LIBMAN.DSS_OPEN", 0x0011),
        # LIBMAN.ll_path: allowlisted scratch-page constant at WIN3 (#C000).
        _sym_line("LIBMAN.ll_path", 0xC000),
    ]
    # Real LIBMAN code/state, all correctly in WIN2, padded past the
    # minimum-symbol-count floor.
    for i in range(LIBMAN_MIN_SYMBOLS + 5):
        lines.append(_sym_line(f"LIBMAN.sym_{i}", 0x8500 + i))
    lines.append(_sym_line("LIBMAN.l_call", 0x8500))
    return lines


def _clean_text() -> str:
    return "\n".join(_clean_lines()) + "\n"


def _expect_reject(lines: list[str], needle: str, description: str) -> None:
    errors = check_sym_text("\n".join(lines) + "\n")
    if not any(needle in error for error in errors):
        raise SystemExit(
            f"[ERR] net-section policy self-test: {description} "
            f"(expected an error containing {needle!r}, got {errors})"
        )


def self_test() -> None:
    if check_sym_text(_clean_text()):
        raise SystemExit(
            "[ERR] net-section policy self-test rejected a clean symbol table: "
            f"{check_sym_text(_clean_text())}"
        )

    # The exact defect this gate exists to prevent: frame_flag back in WIN1.
    broken = [
        l.replace("0x00008191", "0x00004500") if l.startswith("frame_flag:") else l
        for l in _clean_lines()
    ]
    _expect_reject(
        broken, "must live in the WIN2 half",
        "accepted frame_flag placed back in the WIN1 half",
    )

    broken = [
        l.replace("0x00008192", "0x00004500") if l.startswith("im2_saved_i:") else l
        for l in _clean_lines()
    ]
    _expect_reject(
        broken, "must live in the WIN2 half",
        "accepted im2_saved_i placed back in the WIN1 half",
    )

    broken = [
        l.replace("0x00008200", "0x00004600") if l.startswith("ng_call:") else l
        for l in _clean_lines()
    ]
    _expect_reject(
        broken, "must live in the WIN2 half",
        "accepted ng_call placed in the WIN1 half",
    )

    broken = [
        l.replace("0x00008400", "0x00004700") if l.startswith("ovl_ctx:") else l
        for l in _clean_lines()
    ]
    _expect_reject(
        broken, "must live in the WIN2 half",
        "accepted ovl_ctx placed in the WIN1 half",
    )

    # ovl_exec (dispatch code) staying in WIN1 must NOT be flagged: only
    # ovl_ctx is WIN2-required.
    if check_sym_text(_clean_text()):
        raise SystemExit(
            "[ERR] net-section policy self-test flagged ovl_exec in WIN1 "
            "(only ovl_ctx is WIN2-required)"
        )

    broken = [
        l.replace("0x00008500", "0x00004800") if l.startswith("LIBMAN.l_call:") else l
        for l in _clean_lines()
    ]
    _expect_reject(
        broken, "LIBMAN symbol placed outside",
        "accepted a LIBMAN.* symbol placed in the WIN1 half",
    )

    broken = _clean_lines() + [_sym_line("LIBMAN.stray_high", 0xC050)]
    _expect_reject(
        broken, "LIBMAN symbol placed outside",
        "accepted a non-allowlisted LIBMAN.* symbol at/above WIN2_HIGH",
    )

    # The allowlisted ll_path itself is exempt no matter where it lands --
    # it is a scratch WIN3-page constant, not resident code/state.
    allowlisted_moved = [
        l.replace("0x0000C000", "0x0000C100") if l.startswith("LIBMAN.ll_path:") else l
        for l in _clean_lines()
    ]
    if check_sym_text("\n".join(allowlisted_moved) + "\n"):
        raise SystemExit(
            "[ERR] net-section policy self-test flagged the allowlisted "
            "LIBMAN.ll_path constant regardless of its value"
        )

    # LIBMAN constants below #4000 must never be flagged, even at #0000.
    if check_sym_text(_clean_text()):
        raise SystemExit(
            "[ERR] net-section policy self-test flagged a LIBMAN manifest "
            "constant (LS_NONE/DSS_OPEN) as a misplaced address"
        )

    missing_name = REQUIRED_PRESENT[0]
    missing = [l for l in _clean_lines() if not l.startswith(f"{missing_name}:")]
    _expect_reject(
        missing, "required symbol missing",
        "accepted a symbol table missing a required S3 symbol",
    )

    too_few_libman = [
        l for l in _clean_lines()
        if not (l.startswith("LIBMAN.sym_") and l.split(":")[0] not in
                ("LIBMAN.sym_0", "LIBMAN.sym_1"))
    ]
    _expect_reject(
        too_few_libman, "LIBMAN.* symbols present",
        "accepted a symbol table with too few LIBMAN.* symbols to plausibly "
        "be a real libman.asm inclusion",
    )

    _expect_reject(
        ["this is not a symbol line"], "unparsable",
        "accepted an unparsable symbol-table line",
    )

    print("[OK] Sprinter net-section policy self-test")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sym", type=Path,
                        default=Path("build/sprinter/platform_primitives.sym"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    errors = check_sym_file(args.sym)
    if errors:
        print(f"[ERR] Sprinter net-section policy: violation(s) found in {args.sym}")
        for error in errors:
            print(f"  {error}")
        return 1

    print(f"[OK] Sprinter net-section policy: WIN1/WIN2 split holds ({args.sym})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
