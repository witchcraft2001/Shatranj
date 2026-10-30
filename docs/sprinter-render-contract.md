# Sprinter rendering and interrupt boundaries

The 640×256 mode, 48×24 board cells, centred 40×20 pieces and shared
palette indices are unchanged. Original piece pages and slot addresses
remain valid. The additional opaque cell path changes byte movement only.

## Additional allocation

Existing HDR asset indices 0–11 retain their meanings. Append exactly
8×16384 bytes (128 KiB), including code, metadata, caches and padding:

| HDR indices | Content |
| --- | --- |
| 12–15 | 108 packed 48×24 cells, three empty cells, two checker rows |
| 16 | Second rendering code page, location tables and cache metadata |
| 17–18 | Five precoloured AFNT raster sets |
| 19 | Four 4 KiB string raster entries |

Cells never cross a page boundary. `gfx_draw_tile_offset` accepts a full
16-bit WIN0 offset; `gfx_draw_tile` retains its slot-based ABI. Both use
the same blitter. Original art is read from committed PNGs; no SVG or PNG
preparation tool runs during the build.

The stack and every network buffer keep their original addresses.
`LOWRAM_RENDER_PARAMS` uses the previously unused 16 bytes at B8F0.
The coalescer runs after restoring system WIN0 and admits interrupts while
its code page occupies WIN3. Only its map/restore boundary requires DI.
The eight-entry dirty ring uses 48 bytes of the existing reserve above
RTC_PRESENT, at BD81, below IM2_STUB. Both are explicit fixed-layout
regions. This reuses resident space without adding an allocated page.

## Dirty regions and synchronization

A full board logs one 192-byte ×192-row rectangle, suppressing intermediate
cell/tile records. A new region absorbs contained regions and merges with
any region whose bounding area is no greater than their summed areas.
Merging restarts the scan so it is transitive. Overflow collapses all
pending changes to their bounding rectangle; it does not set dirty_all.
Only an explicit full-buffer clear sets dirty_all.

`flip_sync` copies the new front buffer into the hidden buffer using
same-PORT_Y horizontal accelerator copies. Widths above 256 split into
256 bytes plus the remainder. Width 256 and height 256 retain the hardware
zero-byte encoding. Window restoration and row interrupt yields apply in
both buffer directions.

## Interrupt policy

WIN0 may be replaced only under DI and must be restored before EI.
Every accelerator burst finishes with ACC_OFF; PORT_Y is parked before
an interrupt yield. Narrow tiles may finish their last 32 rows without
a yield; wide bands and fills yield every four operations. Text yields
between glyphs and after every eight staged characters, including the
width/clipping pre-scan. Its pre-scan yield restores the caller's WIN3
page because a string literal can live there.

Sprinter overlay computation now starts with EI. This is an intentional
Sprinter dispatcher contract change: first-use legal-move hint generation
was measured holding DI for 10.22 ms. Context registers, stack arguments,
return values and flags are unchanged. Entry mapping and return mapping
remain atomic under DI; the return trampoline explicitly disables
interrupts before restoring WIN3. The same ISR register/window preservation
already supports interruptible cold rendering and NET overlays. This does
not change the ZX/Next dispatchers or any chess/session semantics.

The cold-call generator can select a second code page using a tagged entry
address, preserving the argument frame, return registers, nesting and
actual WIN3 restoration. The original full-board entry-table slot remains
reserved; its resident thunk selects the second page. CPU tests exercise
cross-page argument/register calls and nesting; MAME exercises physical
mapping through 300 set changes.

## Optional text paths

Precolour attributes are 01, 0D, 0B, 0C and 10. Other attributes retain the
original compositor. String keys contain the actual staged/clipped text,
attribute, output width, font page and explicit font generation. Early
hits must also fit the available row width. Two planes with 160-byte source
strides support the full 320-byte destination row within each 4 KiB entry.
The LRU metadata lives in the second code page. A miss commits validity
only after capturing the completed raster.

`text_font_version` must change when font contents change in place. Zero
is reserved for the original packaged font; a changed font page or nonzero
generation disables static precolour. Invalidate the string cache before
reusing a generation value. A new
EXE initializes the metadata afresh. Cache and precolour switches default
to zero: measured miss cost and the precolour result do not justify putting
these paths into normal gameplay. The production profiler enables them
explicitly and measures first output, repetition and eviction separately.
