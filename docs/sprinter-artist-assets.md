# Sprinter artist assets

The game uses 640×256 pixels with one shared 16-colour palette. View PNGs
with vertical scaling ×2: a stored 48×24 board square then appears square.
Use nearest-neighbour scaling when inspecting finished pixel art.

## Piece geometry and files

Edit `assets/sprinter/pieces/{california,mpchess,totoy}/*.png`. Each set has
`wK,wQ,wR,wB,wN,wP,bK,bQ,bR,bB,bN,bP`, in that order. Preserve filenames,
directories and the **40×20 RGBA canvas**. Every alpha value must be 0 or
255. Piece transparency may have any shape; individual transparent pixels
are supported by precomposing the artwork onto its background.

The renderer centres the tile in the unchanged 48×24 cell, with **4 pixels
on either side and 2 rows above and below**. Transparent space inside the
PNG is additional to those margins. Cursor/selection frames remain 48×24;
hint dots and last-move rings remain 16×8.

`src/sprinter/render_layout.json` owns piece and cell geometry. The packer,
assembly constants and previews derive dimensions from it. Each packed
4bpp row has 20 bytes, with the left pixel in the high nibble. A tile has
400 useful bytes and 112 zero padding bytes, occupying two 256-byte
accelerator slots. Artists supply PNGs, never padded binary tiles.

## Colours

Use the exact RGB values in `assets/sprinter/palette.json`. Colour profiles,
antialiasing and partial alpha can change values and cause build errors.
Each set owns indices 4–7; changing PIECES uploads that set's four colours.

| Index | Role | Current RGB |
| --- | --- | --- |
| 4 | White fill | `#F8F8F0` |
| 5 | Source dark strokes / MPChess black body | `#202020` |
| 6 | California/Totoy black fill | `#4C4C4C` |
| 7 | Light detail / added black rim | `#C8C8C0` |

Finished pieces may also use the shared colours at indices
0, 1, 9, 10, 11, 12, 13 and 14. Index 13 (`#707070`) carries California's
original gray highlights, distinct from its added brighter rim.

Do not use indices 2, 3 or 8 in pieces: these are the two board backgrounds
and move-flash yellow, and using them makes parts disappear. Index 15 is
reserved for the hardware transparency key and is also forbidden.

Review every piece on light and dark squares of CLASSIC, BLUE, GREEN,
CYAN and MAGENTA, plus flash yellow (`#FFD24A`). The source's holes, open
cuts and separate components take priority over a continuous outside rim.
White pieces receive no additional rim.

## Manual SVG import and review

`tools/rasterize_sprinter_pieces.py` is a manual import tool. Normal builds
read committed PNGs only. Its default output is the separate candidate
folder `build/sprinter/pieces40-candidates`; review before copying files
into `assets/sprinter/pieces/` so artist edits are never silently replaced.

Chrome renders each SVG in a fixed 1024×1024 viewport. An empty or clipped
render fails. Alpha, colour-region and original-stroke masks receive the
same proportional bbox fit with 8% margin. Nine quarter-pixel grid phases
are ranked by source features, silhouette error and stroke preservation;
zero wins equal scores. Thin diagonal passages are reopened only when the
high-resolution source marks them as exterior. The black rim comes from
source geometry, with physical pixel aspect ratio accounted for, and must
preserve source components and holes.

Intentional exceptions belong in `assets/sprinter/piece_conversion.json`.
The California gray-highlight rule is reproduced there. The old 32×16
California queen bead and MPChess rook notch coordinates were reviewed
again against the SVGs at 40×20: the new coverage conversion retains them
without coordinate patches. Do not scale the old patch coordinates.

Conversion comparisons are under `build/sprinter/preview/pieces40/`:
`*-comparison.png` shows SVG → archived 32×16 → 40×20 in colour and
silhouette. `*-themes.png` and `*-themes_zoom.png` show all backgrounds at
actual corrected scale and 4× without smoothing. Archived theme previews
have `-old-themes` in their names. Source renders and per-phase scores are
under `build/sprinter/preview/source1024/`.

## Markers and logo

| File | Canvas | Current colour |
| --- | --- | --- |
| `markers/dot.png` | 16×8 | `#39C15A` |
| `markers/ring.png` | 16×8 | `#4A90D9` |
| `markers/cursor.png` | 48×24 | `#00BEFE` |
| `markers/select.png` | 48×24 | `#FFD24A` |
| `logo_sprinter.png` | 172×16 | `#E8E8E8`, `#00BEFE` |

These assets use hardware transparency: for each horizontal pair starting
at even X, both pixels must be opaque or both transparent. Index 15 is the
key, not an opaque colour. Return both the logo and its working source
`source/sprinter_logo_source.png` if editing the source. Asset preparation
scripts are manual tools and their outputs must be reviewed before merging.

## About artwork

`about640.png` is a 512×256 indexed PNG with its own palette. Use only the
first 14 palette entries in the artwork; the final two are reserved for
the overlaid version caption. Antialiasing and dithering are permitted
within the 14-colour limit. `assets/pc-client/about/about-shatranj.png` is
the 1254×1254 reference, not a Sprinter build input.

## In-game selection

PIECES cycles California → MPChess → Totoy → California. Launch starts
with California. About/fade, save/load, reset and session changes retain
the selected set. Theme changes affect square colours only. The palette,
set order, cell geometry and marker behaviour are unchanged by 40×20 art.
