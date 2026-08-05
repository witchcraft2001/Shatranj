#!/usr/bin/env python3
"""Publish only permanent-WIN2 base data needed by the resident renderer."""

from __future__ import annotations

import argparse
from pathlib import Path

from gen_sprinter_thunks import map_symbols


SYMBOLS = (
    "_netchesszx_board_theme_index",
    "_netchesszx_piece_set_index",
    "_netchesszx_movement_hints",
    "_netchesszx_hinted_rows",
    "_netchesszx_board_light_attr",
    "_netchesszx_board_dark_attr",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--map", dest="map_file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    found = map_symbols(args.map_file.read_text(encoding="utf-8", errors="replace"))
    lines = ["; Generated base DATA imports; do not edit."]
    entry = found.get("_main")
    if entry is None or not 0x4000 <= entry < 0x8000:
        rendered = "missing" if entry is None else f"0x{entry:04X}"
        raise SystemExit(
            f"gen_sprinter_base_data_defs: _main={rendered} is not in WIN1"
        )
    lines.extend(("PUBLIC SPRINTER_CLIENT_ENTRY",
                  f"DEFC SPRINTER_CLIENT_ENTRY = 0x{entry:04X}"))
    for name in SYMBOLS:
        address = found.get(name)
        if address is None:
            raise SystemExit(f"gen_sprinter_base_data_defs: missing {name}")
        if not 0x8000 <= address < 0xC000:
            raise SystemExit(
                f"gen_sprinter_base_data_defs: {name}=0x{address:04X} is not in WIN2"
            )
        lines.extend((f"PUBLIC {name}", f"DEFC {name} = 0x{address:04X}"))
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[OK] Sprinter client entry and {len(SYMBOLS)} renderer DATA imports")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
