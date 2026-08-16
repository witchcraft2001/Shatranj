# Sprinter size report

`make sprinter-size-report` rebuilds the Sprinter EXE and writes
`build/sprinter/size_report.json` (plus a human-readable
`build/sprinter/size_report.md`).

Unlike `docs/size-report.md`'s ZX/Next report, this one is not framed around
a `.tap`/`.OVL`/`.DAT` layout: the Sprinter target is one flat 32768-byte
resident image plus a handful of 16384-byte asset pages, and the C image is
built by a completely different toolchain (z88dk classic ABI via `zcc +pps`,
not SDCC). `tools/gen_sprinter_size_report.py` is a separate tool from
`tools/gen_size_report.py` for exactly that reason — see that tool's own
docstring.

What it reports:

- **C image budget** (`#4180`–`#8000`, plan D2): `resident_c.bin`'s size
  against the fixed 16000-byte ceiling, with a hard failure (`over_budget`)
  if it is exceeded — the same C image also has to leave room for
  `platform_primitives.bin`, whose own base and size are fixed by plan D1's
  splicer, so there is no fallback budget to borrow from without a deliberate
  layout change.
- **Section totals**: C (sccz80) vs. asm (z88dk-z80asm: `render_core.asm`,
  `overlay_loader_sprinter.asm`, the atlas table) code/rodata/data/bss.
- **Per-module breakdown**, address-gap attributed from `resident_c.map`
  (documented in the tool itself as an approximation, not exact per-symbol
  sizes), tagged with a hand-maintained hot/cold tier (plan D7-ter:
  `hot` = mapped and touched every frame, `cold-candidate` = a migration
  candidate to an overlay if the C image ever runs out of room,
  `boot-only` = runs once at startup). A module the tool has not been told
  about yet is reported as `unclassified` rather than silently guessing —
  see `HOT_COLD_TIERS` in the tool.
- **Overlay slot usage**: the 2 KiB `OVL_SLOT` copy path (mode 0, currently
  just CONTROL) and the two 16 KiB WIN3-mapped pages (mode 1, plan D7-bis):
  page 1 is RULES/BOARD/SAVELOAD/RESTORE/FILEUI (variable-size slots, not a
  uniform 4 KiB one -- `tools/make_sprinter_overlay_page.py`'s own `LAYOUT`),
  page 2 is NET (8 KiB) + INPUT_EDIT (4 KiB, S9 chat pass) + a 4 KiB
  reserve (`LAYOUT2`). GUI_LOG has no WIN3 slot on this port at all -- its
  Sprinter-native replacement (`src/sprinter/gui_log_sprinter.c`) is
  WIN1-resident, not an overlay.

This is a reporting tool, not a growth gate: it fails the build only on an
actual C-image overrun, not on a tier estimate looking large. There is no
tracked baseline/diff mechanism here (unlike `docs/size_report.baseline.json`
on the ZX/Next side) — S5's size question is "does it fit today", not
"did it grow since last commit"; add a baseline later if that changes.
