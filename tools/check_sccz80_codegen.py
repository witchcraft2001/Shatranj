#!/usr/bin/env python3
"""Reject known sccz80 miscompiles in the Sprinter C build.

sccz80 (z88dk classic) is the Sprinter compiler; ZX/Next use SDCC and are not
affected by anything here. Two defect classes are checked, both found the hard
way on 2026-08-15 after four MAME round-trips.

CLASS 1: a CONSTANT index on a cast-literal pointer macro.

    #define NC_MQTT_STREAM ((uint8_t *)0xB706)
    b = NC_MQTT_STREAM[1u];        /* WRONG: compiles to `b = 7` */
    b = *(NC_MQTT_STREAM + 1u);    /* right: ld hl,0xB707 / ld a,(hl) */

sccz80 folds the address and then assigns its LOW BYTE as the value instead of
loading through it. A VARIABLE index compiles correctly, which is why this hid
for so long -- only two lines in the whole port used a constant one. It read
the MQTT remaining-length as 7 (the low byte of 0xB707), so the reassembler
waited for a 9-byte CONNACK that never comes; the broker then dropped the
connection on its keep-alive timer and the panel blamed the network.

sccz80 DOES warn about this (-Wlimited-range, "Value is out of range for
assignment"), so the check for class 1 is simply: **treat any sccz80 warning
on a Sprinter source as an error**. That is broader than the one known
pattern, and deliberately so -- the next codegen surprise will probably warn
too, and nobody reads warnings scrolling past in a build log.

CLASS 2: &&/|| inside a conditional expression's condition.

THE BUG (found 2026-08-15, after three MAME rounds chased its symptoms).
sccz80 -- the z88dk classic compiler this port uses, unlike ZX/Next's SDCC --
emits wrong code for a conditional expression whose CONDITION contains a
logical && or ||:

    return (!ng_v_call_cf && ng_v_call_status == NC_UNET_NERR_OK) ? 1u : 0u;

The && chain is evaluated correctly and its result MATERIALISED INTO HL as a
literal 1 or 0. The enclosing ternary is then compiled as if that result were
in the CARRY flag -- which the materialisation left clear, because `ld` does
not touch flags and the last flag-setter was an `and a`. The emitted shape is
always the same:

        ld      hl,1    ;const        <- the && result, in HL
        jr      i_8
    .i_7
        ld      hl,0    ;const        <- ...or here
    .i_8
        jp      nc,i_9                <- but tested in CF, which is ALWAYS 0
        ld      hl,1    ;const
        jp      i_10
    .i_9
        ld      hl,0    ;const        <- so this always wins
    .i_10

so the expression unconditionally yields the FALSE branch, whatever the
condition actually computed. It is silent: it compiles clean, links clean,
and every gate this project had stayed green.

What it cost before it was found: mqtt_ovl_send() reported every MQTT CONNECT
as a failed send (so the CONNACK wait never even ran, and the panel blamed the
broker); net_ui_filter_port() rejected every digit typed into the PORT field;
net_mqtt_publish_suffix() reported every publish as failed;
spectrum_net_connect_host() reported a successful DIRECT connect as failed;
and fileui.c turned every ERASE pick into a LOAD.

THE FIX is at the source level -- spell the condition out as an `if`, which
sccz80 compiles correctly:

    if (ng_v_call_cf) { return 0u; }
    if (ng_v_call_status != NC_UNET_NERR_OK) { return 0u; }
    return 1u;

WHY THIS GATE READS COMPILER OUTPUT rather than grepping the C. The C-level
trigger ("a ternary whose condition contains && or ||") happens to match all
five sites found, but it is a guess about sccz80's internals, not a fact about
them -- a differently-shaped condition could produce the same emitted bug, and
a ternary that merely mentions && inside a comment or string would produce a
false alarm. The emitted shape, by contrast, IS the defect: a carry-flag test
reached by fall-through from an instruction that cannot set carry. That is what
this checks, on the same sources, with the same flags, that the real build uses.

Runs `zcc -S` for each Sprinter-compiled C file and fails on any warning
(class 1) or any occurrence of the emitted shape (class 2).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# A label, then (skipping blank/comment/C_LINE lines) a carry-conditional jump.
LABEL_RE = re.compile(r"^\.[A-Za-z_][A-Za-z0-9_]*\s*$")
CARRY_JUMP_RE = re.compile(r"^(jp|jr)\s+n?c\s*,")
# Instructions that cannot leave a meaningful carry for the test below.
# `ld` never affects flags on the Z80; a constant load into HL is exactly how
# sccz80 materialises a logical expression's result.
CONST_LOAD_RE = re.compile(r"^ld\s+hl\s*,\s*\S")


def _instructions(lines: list[str]) -> list[tuple[int, str]]:
    """(index, stripped text) for lines that are real instructions or labels."""
    out = []
    for i, raw in enumerate(lines):
        text = raw.strip()
        if not text or text.startswith(";") or text.startswith("C_LINE"):
            continue
        # strip a trailing comment
        text = text.split(";", 1)[0].strip()
        if text:
            out.append((i, text))
    return out


def scan_asm(text: str) -> list[tuple[int, str]]:
    """Return [(line_no, label)] for every miscompiled ternary in `text`."""
    lines = text.splitlines()
    instrs = _instructions(lines)
    hits = []
    for pos, (idx, text_at) in enumerate(instrs):
        if not LABEL_RE.match(text_at) or pos + 1 >= len(instrs):
            continue
        if not CARRY_JUMP_RE.match(instrs[pos + 1][1]):
            continue
        if pos == 0:
            continue
        prev = instrs[pos - 1][1]
        # A label whose fall-in predecessor is a constant load into HL, tested
        # by carry: the signature in this file's header. If the predecessor is
        # a real flag producer (`call l_ge`, `cp n`, ...) the code is correct
        # and this is a legitimate label placement, not the defect.
        if CONST_LOAD_RE.match(prev):
            hits.append((idx + 1, text_at))
    return hits


def sprinter_c_sources(makefile: Path) -> list[str]:
    """The C files the Sprinter target actually compiles with sccz80."""
    text = makefile.read_text(encoding="utf-8")
    srcs: set[str] = set()
    for var in ("SPRINTER_RESIDENT_C_SRC", "SPRINTER_NET_FRAME_C_SRC"):
        m = re.search(re.escape(var) + r"\s*:?=\s*((?:.*\\\n)*.*)", text)
        if m:
            srcs.update(re.findall(r"\S+\.c", m.group(1)))
    # The overlay .c files are named in their own recipes, not in a list
    # variable -- take them from the recipe lines that compile them.
    for m in re.finditer(r"-c\s+(\S+\.c)", text):
        srcs.add(m.group(1))
    return sorted(s for s in srcs if Path(s).exists())


CFLAGS = [
    "+pps",
    "-clib=default",
    "-SO3",
    "-Isrc",
    "-Iasm/sprinter/zcc",
    "-Ibuild/sprinter/generated",
    "-DNETCHESSZX_SPRINTER",
    "-DNETCHESSZX_FIXED_LOW_RAM",
]


def self_test() -> None:
    bad = "\n".join(
        [
            "._f",
            "\tld\ta,(_x)",
            "\tand\ta",
            "\tjp\tnz,i_7\t;",
            "\tld\thl,1\t;const",
            "\tjr\ti_8",
            ".i_7",
            "\tld\thl,0\t;const",
            ".i_8",
            "\tjp\tnc,i_9\t;",
            "\tld\thl,1\t;const",
            ".i_9",
            "\tret",
        ]
    )
    hits = scan_asm(bad)
    if len(hits) != 1 or hits[0][1] != ".i_8":
        raise SystemExit(f"[ERR] sccz80-codegen self-test: miscompile not detected ({hits})")

    # A carry test reached from a real flag producer is correct code and must
    # not be flagged, even with a label immediately before it.
    good = "\n".join(
        [
            "._f",
            "\tcall\tl_ge",
            ".i_3",
            "\tjp\tnc,i_4\t;",
            "\tld\thl,1\t;const",
            ".i_4",
            "\tret",
        ]
    )
    if scan_asm(good):
        raise SystemExit("[ERR] sccz80-codegen self-test: false positive on correct code")

    # A ternary on a plain comparison compiles correctly and stays quiet.
    plain = "\n".join(["._f", "\tld\thl,0\t;const", ".i_1", "\tld\ta,l", "\tret"])
    if scan_asm(plain):
        raise SystemExit("[ERR] sccz80-codegen self-test: false positive on plain code")

    print("[OK] sccz80-codegen self-test")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zcc", default=os.environ.get("ZCC", "zcc"))
    parser.add_argument("--makefile", type=Path, default=Path("Makefile"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if shutil.which(args.zcc) is None:
        print(f"[ERR] {args.zcc} not found", file=sys.stderr)
        return 1

    sources = sprinter_c_sources(args.makefile)
    if not sources:
        print("[ERR] no Sprinter C sources found in the Makefile", file=sys.stderr)
        return 1

    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for src in sources:
            out = Path(tmp) / (src.replace("/", "_") + ".asm")
            proc = subprocess.run(
                [args.zcc, *CFLAGS, "-S", src, "-o", str(out)],
                capture_output=True,
                text=True,
            )
            if proc.returncode != 0 or not out.exists():
                print(f"[ERR] {src}: zcc -S failed\n{proc.stderr}", file=sys.stderr)
                failures += 1
                continue
            # Class 1: any sccz80 diagnostic is fatal here. -Wlimited-range is
            # the one that catches the cast-literal constant-index miscompile;
            # the rest are held to the same bar rather than triaged, because a
            # warning nobody fails on is a warning nobody reads.
            for line in (proc.stderr + proc.stdout).splitlines():
                if "warning" in line.lower():
                    print(f"[ERR] {line.strip()}", file=sys.stderr)
                    failures += 1
            for line_no, label in scan_asm(out.read_text(encoding="utf-8", errors="replace")):
                print(
                    f"[ERR] {src}: sccz80 &&/||-in-a-ternary miscompile "
                    f"(emitted {label} at asm line {line_no}) -- rewrite the "
                    f"conditional expression as an if; see this tool's header",
                    file=sys.stderr,
                )
                failures += 1

    if failures:
        print(f"[ERR] sccz80-codegen check: {failures} problem(s)", file=sys.stderr)
        return 1
    print(f"[OK] sccz80-codegen check: {len(sources)} Sprinter C sources clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
