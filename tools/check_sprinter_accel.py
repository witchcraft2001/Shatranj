#!/usr/bin/env python3
"""Enforce R3: every accelerator block runs under DI and ends with ACC_OFF.

port.md rule R3: each accelerator sequence is DI -> (PORT_Y, arm, trigger)
-> ACC_OFF (LD B,B) -> PORT_Y=#C0 -> EI, with nothing extra between the arm
and the trigger. This gate scans every asm/sprinter/*.asm and *.inc source,
tracking DI/EI state per file, and flags:

  1. An ACC_SET_SIZE/ACC_FILL_*/ACC_COPY_* invocation outside a DI..EI span.
  2. An armed sequence (ACC_SET_SIZE or a FILL/COPY trigger) not followed
     by ACC_OFF before the next DI, EI, or end of file.
  3. A DI..EI span that used the accelerator but never parks PORT_Y=#C0
     (acc_park_y, or the equivalent literal OUT) AFTER the last arm closed
     and before the EI (a park before the arm does not count).
  4. An ACC_COPY_H immediately followed by the classic latching read
     `LD A,(HL)` (gfx_core.asm's draw_tile copy pattern) whose very next
     statement is not the paired write (`LD (DE),A`/`LD (BC),A`/
     `LD (HL),A`) or ACC_OFF -- the source byte is latched by that read
     (gfx640.asm:1269-1273), so nothing may sit between it and the write.
     This only fires when ACC_COPY_H is followed by exactly that read
     shape: ACC_COPY_H used for the AND/XOR masking trick in text640.asm's
     row renderers (a different, donor-proven pattern with no such pair)
     is not this shape and is left alone.

The macro invocations are the enforced surface: asm code must use the
ACC_* macros from accel.inc, not raw `ld d,d`-style opcodes, or this gate
cannot see the sequence at all (and video_s1.asm's accel_smoke is written
accordingly).

win0_map_di/win0_restore (win0.inc) also open/close a DI span -- they DI
and EI internally -- so a call site that maps a tile/font source page via
win0_map_di and then uses the accelerator against it (gfx_core.asm's
draw_tile) is recognised as being inside DI too, without needing a second,
redundant literal `di`. This recognition is skipped inside win0.inc itself:
its own macro bodies already contain the literal di/ei this gate tracks
natively, and the macro *declaration* line ("MACRO win0_map_di") would
otherwise be misread as a call site.

Lines are pre-split into colon-separated statements (quote-aware, with ;
and // comments removed), so label-prefixed instructions ("start: di") and
multi-statement lines ("ei : ACC_FILL_H") are scanned per statement, not
skipped by line-anchored patterns.

Follows the tools/check_spectrum_direct_policy.py pattern: a pure,
accumulating-error scan plus a mandatory --self-test with a clean fixture
and several deliberately-violating ones, each checked for its specific
diagnostic.
"""

from __future__ import annotations

import argparse
import re
from pathlib import PurePosixPath, Path

SOURCE_DIR = "asm/sprinter"
MACRO_DEFINITION_FILE = "accel.inc"
WIN0_MACRO_FILE = "win0.inc"

DI_PATTERN = re.compile(r"^\s*DI\b", re.IGNORECASE)
EI_PATTERN = re.compile(r"^\s*EI\b", re.IGNORECASE)
WIN0_MAP_PATTERN = re.compile(r"\bwin0_map_di\b", re.IGNORECASE)
WIN0_RESTORE_PATTERN = re.compile(r"\bwin0_restore\b", re.IGNORECASE)
ARM_PATTERN = re.compile(
    r"\bACC_(SET_SIZE|FILL_H|FILL_V|COPY_H|COPY_V)\b", re.IGNORECASE
)
OFF_PATTERN = re.compile(r"\bACC_OFF\b", re.IGNORECASE)
PARK_PATTERN = re.compile(
    r"\bacc_park_y\b|OUT\s*\(\s*PORT_Y\s*\)\s*,\s*A", re.IGNORECASE
)
COPY_H_PATTERN = re.compile(r"\bACC_COPY_H\b", re.IGNORECASE)
LATCH_READ_PATTERN = re.compile(r"^\s*LD\s+A\s*,\s*\(\s*HL\s*\)\s*$", re.IGNORECASE)
PAIRED_WRITE_PATTERN = re.compile(
    r"^\s*LD\s+\(\s*(DE|BC|HL)\s*\)\s*,\s*A\s*$", re.IGNORECASE
)
MACRO_DEF_PATTERN = re.compile(r"^\s*MACRO\s+ACC_\w+\b", re.IGNORECASE)
ENDM_PATTERN = re.compile(r"^\s*ENDM\b", re.IGNORECASE)


def split_statements(line: str) -> list[str]:
    """Strip ;/// comments and split on ':' separators, quote-aware.

    Labels come out as their own fragment (matching no instruction
    pattern), so 'start: di' yields a scannable ' di' statement.
    """
    statements: list[str] = []
    current: list[str] = []
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            current.append(ch)
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            current.append(ch)
            i += 1
            continue
        if ch == ";" or line.startswith("//", i):
            break
        if ch == ":":
            statements.append("".join(current))
            current = []
            i += 1
            continue
        current.append(ch)
        i += 1
    statements.append("".join(current))
    return statements


def check_file(path_label: str, text: str) -> list[str]:
    errors: list[str] = []
    lines = text.splitlines()

    in_macro_def_file = PurePosixPath(path_label).name == MACRO_DEFINITION_FILE
    is_win0_macro_file = PurePosixPath(path_label).name == WIN0_MACRO_FILE
    inside_macro_body = False

    di_line = None          # line of the currently-open DI, or None
    armed_line = None       # line of the last arm/trigger awaiting ACC_OFF
    used_accel = False      # this DI..EI span invoked any ACC_* macro
    parked = False          # acc_park_y seen since the last arm closed
    copy_h_state = None     # None | "armed" | "read_done": tracks the
                             # ACC_COPY_H -> LD A,(HL) -> {write|ACC_OFF}
                             # shape one statement at a time (rule 4)

    def close_di(end_lineno: int) -> None:
        nonlocal di_line, armed_line, used_accel, parked
        if armed_line is not None:
            errors.append(
                f"{path_label}:{armed_line}: accelerator sequence armed "
                "but never closed with ACC_OFF before EI (R3)"
            )
        if used_accel and not parked:
            errors.append(
                f"{path_label}:{di_line}: DI section used the accelerator "
                "but never parked PORT_Y=#C0 before EI (R3/R10)"
            )
        di_line = None
        armed_line = None
        used_accel = False
        parked = False

    for lineno, line in enumerate(lines, 1):
        for stmt in split_statements(line):
            if in_macro_def_file:
                if MACRO_DEF_PATTERN.search(stmt):
                    inside_macro_body = True
                elif ENDM_PATTERN.search(stmt):
                    inside_macro_body = False
                if inside_macro_body:
                    continue

            # Rule 4: resolve any pending ACC_COPY_H/LD A,(HL) pair using
            # THIS statement, before anything else below acts on it (and
            # regardless of whether this statement also matches one of the
            # patterns below -- e.g. a fresh ACC_COPY_H right after another
            # one's unresolved read).
            if copy_h_state == "armed":
                copy_h_state = "read_done" if LATCH_READ_PATTERN.search(stmt) else None
            elif copy_h_state == "read_done":
                if not (PAIRED_WRITE_PATTERN.search(stmt) or OFF_PATTERN.search(stmt)):
                    errors.append(
                        f"{path_label}:{lineno}: something other than the "
                        "paired write or ACC_OFF follows ACC_COPY_H's "
                        "latching read LD A,(HL) (R3)"
                    )
                copy_h_state = None
            if COPY_H_PATTERN.search(stmt):
                copy_h_state = "armed"

            if DI_PATTERN.search(stmt) or (
                not is_win0_macro_file and WIN0_MAP_PATTERN.search(stmt)
            ):
                if di_line is not None:
                    close_di(lineno)  # tolerate nested DI defensively
                di_line = lineno
                armed_line = None
                used_accel = False
                parked = False
                copy_h_state = None
                continue

            if EI_PATTERN.search(stmt) or (
                not is_win0_macro_file and WIN0_RESTORE_PATTERN.search(stmt)
            ):
                if di_line is not None:
                    close_di(lineno)
                copy_h_state = None
                continue

            if ARM_PATTERN.search(stmt):
                if di_line is None:
                    errors.append(
                        f"{path_label}:{lineno}: accelerator opcode used "
                        "outside a DI section (R3)"
                    )
                else:
                    used_accel = True
                    armed_line = lineno
                    parked = False  # a park BEFORE the arm does not count
                continue

            if OFF_PATTERN.search(stmt):
                armed_line = None
                continue

            if PARK_PATTERN.search(stmt) and di_line is not None:
                parked = True

    if di_line is not None:
        close_di(len(lines) + 1)

    return errors


def check_tree(root: Path) -> list[str]:
    source_dir = root / SOURCE_DIR
    if not source_dir.is_dir():
        return [f"{SOURCE_DIR}: missing Sprinter asm source directory"]

    errors: list[str] = []
    for path in sorted(source_dir.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in (".asm", ".inc"):
            continue
        label = path.relative_to(root).as_posix()
        errors.extend(check_file(label, path.read_text(encoding="utf-8")))
    return errors


def _expect_reject(fixture: str, needle: str, description: str) -> None:
    errors = check_file(f"{SOURCE_DIR}/video_s1.asm", fixture)
    if not any(needle in error for error in errors):
        raise SystemExit(
            f"[ERR] accel policy self-test: {description} "
            f"(expected an error containing {needle!r}, got {errors})"
        )


def self_test() -> None:
    clean = (
        "accel_smoke:\n"
        "        di\n"
        "        ld a,8\n"
        "        ACC_SET_SIZE\n"
        "        ld a,0\n"
        "        ACC_FILL_H\n"
        "        ld a,#37\n"
        "        ld (hl),a\n"
        "        ACC_OFF\n"
        "        acc_park_y\n"
        "        ei\n"
        "        ret\n"
    )
    label = f"{SOURCE_DIR}/video_s1.asm"
    if check_file(label, clean):
        raise SystemExit("[ERR] accel policy self-test rejected clean source")

    # A label-prefixed DI must still open the span (no false positive).
    labelled_di = clean.replace("        di\n", "start:  di\n")
    if check_file(label, labelled_di):
        raise SystemExit(
            "[ERR] accel policy self-test rejected a label-prefixed DI span"
        )

    outside_di = clean.replace("        di\n", "")
    _expect_reject(
        outside_di, "outside a DI",
        "accepted accelerator use outside DI",
    )

    multi_stmt = clean.replace("        ACC_FILL_H\n", "        ei : ACC_FILL_H\n")
    _expect_reject(
        multi_stmt, "outside a DI",
        "accepted an arm hidden behind a colon-separated EI",
    )

    no_off = clean.replace("        ACC_OFF\n", "")
    _expect_reject(
        no_off, "never closed",
        "accepted a sequence missing ACC_OFF",
    )

    no_park = clean.replace("        acc_park_y\n", "")
    _expect_reject(
        no_park, "never parked",
        "accepted a DI section that never parked PORT_Y",
    )

    park_before_arm = clean.replace("        acc_park_y\n", "").replace(
        "        ld a,8\n", "        acc_park_y\n        ld a,8\n"
    )
    _expect_reject(
        park_before_arm, "never parked",
        "accepted a park that happened before the arm, not after",
    )

    # win0_map_di/win0_restore open/close DI too (they DI/EI internally):
    # accelerator use against a WIN0-mapped tile/font source must be
    # recognised without a second, redundant literal di.
    win0_wrapped = clean.replace("        di\n", "        win0_map_di\n").replace(
        "        ei\n", "        win0_restore\n"
    )
    if check_file(label, win0_wrapped):
        raise SystemExit(
            "[ERR] accel policy self-test rejected accelerator use inside "
            "win0_map_di/win0_restore"
        )

    win0_outside = win0_wrapped.replace("        win0_map_di\n", "")
    _expect_reject(
        win0_outside, "outside a DI",
        "accepted accelerator use outside a win0_map_di/win0_restore span",
    )

    # win0.inc's own macro bodies (literal di/ei, no accelerator use) must
    # stay exempt from the win0_map_di/win0_restore name-based recognition,
    # which would otherwise misread the "MACRO win0_map_di" declaration
    # line itself as a call site.
    win0_inc_body = (
        "        MACRO win0_map_di\n"
        "        di\n"
        "        push af\n"
        "        in a,(WIN0_PORT)\n"
        "        ld (win0_saved_page),a\n"
        "        pop af\n"
        "        out (WIN0_PORT),a\n"
        "        ENDM\n"
        "\n"
        "        MACRO win0_restore\n"
        "        ld a,(win0_saved_page)\n"
        "        out (WIN0_PORT),a\n"
        "        ei\n"
        "        ENDM\n"
    )
    if check_file(f"{SOURCE_DIR}/win0.inc", win0_inc_body):
        raise SystemExit(
            "[ERR] accel policy self-test rejected win0.inc's own macro bodies"
        )

    # Rule 4: ACC_COPY_H's classic "LD A,(HL)" latching read must be
    # immediately followed by the paired write (or ACC_OFF, a read-only
    # latch) -- nothing may sit between the read and the write.
    copy_pair = (
        "draw_tile:\n"
        "        di\n"
        "        ACC_SET_SIZE\n"
        "        ld a,16\n"
        "        ACC_COPY_H\n"
        "        ld a,(hl)\n"
        "        ld (de),a\n"
        "        ACC_OFF\n"
        "        acc_park_y\n"
        "        ei\n"
        "        ret\n"
    )
    if check_file(label, copy_pair):
        raise SystemExit("[ERR] accel policy self-test rejected a clean copy pair")

    copy_pair_broken = copy_pair.replace(
        "        ld a,(hl)\n        ld (de),a\n",
        "        ld a,(hl)\n        inc hl\n        ld (de),a\n",
    )
    _expect_reject(
        copy_pair_broken, "latching read",
        "accepted an instruction inserted between ACC_COPY_H's read and write",
    )

    # A read-only latch (ACC_COPY_H / LD A,(HL) / ACC_OFF, no write at all)
    # is a legitimate donor pattern (afnt640.asm's rows_general/black) and
    # must not be flagged.
    copy_read_only = copy_pair.replace(
        "        ld a,(hl)\n        ld (de),a\n", "        ld a,(hl)\n"
    )
    if check_file(label, copy_read_only):
        raise SystemExit(
            "[ERR] accel policy self-test rejected a read-only ACC_COPY_H latch"
        )

    # ACC_COPY_H used for the AND/XOR masking trick (text640.asm's row
    # renderers) never matches the "LD A,(HL)" read shape at all and must
    # not be flagged, even though nothing follows it but ACC_OFF is absent
    # from the very next statement.
    copy_mask = (
        "rows_general:\n"
        "        di\n"
        "        ACC_COPY_H\n"
        "        and (hl)\n"
        "        ACC_OFF\n"
        "        acc_park_y\n"
        "        ei\n"
        "        ret\n"
    )
    if check_file(label, copy_mask):
        raise SystemExit(
            "[ERR] accel policy self-test rejected ACC_COPY_H's AND-masking use"
        )

    print("[OK] Sprinter accelerator policy self-test")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return

    errors = check_tree(Path(args.root))
    if errors:
        print("[ERR] Sprinter accelerator policy (R3): violation(s) found")
        for error in errors:
            print(f"  {error}")
        raise SystemExit(1)

    print("[OK] Sprinter accelerator policy: DI-armed, ACC_OFF-closed, PORT_Y parked")


if __name__ == "__main__":
    main()
