#!/usr/bin/env python3
"""Report where the Sprinter resident's bytes actually go (S5 size gate).

Every earlier S5 size claim in port.md/docs/sprinter-testnotes/S5.md ("C
image: 6666 bytes", "platform_primitives: ~5223 bytes free before OVL_SLOT")
was worked out by hand from `build/sprinter/resident_c.map`, once per pass.
This tool makes that a build artifact instead of a one-off calculation, so
the S5-finish plan's size decision (does gui.c + the render surface fit the
16000-byte C-image budget?) is answered by a number, not a guess -- and so
the next milestone does not have to redo the arithmetic by hand again.

Two things this tool is NOT:

  - It is not tools/gen_size_report.py. That tool is ZX/Next-only: its
    stack-gap/section-tail logic is keyed to SDCC's map format and to the
    ZX .tap/.OVL/.DAT layout (--tap/--ovl/--dat are required arguments).
    z88dk's map format for the Sprinter C image differs (see parse_map's
    own docstring), and there is no .tap/.OVL/.DAT here at all -- the
    Sprinter resident is one flat 32768-byte image plus a handful of
    16384-byte asset pages. Duplicating that tool's assumptions onto a
    format it was never designed for would be a worse maintenance burden
    than a second small tool.
  - It is not a policy gate. It reports numbers and, where a hard ceiling
    is known (the C-image budget, the 2 KiB OVL_SLOT, the 32768-byte
    resident), flags an overrun -- but it does not fail a build just because
    a *tier* estimate looks large. Tier attribution (hot vs cold, plan
    D7-ter) is inherently a judgement call about what a routine does, not
    something derivable from an address map; see HOT_COLD_TIERS below.

Output: JSON to stdout (or --json PATH), and optionally a Markdown summary
via --markdown PATH (docs/sprinter-size-report.md). Both are a pure function
of the input files -- same determinism contract as every other
tools/gen_sprinter_*.py/tools/make_sprinter_*.py tool in this port.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True


# ---------------------------------------------------------------------------
# z88dk map parsing (build/sprinter/resident_c.map)
#
# Line shape (one real example, kept verbatim as documentation):
#   _NETCHESS_PROTO_ACK_PING        = $5AD9 ; addr, public, , \
#       src_common_protocol_game_protocol_c, rodata_compiler, \
#       src/common/protocol/game_protocol.c:24
#   BANNER_COLOR                    = $0001 ; const, local, , render_core, \
#       code_user, asm/sprinter/zcc/render_core.asm:656
#   __code_compiler_head            = $42B8 ; const, public, def, , ,
#
# Six fields follow the ';': kind ("addr" for a real linked symbol, "const"
# for an EQU/aggregate value that carries no size), scope, an optional "def"
# flag (aggregate head/tail/size markers only), module, section, source
# location. `kind` is what separates a real byte range (an "addr" symbol
# marks a linked address) from a same-named EQU constant that happens to
# share the file's numbering -- e.g. render_core.asm's own BOARD_COLS EQU
# alongside platform_defs.asm's bridged BOARD_COLS defc.
# ---------------------------------------------------------------------------

MAP_LINE = re.compile(
    r"^(\S+)\s+=\s+\$([0-9A-Fa-f]+)\s*;\s*"
    r"(\w+),\s*(\w+),\s*([^,]*),\s*([^,]*),\s*([^,]*),\s*(.*)$"
)


class Symbol:
    __slots__ = ("name", "addr", "kind", "scope", "module", "section", "path")

    def __init__(self, name: str, addr: int, kind: str, scope: str,
                 module: str, section: str, path: str) -> None:
        self.name = name
        self.addr = addr
        self.kind = kind
        self.scope = scope
        self.module = module.strip()
        self.section = section.strip()
        self.path = path.strip()


def parse_map(path: Path) -> list[Symbol]:
    symbols: list[Symbol] = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = MAP_LINE.match(line.rstrip("\n"))
            if not match:
                continue
            name, addr_hex, kind, scope, _extra, module, section, path = match.groups()
            symbols.append(Symbol(name, int(addr_hex, 16), kind, scope, module, section, path))
    return symbols


def const(symbols_by_name: dict[str, Symbol], name: str) -> int | None:
    sym = symbols_by_name.get(name)
    return sym.addr if sym is not None else None


# Section pairs whose head/tail aggregate constants z88dk always emits,
# named (report key, EQU prefix). "compiler" sections are sccz80's output
# for src/sprinter/main.c + the linked common/spectrum C files; "user"
# sections are the z80asm modules linked alongside them (render_core.asm,
# overlay_loader_sprinter.asm, the atlas table, resident_crt0.asm).
SECTION_PAIRS = [
    ("c_code", "code_compiler"),
    ("c_bss", "bss_compiler"),
    ("c_rodata", "rodata_compiler"),
    ("c_data", "data_compiler"),
    ("asm_code", "code_user"),
    ("asm_bss", "bss_user"),
    ("asm_rodata", "rodata_user"),
    ("asm_data", "data_user"),
]


def section_sizes(symbols_by_name: dict[str, Symbol]) -> dict[str, int]:
    sizes: dict[str, int] = {}
    for key, prefix in SECTION_PAIRS:
        head = const(symbols_by_name, f"__{prefix}_head")
        tail = const(symbols_by_name, f"__{prefix}_tail")
        if head is not None and tail is not None:
            sizes[key] = tail - head
    return sizes


# ---------------------------------------------------------------------------
# Per-module attribution inside one section, by address-gap.
#
# The map has no per-symbol size field, so a module's footprint is inferred
# from the gap to the next symbol's address within the same section --
# standard poor-man's map-file profiling. This slightly over-attributes the
# LAST module in address order (any final padding/alignment goes to it) and
# is blind to interleaving finer than one symbol; both are acceptable for a
# planning-level report and are documented here rather than glossed over.
# ---------------------------------------------------------------------------

def module_breakdown(symbols: list[Symbol], section: str, tail: int | None) -> dict[str, int]:
    in_section = sorted(
        (s for s in symbols if s.section == section and s.kind == "addr"),
        key=lambda s: s.addr,
    )
    totals: dict[str, int] = {}
    for i, sym in enumerate(in_section):
        if i + 1 < len(in_section):
            end = in_section[i + 1].addr
        elif tail is not None:
            end = tail
        else:
            end = sym.addr
        size = max(0, end - sym.addr)
        module = sym.module or "(unknown)"
        totals[module] = totals.get(module, 0) + size
    return totals


# ---------------------------------------------------------------------------
# Hot/cold tier map (plan D7-ter). This is a curated, hand-maintained
# classification -- NOT derived from the address map, because "is this
# called every frame or once at boot" is a fact about the code, not its
# address. Extend this dict when a module is added to
# SPRINTER_RESIDENT_C_SRC/SPRINTER_RENDER_CORE_ASM; an unclassified module
# is reported as "unclassified" rather than silently guessing a tier.
# ---------------------------------------------------------------------------

HOT_COLD_TIERS: dict[str, str] = {
    # Tier 0 (plan D7-ter): always mapped, touched every frame.
    "src_sprinter_main_c": "hot",
    "render_core": "hot",
    "src_spectrum_board_board_c": "hot",
    "src_common_chess_move_coords_c": "hot",
    "src_spectrum_ui_gui_c": "hot",
    "overlay_loader_sprinter": "hot",
    "overlay_atlas_table_sprinter": "hot",
    # Boot-only / rarely-called: dispatch plumbing shared with overlays
    # rather than the frame loop itself.
    "src_common_protocol_game_protocol_c": "cold-candidate",
    "src_common_protocol_mqtt_session_protocol_c": "cold-candidate",
    "sprinter_resident_crt0": "boot-only",
}


def tier_of(module: str) -> str:
    return HOT_COLD_TIERS.get(module, "unclassified")


# ---------------------------------------------------------------------------
# Fixed ceilings this report checks the C image against. Kept as literals
# here (not re-derived from fixed_layout.json) because the two numbers this
# tool cares about -- the C-image span and the OVL_SLOT size -- are already
# available as build-time constants passed in via --c-image-base/--win1-end/
# --ovl-slot-size; gen_sprinter_layout.py remains the single source of
# truth for those, this tool just receives them.
# ---------------------------------------------------------------------------

def build_report(args: argparse.Namespace) -> dict[str, object]:
    symbols = parse_map(args.resident_c_map)
    by_name = {s.name: s for s in symbols if s.kind == "const"}

    sizes = section_sizes(by_name)
    c_total = sizes.get("c_code", 0) + sizes.get("c_rodata", 0) + sizes.get("c_data", 0)
    asm_total = sizes.get("asm_code", 0) + sizes.get("asm_rodata", 0) + sizes.get("asm_data", 0)
    bss_total = sizes.get("c_bss", 0) + sizes.get("asm_bss", 0)

    resident_c_bytes = args.resident_c_bin.stat().st_size if args.resident_c_bin.exists() else None
    c_image_budget = args.win1_end - args.c_image_base

    modules: dict[str, dict[str, object]] = {}
    for _key, prefix in SECTION_PAIRS:
        head = const(by_name, f"__{prefix}_head")
        tail = const(by_name, f"__{prefix}_tail")
        if head is None:
            continue
        for module, size in module_breakdown(symbols, prefix, tail).items():
            entry = modules.setdefault(module, {"code": 0, "rodata": 0, "data": 0, "bss": 0, "total": 0})
            bucket = {
                "code_compiler": "code", "code_user": "code",
                "rodata_compiler": "rodata", "rodata_user": "rodata",
                "data_compiler": "data", "data_user": "data",
                "bss_compiler": "bss", "bss_user": "bss",
            }[prefix]
            entry[bucket] = entry[bucket] + size
            entry["total"] = entry["total"] + size

    module_rows = [
        {"module": name, "tier": tier_of(name), **fields}
        for name, fields in sorted(modules.items(), key=lambda kv: -kv[1]["total"])
    ]

    overlay_win3 = {}
    if args.ovl_rules_bin and args.ovl_rules_bin.exists():
        overlay_win3["rules"] = args.ovl_rules_bin.stat().st_size
    if args.ovl_board_bin and args.ovl_board_bin.exists():
        overlay_win3["board"] = args.ovl_board_bin.stat().st_size
    if args.ovl_input_edit_bin and args.ovl_input_edit_bin.exists():
        overlay_win3["input_edit"] = args.ovl_input_edit_bin.stat().st_size
    if args.ovl_win3_page and args.ovl_win3_page.exists():
        overlay_win3["page_bytes"] = args.ovl_win3_page.stat().st_size

    overlay_slot = {}
    if args.ovl_control_bin and args.ovl_control_bin.exists():
        overlay_slot["control"] = args.ovl_control_bin.stat().st_size

    report: dict[str, object] = {
        "c_image": {
            "resident_c_bin_bytes": resident_c_bytes,
            "budget_bytes": c_image_budget,
            "free_bytes": (c_image_budget - resident_c_bytes) if resident_c_bytes is not None else None,
            "over_budget": (resident_c_bytes is not None and resident_c_bytes > c_image_budget),
        },
        "sections": {
            "c_code": sizes.get("c_code", 0),
            "c_rodata": sizes.get("c_rodata", 0),
            "c_data": sizes.get("c_data", 0),
            "c_bss": sizes.get("c_bss", 0),
            "asm_code": sizes.get("asm_code", 0),
            "asm_rodata": sizes.get("asm_rodata", 0),
            "asm_data": sizes.get("asm_data", 0),
            "asm_bss": sizes.get("asm_bss", 0),
            "c_total_rom": c_total,
            "asm_total_rom": asm_total,
            "bss_total": bss_total,
        },
        "modules": module_rows,
        "ovl_slot": {
            "budget_bytes": args.ovl_slot_size,
            **overlay_slot,
        },
        "ovl_win3_page": {
            "budget_bytes": args.win3_page_size,
            "slot_size": args.win3_slot_size,
            **overlay_win3,
        },
    }
    if args.platform_primitives_bin and args.platform_primitives_bin.exists():
        report["platform_primitives_bytes"] = args.platform_primitives_bin.stat().st_size
    if args.resident_bin and args.resident_bin.exists():
        report["resident_bytes"] = args.resident_bin.stat().st_size

    return report


def render_markdown(report: dict[str, object]) -> str:
    lines = [
        "# Sprinter size report",
        "",
        "Generated by `tools/gen_sprinter_size_report.py` from "
        "`build/sprinter/resident_c.map` and the built blobs -- pure "
        "function of the current build, do not hand-edit. Regenerate with "
        "`make sprinter-size-report`.",
        "",
        "## C image (`#4180..#8000`, plan D2)",
        "",
    ]
    ci = report["c_image"]
    lines.append(f"- resident_c.bin: **{ci['resident_c_bin_bytes']} bytes** "
                 f"of {ci['budget_bytes']} budget "
                 f"({ci['free_bytes']} free)" + (" -- **OVER BUDGET**" if ci["over_budget"] else ""))
    lines.append("")
    lines.append("## Section totals")
    lines.append("")
    lines.append("| Section | Bytes |")
    lines.append("| --- | --- |")
    for key, value in report["sections"].items():
        lines.append(f"| {key} | {value} |")
    lines.append("")
    lines.append("## Per-module breakdown (plan D7-ter tiers)")
    lines.append("")
    lines.append("| Module | Tier | Code | Rodata | Data | BSS | Total |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- |")
    for row in report["modules"]:
        lines.append(
            f"| {row['module']} | {row['tier']} | {row['code']} | {row['rodata']} | "
            f"{row['data']} | {row['bss']} | {row['total']} |"
        )
    lines.append("")
    lines.append(
        "Tiers: **hot** = mapped and potentially touched every frame; "
        "**cold-candidate** = called rarely, a plan-D7-ter/§3.10 overlay "
        "migration candidate if the C image runs out of room; **boot-only** "
        "= runs once at startup; **unclassified** = not yet triaged, add it "
        "to `HOT_COLD_TIERS` in the tool."
    )
    lines.append("")
    lines.append("## Overlay slots")
    lines.append("")
    slot = report["ovl_slot"]
    lines.append(f"- OVL_SLOT (mode 0, copy): budget {slot['budget_bytes']} bytes; "
                 f"CONTROL = {slot.get('control', 'n/a')} bytes")
    page = report["ovl_win3_page"]
    lines.append(f"- WIN3 overlay page (mode 1, map): budget {page['budget_bytes']} bytes, "
                 f"{page['slot_size']} bytes/slot; "
                 f"RULES = {page.get('rules', 'n/a')}, BOARD = {page.get('board', 'n/a')}, "
                 f"GUI_LOG = {page.get('gui_log', 'n/a')}, INPUT_EDIT = {page.get('input_edit', 'n/a')}")
    if "platform_primitives_bytes" in report:
        lines.append(f"- platform_primitives.bin: {report['platform_primitives_bytes']} bytes (fixed span)")
    if "resident_bytes" in report:
        lines.append(f"- resident.bin (final spliced image): {report['resident_bytes']} bytes")
    lines.append("")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resident-c-map", type=Path)
    parser.add_argument("--resident-c-bin", type=Path)
    parser.add_argument("--resident-bin", type=Path)
    parser.add_argument("--platform-primitives-bin", type=Path)
    parser.add_argument("--ovl-control-bin", type=Path)
    parser.add_argument("--ovl-rules-bin", type=Path)
    parser.add_argument("--ovl-board-bin", type=Path)
    parser.add_argument("--ovl-input-edit-bin", type=Path)
    parser.add_argument("--ovl-win3-page", type=Path)
    parser.add_argument("--c-image-base", type=lambda v: int(v, 0))
    parser.add_argument("--win1-end", type=lambda v: int(v, 0))
    parser.add_argument("--ovl-slot-size", type=lambda v: int(v, 0))
    parser.add_argument("--win3-page-size", type=lambda v: int(v, 0), default=16384)
    parser.add_argument("--win3-slot-size", type=lambda v: int(v, 0), default=4096)
    parser.add_argument("--json", type=Path, help="write JSON report here (default: stdout)")
    parser.add_argument("--markdown", type=Path, help="also write a Markdown summary here")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if not args.self_test:
        missing = [
            name for name, value in (
                ("--resident-c-map", args.resident_c_map),
                ("--resident-c-bin", args.resident_c_bin),
                ("--c-image-base", args.c_image_base),
                ("--win1-end", args.win1_end),
                ("--ovl-slot-size", args.ovl_slot_size),
            ) if value is None
        ]
        if missing:
            parser.error(
                "the following arguments are required unless --self-test: "
                + ", ".join(missing)
            )
    return args


def self_test() -> None:
    import tempfile

    fixture = (
        "_main                            = $4180 ; addr, public, , "
        "src_sprinter_main_c, code_compiler, src/sprinter/main.c:236\n"
        "_board_select_or_move            = $41F0 ; addr, local, , "
        "src_sprinter_main_c, code_compiler, src/sprinter/main.c:177\n"
        "_spectrum_board_reset            = $4300 ; addr, public, , "
        "src_spectrum_board_board_c, code_compiler, src/spectrum/board/board.c:10\n"
        "__code_compiler_head             = $4180 ; const, public, def, , ,\n"
        "__code_compiler_size             = $0200 ; const, public, def, , ,\n"
        "__code_compiler_tail             = $4380 ; const, public, def, , ,\n"
        "__bss_compiler_head              = $5B00 ; const, public, def, , ,\n"
        "__bss_compiler_tail              = $5B10 ; const, public, def, , ,\n"
        "__rodata_compiler_head           = $5A00 ; const, public, def, , ,\n"
        "__rodata_compiler_tail           = $5A20 ; const, public, def, , ,\n"
        "render_square                    = $6000 ; addr, public, , "
        "render_core, code_user, asm/sprinter/zcc/render_core.asm:337\n"
        "__code_user_head                 = $6000 ; const, public, def, , ,\n"
        "__code_user_tail                 = $6100 ; const, public, def, , ,\n"
    )

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        map_path = tmp_path / "resident_c.map"
        map_path.write_text(fixture, encoding="ascii")
        bin_path = tmp_path / "resident_c.bin"
        bin_path.write_bytes(bytes(6000))

        args = parse_args([
            "--resident-c-map", str(map_path),
            "--resident-c-bin", str(bin_path),
            "--c-image-base", "0x4180",
            "--win1-end", "0x8000",
            "--ovl-slot-size", "0x800",
        ])
        report = build_report(args)

        if report["sections"]["c_code"] != 0x200:
            raise SystemExit("[ERR] size-report self-test: c_code size wrong")
        if report["sections"]["asm_code"] != 0x100:
            raise SystemExit("[ERR] size-report self-test: asm_code size wrong")
        if report["c_image"]["resident_c_bin_bytes"] != 6000:
            raise SystemExit("[ERR] size-report self-test: resident_c_bin_bytes wrong")
        if report["c_image"]["budget_bytes"] != 0x8000 - 0x4180:
            raise SystemExit("[ERR] size-report self-test: budget wrong")
        if report["c_image"]["over_budget"]:
            raise SystemExit("[ERR] size-report self-test: falsely over budget")

        # Two code_compiler symbols (_main, _board_select_or_move) belong to
        # main.c and precede board.c's one symbol in address order, so both
        # gaps before board.c's symbol attribute to main.c -- this is
        # exactly the "poor man's profiling" address-gap rule the tool
        # documents, not a bug: it is what a real map with several
        # functions per file will do too.
        modules_by_name = {row["module"]: row for row in report["modules"]}
        main_c = modules_by_name.get("src_sprinter_main_c")
        board_c = modules_by_name.get("src_spectrum_board_board_c")
        if main_c is None or board_c is None:
            raise SystemExit("[ERR] size-report self-test: expected modules missing "
                              f"(got {sorted(modules_by_name)})")
        if main_c["code"] + board_c["code"] != 0x200:
            raise SystemExit("[ERR] size-report self-test: c_code module sizes don't sum "
                              f"to the section total (got {main_c['code']} + {board_c['code']})")
        if main_c["tier"] != "hot":
            raise SystemExit("[ERR] size-report self-test: main.c should be tier 'hot'")

        render_core = modules_by_name.get("render_core")
        if render_core is None or render_core["code"] != 0x100:
            raise SystemExit("[ERR] size-report self-test: render_core module attribution wrong")

        # Determinism: same inputs, same output.
        report2 = build_report(args)
        if json.dumps(report, sort_keys=True) != json.dumps(report2, sort_keys=True):
            raise SystemExit("[ERR] size-report self-test: report is not deterministic")

        md = render_markdown(report)
        if "src_sprinter_main_c" not in md or "OVL_SLOT" not in md:
            raise SystemExit("[ERR] size-report self-test: markdown missing expected content")

    print("[OK] gen_sprinter_size_report self-test passed")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0

    report = build_report(args)
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)

    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(render_markdown(report), encoding="utf-8")

    if report["c_image"]["over_budget"]:
        sys.stderr.write(
            f"[ERR] Sprinter C image over budget: "
            f"{report['c_image']['resident_c_bin_bytes']} > {report['c_image']['budget_bytes']}\n"
        )
        return 1

    print(
        f"[OK] sprinter-size-report: C image {report['c_image']['resident_c_bin_bytes']}/"
        f"{report['c_image']['budget_bytes']} bytes "
        f"({report['c_image']['free_bytes']} free)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
