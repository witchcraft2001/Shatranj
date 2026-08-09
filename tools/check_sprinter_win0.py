#!/usr/bin/env python3
"""Enforce R1: WIN0 is only ever replaced through win0_map_di/win0_restore.

port.md rule R1: the DSS system page lives in WIN0; it may only be
temporarily replaced, under DI for the whole duration of the replacement,
restored before EI, with no DSS/BIOS/Mouse call (RST) in between. This gate
scans every asm/sprinter/*.asm and *.inc source for:

  1. Any literal WIN0_PORT/#82 OUT (any sjasmplus numeric spelling: #82,
     $82, 0x82, 82h, 130) outside win0.inc's own macro bodies
     (win0_map_di/win0_restore are the only place allowed to write it).
  2. win0_map_di/win0_restore invocations balanced within each file (every
     open has a matching close, no close without an open).
  3. No RST or bare EI statement between a win0_map_di and its matching
     win0_restore (win0_restore itself performs the EI; a second one
     in between would mean WIN0 stayed swapped while interrupts ran).

Lines are pre-split into colon-separated statements (quote-aware, with ;
and // comments removed), so label-prefixed instructions ("err: rst #10")
and multi-statement lines ("ei : rst #10") are scanned per statement, not
skipped by line-anchored patterns.

Follows the tools/check_spectrum_direct_policy.py pattern: a pure,
accumulating-error scan plus a mandatory --self-test with both a clean and
several deliberately-violating fixtures, each checked for its specific
diagnostic.
"""

from __future__ import annotations

import argparse
import re
from pathlib import PurePosixPath, Path

SOURCE_DIR = "asm/sprinter"
MACRO_DEFINITION_FILE = "win0.inc"
OUT_PATTERN = re.compile(
    r"\bOUT\s*\(\s*(WIN0_PORT|#0*82|\$0*82|0[xX]0*82|0*82[hH]|130)\s*\)",
    re.IGNORECASE,
)
MAP_DI_PATTERN = re.compile(r"\bwin0_map_di\b", re.IGNORECASE)
RESTORE_PATTERN = re.compile(r"\bwin0_restore\b", re.IGNORECASE)
RST_PATTERN = re.compile(r"^\s*RST\b", re.IGNORECASE)
BARE_EI_PATTERN = re.compile(r"^\s*EI\b", re.IGNORECASE)
MACRO_DEF_PATTERN = re.compile(r"^\s*MACRO\s+win0_(map_di|restore)\b", re.IGNORECASE)
ENDM_PATTERN = re.compile(r"^\s*ENDM\b", re.IGNORECASE)


def split_statements(line: str) -> list[str]:
    """Strip ;/// comments and split on ':' separators, quote-aware.

    Labels come out as their own fragment (matching no instruction
    pattern), so 'err: rst #10' yields a scannable ' rst #10' statement.
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

    in_macro_def = PurePosixPath(path_label).name == MACRO_DEFINITION_FILE
    inside_macro_body = False
    open_line = None

    for lineno, line in enumerate(lines, 1):
        for stmt in split_statements(line):
            if in_macro_def:
                if MACRO_DEF_PATTERN.search(stmt):
                    inside_macro_body = True
                elif ENDM_PATTERN.search(stmt):
                    inside_macro_body = False

            if OUT_PATTERN.search(stmt) and not (in_macro_def and inside_macro_body):
                errors.append(
                    f"{path_label}:{lineno}: WIN0_PORT written outside "
                    "win0_map_di/win0_restore (R1)"
                )

            if in_macro_def and inside_macro_body:
                continue

            if MAP_DI_PATTERN.search(stmt):
                if open_line is not None:
                    errors.append(
                        f"{path_label}:{open_line}: win0_map_di never closed "
                        f"by win0_restore before another win0_map_di at line {lineno} (R1)"
                    )
                open_line = lineno
                continue

            if RESTORE_PATTERN.search(stmt):
                if open_line is None:
                    errors.append(
                        f"{path_label}:{lineno}: win0_restore with no preceding "
                        "win0_map_di (R1)"
                    )
                open_line = None
                continue

            if open_line is not None:
                if RST_PATTERN.search(stmt):
                    errors.append(
                        f"{path_label}:{lineno}: RST inside a win0_map_di.."
                        "win0_restore section (R1: no DSS/BIOS call while WIN0 "
                        "is swapped)"
                    )
                if BARE_EI_PATTERN.search(stmt):
                    errors.append(
                        f"{path_label}:{lineno}: EI inside a win0_map_di.."
                        "win0_restore section (R1: WIN0 must stay swapped only "
                        "under DI)"
                    )

    if open_line is not None:
        errors.append(
            f"{path_label}:{open_line}: win0_map_di never closed by "
            "win0_restore in this file (R1)"
        )

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
            f"[ERR] WIN0 policy self-test: {description} "
            f"(expected an error containing {needle!r}, got {errors})"
        )


def self_test() -> None:
    clean_macro_file = (
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
    clean_caller = (
        "probe:\n"
        "        ld a,5\n"
        "        win0_map_di\n"
        "        ld a,(hl)\n"
        "        win0_restore\n"
        "        ret\n"
    )
    if check_file(f"{SOURCE_DIR}/win0.inc", clean_macro_file) or \
       check_file(f"{SOURCE_DIR}/video_s1.asm", clean_caller):
        raise SystemExit("[ERR] WIN0 policy self-test rejected clean source")

    for spelling in ("WIN0_PORT", "#82", "$82", "0x82", "82h", "130"):
        direct_out = clean_caller.replace(
            "ld a,(hl)", f"ld a,(hl)\n        out ({spelling}),a"
        )
        _expect_reject(
            direct_out, "written outside",
            f"accepted a direct OUT ({spelling}) outside the macros",
        )

    unclosed = clean_caller.replace("        win0_restore\n", "")
    _expect_reject(unclosed, "never closed", "accepted an unclosed win0_map_di")

    orphan_restore = clean_caller.replace("        win0_map_di\n", "")
    _expect_reject(
        orphan_restore, "no preceding",
        "accepted a win0_restore with no win0_map_di",
    )

    rst_inside = clean_caller.replace(
        "ld a,(hl)", "ld a,(hl)\n        ld c,DSS_SCANKEY\n        rst RST_DSS"
    )
    _expect_reject(rst_inside, "RST inside", "accepted an RST inside the DI section")

    labelled_rst = clean_caller.replace(
        "ld a,(hl)", "ld a,(hl)\nerr:    rst RST_DSS"
    )
    _expect_reject(
        labelled_rst, "RST inside",
        "accepted a label-prefixed RST inside the DI section",
    )

    ei_inside = clean_caller.replace("ld a,(hl)", "ld a,(hl)\n        ei")
    _expect_reject(
        ei_inside, "EI inside", "accepted a bare EI inside the DI section"
    )

    print("[OK] Sprinter WIN0 policy self-test")


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
        print("[ERR] Sprinter WIN0 policy (R1): violation(s) found")
        for error in errors:
            print(f"  {error}")
        raise SystemExit(1)

    print("[OK] Sprinter WIN0 policy: WIN0_PORT only in win0_map_di/win0_restore")


if __name__ == "__main__":
    main()
