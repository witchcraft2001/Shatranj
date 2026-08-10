# Sprinter render budget (S2)

Both hotkeys measure the same way: run a fixed **4-second window** off the
CMOS clock (DSS SysTime) and report **how many iterations fitted in it**.
That inversion is what turns a 1-second-resolution clock into a usable
instrument — the count, not the elapsed time, carries the precision.

```
per_op_ms = 4000 / iterations_reported
```

**Why not the 50 Hz frame tick.** The first version of this bench counted
frames via the IM2 stub's `frame_flag` (`bench_poll`). On hardware that
proved unusable: three runs of the identical 50-redraw board loop reported
`0x15`, `0x0F` and `0x08` frames, and the text loop reported `0x0000`
whether it ran 100 or 1000 lines. A bench holds DI almost continuously
(`text_print` keeps it for a whole string, so its DI duty cycle is ~99.8 %),
and under that load the tick is not reliably observed — either it arrives
inside a DI span, or the IM2 stub classifies it as a keyboard interrupt
because SIO RR0 bit 0 is set by then (`resident_s1.asm`'s `im2_stub`). The
undercount is large and varies run to run, so no budget claim can rest on
it.

The frame counter is still displayed, as the **second** hex16 of each pair,
purely as a cross-check. Expected honest value over a 4-second window is
`0x00C8` (200 frames). Anything far below that is measuring the undercount,
not the renderer — and that gap is itself worth reporting, because it bears
on port.md §3.9's claim that a tick is merely delayed, never lost, by a long
DI span.

Per CLAUDE.md rule 6, this file records numbers a human tester reads off
the running stand — it is never filled in from a build log or an
emulator run alone. The **MAME** column is informational (accelerator
timing fidelity in MAME is unconfirmed, port.md §6); the **hardware**
column is authoritative for the DoD.

| Bench | Hotkey | Iterations | What one iteration does |
| --- | --- | --- | --- |
| Board redraw | `5` | as many as fit in 4 s | Full 8×8 board: 64× (`gfx_fill_rect` 48×24 + `gfx_draw_tile` 32×16) + one `gfx_draw_tile` 40×20, into the back buffer |
| Text line | `6` | as many as fit in 4 s (in batches of 64) | One `text_print` call, the fixed 38-character proportional string (95 byte-columns, fully inside the row — nothing clipped), info-panel position |
| CPU clock | `7` | as many as fit in 4 s (in batches of 64) | 256 `DJNZ` iterations = 3323 T-states. Not a render measurement: it establishes which CPU clock the other two numbers belong to (≈`0x20E0` at 7 MHz, ≈`0x62B0` at 21 MHz before wait states) |
| Accelerator | `8` | three 4-second windows | The same 192×192-byte area filled three ways: one 192-byte accelerator operation per row, eight 24-byte ones per row, and plain CPU stores. Isolates block size as the only variable |

## Budget targets (port.md §3.3)

| Operation | Target | Formula | MAME | Hardware |
| --- | --- | --- | --- | --- |
| Full board redraw (strip, `9`) | ≤ 1 frame (≤ 20 ms) | `4000 / count` — so **count ≥ 200** passes | `0120` (288) = 13.9 ms — **met** | `0120` (288) = **13.9 ms — met** |
| HUD/text line, 38 chars (`6`) | ≤ 1 ms | `4000 / count` — so **count ≥ 4000** (`0x0FA0`) passes | `0440` (1088) = 3.68 ms — missed | `0440` (1088) = **3.68 ms — missed 3.7×** |

## How to fill this in

1. Build and boot the stand per `docs/sprinter-testnotes/S2.md`.
2. Press `5`. The screen holds still for ~4 s (that is the window, not a
   hang), then two hex16 numbers appear: the redraw **count** at (16,232)
   and the frame counter's cross-check at (72,232).
3. Press `6`. Same 4-second window, then the line **count** at (200,232)
   and its cross-check at (256,232).
4. Convert with `per_op_ms = 4000 / count` and enter both the raw counts
   and the result below. Do this once for MAME and once for real hardware
   (separate rows); the DoD ("full board ≤ 1 frame, HUD line ≤ 1 ms" —
   port.md §5/S2) is only confirmed once the **hardware** numbers are in,
   per CLAUDE.md rule 6.

| Run | Date | Board count (hex16) | Board per-redraw ms | Board frame cross-check | Text count (hex16) | Text per-line ms | Text frame cross-check | CPU probe (hex16) | DoD met? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MAME | 2026-08-09 | `0034` (52) per-cell / `0120` (288) strip | **77 ms** per-cell, **13.9 ms** strip (budget 20) | `0015`/`0018` (21–24 of 200) | `0440` (1088) | **3.7 ms** (budget 1) | `32C0` (12992), turbo on | board **yes** (strip), text **no** |
| **Hardware** | 2026-08-09 | `0036` (54) per-cell / `0120` (288) strip | **74.1 ms** per-cell, **13.9 ms** strip (budget 20) | `0012` (18 of 200) per-cell | `0440` (1088) | **3.68 ms** (budget 1) | `30C0` (12480), turbo on | board **yes** (strip), text **no** |

### Reading of the 2026-08-09 hardware run (authoritative)

All five benches run on real Sprinter hardware, turbo on. **The hardware
reproduces MAME**: three of the five numbers are identical to the digit, and
the other two are within 4 %.

| Bench | Hotkey | Hardware | MAME | Δ |
| --- | --- | --- | --- | --- |
| Board, per cell | `5` | `0036` (54) → 74.1 ms | `0034` (52) → 76.9 ms | +3.7 % |
| Text line, 38 chars | `6` | `0440` (1088) → 3.676 ms | `0440` (1088) | identical |
| CPU clock | `7` | `30C0` (12480) | `32C0` (12992) | −3.9 % |
| Accelerator sweep | `8` | `0165`/`006A`/`0029` | `0165`/`006A`/`0029` | identical |
| Board, strip | `9` | `0120` (288) → 13.9 ms | `0120` (288) | identical |

Three conclusions follow, in order of how much they change:

**1. The board half of the S2 DoD is met on hardware.** `9` = 288 redraws in
4 s = **13.9 ms** for a full 8×8 board, inside the 20 ms frame budget, at
5.3× the per-cell strategy's 74.1 ms. The strip strategy is confirmed on
silicon, not just in the emulator.

**2. MAME's accelerator timing is representative.** The block-size sweep —
the one probe designed to answer this — returned the *same three counts* on
hardware as in the emulator, so the 3.4× (block size) and 8.7× (accelerator
vs CPU) ratios hold on real hardware. This retires the standing "MAME's
accelerator emulation is unconfirmed" caveat **for timing measurements**.
It says nothing about the `#58` alias's *visual* transparency behaviour,
which is a correctness question and stays hardware-authoritative (P4).

**3. The machine's effective CPU throughput is ~10 M T-states/s.** Hotkey
`7` (a pure `DJNZ` loop, no data access) gives 12480 × 3323 T ÷ 4 s =
**10.37 M T/s**. Hotkey `8`'s CPU mode gives an independent cross-check
through a memory-writing loop: its inner loop is `ld (hl),e` / `inc hl` /
`djnz` = 26 T per byte, and 36 864 bytes in 97.6 ms works out to **9.8 M
T/s** (**10.0 M** once the per-row setup outside the byte loop is counted
in). The two agree, so VRAM stores cost about what instruction fetches do
here — both figures already include wait states. Nominal clock is 21 MHz;
roughly half of it is lost to waits, and that is the number every budget
estimate below has to be built on.

The frame cross-checks came in even lower than in MAME — 18 of 200 frames
for the board bench, 4 of 200 for the text bench — confirming on hardware
that the 50 Hz tick cannot be used as a bench clock under near-continuous
DI, and quantifying the loss for port.md §3.9.

### Reading of the 2026-08-09 MAME run

Both operations miss the budget by essentially the same factor — 3.8× for
the board, 3.7× for the text — and both readings reproduced exactly across
repeated presses (`0034` twice, `0440` twice), so this is a stable
measurement, not noise.

**The CPU clock does not explain it.** Turbo was on by default for these
runs, confirmed by the tester and by hotkey `7`: `32C0` = 12992 units in
4 s = 43.2 M T-states/s, i.e. ~10.8 MHz *effective* against a 21 MHz
nominal clock (the ~2× shortfall is memory wait states — every `DJNZ` in
the probe fetches two bytes through a mapped window). So the machine was
already at its fast setting.

**What the numbers say instead: the blocks are too small.** Combining
hotkeys `5` and `7`: a board redraw moves 64×(24×24 + 16×16) + 20×20 =
53 648 bytes in 77 ms = 697 k bytes/s = **1.43 µs per VRAM byte**.
`HW_NOTES.md` §4 quotes the accelerator at 256 bytes in ~37 µs =
**0.145 µs/byte** — ten times better. The difference is operation size:
this port's primitives were issuing 16-byte (tile row) and 24-byte (fill
column) operations, roughly 2 560 of them per redraw, and the accelerator's
cost is dominated by a large fixed per-operation overhead rather than by
bytes moved.

Every reference implementation available to this port sizes its blocks far
larger — flappybird blits 138-byte rows, flexnavigator's `fnwin.z80` sizes
its vertical copy to the whole window height, spevosdk's screen fill uses
two 160-byte operations per row — and spevosdk's `lib_tiles.asm` does not
use the accelerator *at all* for 4-byte tile rows, falling back to unrolled
`LDI`. An earlier note here concluded "the accelerator buys nothing"; that
was wrong, and it is withdrawn. The accelerator works; it was being used in
the regime where it loses.

`gfx_fill_rect` now picks the orientation that yields the fewer, larger
operations (gfx640.asm's own branch, which this port had dropped).

### Block-size sweep, MAME, 2026-08-09 (hotkey `8`)

Same 192×192-byte area (36 864 bytes), 4-second window each:

| Mechanism | Count | Throughput | Per byte | Per area |
| --- | --- | --- | --- | --- |
| One 192-byte accelerator op per row | `0165` (357) | 3.29 MB/s | 0.304 µs | 11.2 ms |
| Eight 24-byte ops per row | `006A` (106) | 0.98 MB/s | 1.024 µs | 37.7 ms |
| Plain CPU stores | `0029` (41) | 0.38 MB/s | 2.647 µs | 97.6 ms |

The accelerator works, and MAME emulates it: it beats CPU stores **2.6×**
even at 24-byte blocks and **8.7×** at 192-byte blocks. Block size alone is
worth **3.4×**. So neither "MAME doesn't accelerate" nor "the accelerator
is useless" was right — the operations were simply too small.

**What this means for the board budget.** At the big-block rate a
board-sized area (36 864 bytes) is painted in **11.2 ms**, inside the 20 ms
budget. At the small-block rate the same area takes 37.7 ms — over it
before a single piece is drawn. The bench's current per-cell strategy
(64 × fill 576 B + 64 × tile 256 B) can only ever issue 24- and 16-byte
operations, and that is exactly where its 77 ms comes from: 37.7 ms of
fills + 16.8 ms of tiles + per-call overhead.

The budget is therefore reachable, but not by tuning the primitives: the
board has to be drawn as **full-width row operations** — compose the board
rows (squares and pieces together) in RAM, then one 192-byte copy per row.

Hotkey `9` implements exactly that as a bench: two 192-byte band rows are
composed once, then each 24-row band is a single `gfx_blit_rows` call with
stride 0, so a whole board is 192 operations of 192 bytes. Same picture as
hotkey `5`, same bytes moved, different operation size — the pair is the
evidence. `9`'s count is the number the S2 DoD hangs on; `5` stays as the
per-cell baseline.

| Bench | Hotkey | Iterations | What one iteration does |
| --- | --- | --- | --- |
| Board redraw, strip | `9` | as many as fit in 4 s | The same 8×8 checkerboard as `5`, as 8 band blits of 192×24 bytes (192 operations of 192 bytes) |

Composing pieces into those rows for real belongs to the UI stage: it needs
a staging buffer sized for a band and a decision about whether pieces are
composited in RAM or blitted over the strip with the hardware `#FF` key
(§3.3). What `9` establishes is that the board-sized byte movement fits the
budget once the operations are large.

**Measured, MAME, 2026-08-09:** hotkey `9` reported `0120` = 288 redraws in
4 s = **13.9 ms per full board redraw**, against 77 ms for the same picture
drawn per cell — a 5.5× improvement and inside the 20 ms budget. Confirmed
twice, before and after a fix to the row composition, with the same count:
the blit moves 192×192 bytes regardless of what they contain. (The
predicted floor from the block-size sweep was 11.2 ms; the extra 2.7 ms is
the per-call overhead of the 8 band blits and the window sampling.) The
board half of the S2 DoD is therefore met in MAME; the text half is not,
and both still need a hardware run to be authoritative.

### Why the text line still misses its budget

The same disease, one size smaller. `text_print`'s row renderer issues
**four accelerator operations per byte-column** of output — latch the glyph
mask, AND it with the foreground pattern, XOR with the background, then a
vertical copy to store — each moving the 8 bytes of one glyph column. A
38-character line is 95 byte-columns, so 380 operations for 760 output
bytes: 3.68 ms measured, i.e. **4.8 µs per output byte**, worse than the
2.65 µs/byte of plain CPU stores. At an 8-byte block the accelerator is not
merely unhelpful, it loses — which is exactly why spevosdk's `lib_tiles.asm`
drops it for 4-byte tile rows.

The obvious fix looks like the one the board just demonstrated: compose the
line's 8 rows in a RAM buffer with ordinary CPU AND/XOR, then blit them as
8 operations of ~95 bytes, trading 380 accelerator operations for 8.

**That fix does not reach 1 ms, and the hardware CPU measurement is what
proves it.** An earlier revision of this file estimated the rewrite at
"~0.9–1.0 ms"; that estimate was made before hotkey `7` existed and is
withdrawn. The compositing is 760 output bytes of CPU work, and the
cheapest honest inner loop per output byte is

```
ld a,(de)   ; 7   glyph mask (column-major, contiguous within a glyph)
inc de      ; 6
and c       ; 4   fg XOR bg
xor b       ; 4   bg
ld (hl),a   ; 7   into the row buffer
inc h       ; 4   next row — only this cheap if the 8 row buffers are
            ;     placed 256 bytes apart so the step is a register bump
            ; = 32 T
```

760 × 32 T = 24 320 T ÷ 10 M T/s = **2.4 ms**, before the blit. Stripping it
to the bone — black-background fast path (no XOR), fully unrolled (no
`DJNZ`) — floors at ~24 T/byte = **1.8 ms**. Add ~0.3 ms for the 8 blits and
the rewrite lands at **2.1–2.7 ms against 3.68 ms today**: a ~1.4–1.7×
improvement, not the 3.7× the budget needs. Byte-at-a-time CPU transformation
of 760 bytes simply cannot fit 1 ms on a machine that retires ~10 M T-states
per second; even `LDI`, which transforms nothing, costs 16 T/byte.

So the budget miss is not a coding defect to be fixed by dropping the
accelerator — it is a floor. Only the accelerator moves 760 bytes fast
enough (0.2–0.3 µs/byte → 150–230 µs), and it must perform the AND/XOR
itself, which is exactly what the donor's sequence does — just eight bytes
at a time. Any real fix has to keep the accelerator and **enlarge its
blocks**, and whether that is possible is a hardware question this port has
not answered: a glyph's raster is contiguous (w×8 bytes), so the latch/AND/
XOR passes could plausibly batch per glyph (3 operations instead of 2w), but
the store is a `COPY_V` per byte-column and there is no evidence the latch
can be stored in sub-ranges. That needs an experiment on the stand, not a
rewrite on speculation.

**What does fit the budget today.** The measured cost is **38.7 µs per
byte-column** (3.676 ms ÷ 95). One millisecond therefore buys **~26
byte-columns ≈ 10–12 proportional characters** — so short HUD updates (a
move like `e2e4`, a clock, a status word) are already inside budget, and it
is the 38-character full-width info line that is not. The bench deliberately
measures that worst case.

A rewrite would still have one non-performance benefit worth noting: it makes
the compositing arithmetic verifiable in z88dk-ticks for the first time —
today it cannot be checked at all, because the accelerator substitutes its
own latched byte for the AND/XOR operand and plain Z80 computes something
else (see `text640.asm`'s header). But that benefit costs the donor's
byte-for-byte proven accelerator sequence, and buys no budget.

### RAM-compositing dead end (built, measured, retired — 2026-08-09)

Built on an explicit decision, and built as a **second renderer rather than
a replacement**: `asm/sprinter/text_compose.asm` alongside the untouched
`asm/sprinter/text640.asm`. Hotkey `0` ran the composed path over the
identical string, colour and X that hotkey `6` ran the donor path over, so
the two were one keystroke apart on one screen — the same "same picture,
different mechanism" shape that `5`/`9` used to settle the board. The rule
going in: whichever wins on hardware keeps its file; the loser's is deleted.

The projection, made before the hardware run so the measurement could
contradict it: the composed path's inner loop is 32 T per output byte on
the general path and 28 T on the black-background path (bg = 0 drops the
XOR, which frees `B` to be the column counter and turns the loop tail into
a single `DJNZ`), so a 95-column line should cost 244 T per byte-column
against the donor's measured ~34.3 µs. That works out to **~2.9 ms, i.e.
~1.3× faster** — not the 1.4–1.7× an earlier revision of this document
estimated, which counted the composite loop against the whole line time
instead of against the per-column part it actually replaces.

**The hardware measurement said the opposite.** Same string, same colour,
same position, same 4-second-window instrument: the donor path again
measured `0440` (1088) = 3.68 ms — identical to the first run, confirming
the measurement is reproducible — and the composed path measured `0280`
(640) = **6.25 ms, 1.7× slower**. The two renderings were pixel-identical
on screen (the compositing arithmetic was correct), so this was a genuine
performance result, not a bug in the visible output. No T-state accounting
built from the CPU-clock probe predicted this; the gap between the ~2.9 ms
projection and the measured 6.25 ms was not tracked down, because the
result was decisive enough on its own terms — per the rule stated going in,
the donor won and `text_compose.asm`, `tests/sprinter/z80/t_text_compose.asm`
and hotkey `0` were removed. `text640.asm` is the port's only text renderer.
The one surviving lesson: for accelerator-vs-CPU tradeoffs on this
hardware, arithmetic built from isolated micro-probes (`7`, `8`) has now
been wrong three times in this stage when extrapolated to a different code
shape — measure the actual shape, don't project onto it.

While it existed, `tests/sprinter/z80/t_text_compose.asm` did check the
composited **pixel values** — `out = (mask AND (fg^bg)) XOR bg`, both
colour paths, plus the blit geometry and the clipping contract — the first
time any part of this port's text output had been verifiable under
z88dk-ticks at all. That benefit went with the file; `text640.asm`'s
accelerator-substituted arithmetic remains unverifiable outside MAME/
hardware, as documented in its own header.

The frame cross-checks quantify the tick undercount discussed above: in MAME
21–24 and 7 frames observed where 200 elapsed (~11 % and 3.5 %), on hardware
18 and 4 (9 % and 2 %). The text bench, whose DI duty cycle is the higher of
the two, is the worse of the two on both, exactly as the DI explanation
predicts.

## Notes

- A count of `0000` is always a defect, never a pass: the window runs for
  4 whole seconds, so at least one iteration must complete unless the loop
  itself is broken.
- A single `C` glyph at (16,232) instead of numbers means the machine
  reported no CMOS clock, so the bench refused to invent a timing it
  cannot measure. Record it as such; the DoD stays unconfirmed.
- Both benches clear their target buffer to black before starting, so the
  bench screen never composites over what the S1 stand left there. The
  clear is outside the timed loop: the real UI repaints the board over
  itself rather than clearing first, so counting a full-screen clear as
  part of a "board redraw" would overstate the cost.
- The board bench draws into the buffer *not* currently displayed and
  flips once at the end (outside the timed loop), so the timed loop
  measures pure draw cost, not flip cost. That flip leaves buffer 1 on
  screen, and the stand's tick/RTC line only ever goes to buffer 0 — the
  line looks frozen until hotkey `1` flips back. Documented S1 behaviour
  (`docs/sprinter-testnotes/S1.md` P4), not a hang.
- The hardware `#FF`-key tile and the 40×20 wide tile drawn by hotkey `6`
  are visual-only checks (`docs/sprinter-testnotes/S2.md` P4); they are
  not separately timed.
