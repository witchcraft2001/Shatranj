# Sprinter 640-mode assets

The Sprinter target uses DSS mode `0x82` (640×256, packed 4bpp). Its normal
build does not rasterize SVG or PNG sources. The tracked files under
`assets/sprinter/` are the pinned raster inputs, and
`tools/build_sprinter_assets.py` deterministically converts them into four
16-KiB GFX640 pages plus one palette page.

## Piece storage

Each of the 36 pieces has a 32×16 RGBA source raster. A piece is stored as two
adjacent 16×32 GFX640 tiles: visible rows occupy storage rows 4..19 and all
other rows contain `0xFF`. The renderer places the pair at `square_x + 8` and
`square_y`, giving the 32×16 artwork natural 8-pixel horizontal and 4-pixel
vertical margins inside a 48×24 square.

Packed bytes use the left pixel in the high nibble and the right pixel in the
low nibble. Palette index 15 is transparent. Since `GFX_KEY_FF` skips only a
complete `0xFF` byte, the packer normalizes alpha in pixel pairs and rejects
indices outside 0..15.

## About image and palettes

The About artwork is a pinned 384×192 RGB raster. It occupies a 24×6 grid of
16×32 tiles and is drawn only over the board area. AFNT640 draws its captions.

Gameplay and About use separate RGB888 profiles. Slots 0..9 are identical UI
colours in both profiles. Gameplay reserves slots 10 and 11 for the current
light/dark board theme, slots 12..14 for piece tones, and slot 15 for keyed
transparency. Five theme pairs are stored in the palette page. Palette restore
always reads that pinned page, loads the gameplay profile, and reapplies the
currently selected theme after uNet or modal rendering.

## Maintenance regeneration

Regenerate the tracked source rasters only when their source artwork changes:

```sh
python3 tools/build_sprinter_rasters.py --root .
```

This maintenance command requires `rsvg-convert` and ImageMagick. Vector SVGs
are supersampled, alpha-trimmed to their useful artwork, then downscaled once
to 32×16; pixel-art SVGs marked with `shape-rendering="crispEdges"` are
alpha-trimmed too and expanded with point filtering. The 48×24 square, not an
SVG's transparent frame, supplies the gameplay margin.
The command also refreshes `assets/sprinter/raster_manifest.json`, including
source and output SHA-256 values. Run `make sprinter-check` after regeneration.

## Piece atlas source files

`assets/sprinter/pieces-california.png`, `pieces-mpchess.png`, and
`pieces-totoy.png` are the editable Sprinter sources. Each is a non-interlaced
RGBA8888 PNG, exactly **192×32** pixels: six 32×16 figures across and two rows.
The order is `wK wQ wR wB wN wP` on the first row and `bK bQ bR bB bN bP` on
the second. Alpha below 64 is transparent; no matte colour is reserved.

The target build reads these PNGs directly and packs them as two 16×32 GFX640
tiles per figure. Artwork may use at most **three opaque RGB colours** per
atlas. They are mapped to palette slots 12–14 and may differ for every set.
The palette for an atlas is declared in `raster_manifest.json`; changing its
colours requires updating that declaration too. Slots 0–9 are reserved for
HUD/text, 10–11 for the board theme, and 15 is transparent. Consequently HUD
uses at most **ten fixed colours** and must never use indices 10–15.
