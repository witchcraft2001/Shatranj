#!/usr/bin/env python3
"""Publish permanent-WIN2 data and the direct app entry used by runtime."""

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
    parser.add_argument("--app-map", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    found = map_symbols(args.map_file.read_text(encoding="utf-8", errors="replace"))
    app = map_symbols(args.app_map.read_text(encoding="utf-8", errors="replace"))
    lines = ["; Generated base DATA imports; do not edit."]
    for name in SYMBOLS:
        address = found.get(name)
        if address is None:
            raise SystemExit(f"gen_sprinter_base_data_defs: missing {name}")
        if not 0x8000 <= address < 0xC000:
            raise SystemExit(
                f"gen_sprinter_base_data_defs: {name}=0x{address:04X} is not in WIN2"
            )
        lines.extend((f"PUBLIC {name}", f"DEFC {name} = 0x{address:04X}"))
    app_main = app.get("_main")
    if app_main is None or not 0x4100 <= app_main < 0x8000:
        raise SystemExit(
            "gen_sprinter_base_data_defs: app _main is not in resident WIN1"
        )
    lines.extend(("PUBLIC sprinter_app_main",
                  f"DEFC sprinter_app_main = 0x{app_main:04X}"))
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[OK] Sprinter renderer DATA imports and direct app entry: "
          f"{len(SYMBOLS) + 1} symbols")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
