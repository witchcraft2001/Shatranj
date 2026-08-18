#!/usr/bin/env python3
"""Prepare the About screen artwork for mode #82 (640x256x4bpp).

Manual, one-off tool -- never part of the build, mirroring
tools/prepare_sprinter_logo.py and tools/rasterize_sprinter_pieces.py.
Reads the master artwork committed for provenance at
assets/pc-client/about/about-shatranj.png (1254x1254 RGB, the same image
the Qt client's About dialog uses) and writes the build-ready, PALETTISED
assets/sprinter/about640.png that tools/build_sprinter_about.py packs.

WHY THE QUANTISER IS NOT IN THE BUILD. Pillow's MEDIANCUT output is not
guaranteed stable from release to release, and make sprinter-check gates
the smoke image on byte-for-byte determinism. So the lossy step runs here,
once, by hand, and its RESULT is committed -- exactly the split CLAUDE.md
describes for the other Sprinter art tools ("их вывод коммитится и
правится художником в любом редакторе"). The build then does nothing but
deterministic bit-packing. An artist can also just open about640.png and
repaint it, as long as it stays 512x256 with at most 16 palette entries.

GEOMETRY. Mode #82 pixels are visually about half as wide as they are tall
-- the same ratio that makes a 48x24 board cell look square (port.md
section 3.6, and prepare_sprinter_logo.py's own note). So a PHYSICALLY
square master has to become 512x256 stored pixels, not 256x256: the
non-uniform resize here is what cancels the pixel aspect, not a distortion
of it. 512 of the screen's 640 pixels leaves a 64-pixel (32-byte) black
margin either side, which the packer turns into a pillarbox rather than
storing -- see that tool for why the stored asset is 512 wide.

COLOURS. Mode #82 is 4bpp: 16 palette entries for the WHOLE screen. The
About screen is a full-screen takeover, so it does not have to share those
16 with the HUD -- the overlay swaps the whole palette in and restores the
theme palette on exit. All 16 therefore go to this image. Index 15 is NOT
special here: the hardware transparency key only applies to whole #FF
bytes under VRAM_ALIAS_KEY, and the About blit is opaque
(VRAM_ALIAS_OPAQUE), so every index 0-15 is usable.

Usage (from the repo root):

    python3 tools/prepare_sprinter_about.py

Re-running overwrites assets/sprinter/about640.png. Diff it before
committing -- a rerun on a different Pillow could shift colours even with
the same master, and manual retouching would be silently lost (CLAUDE.md's
warning about the other art tools applies verbatim).
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageEnhance

ROOT = Path(__file__).resolve().parent.parent

DEFAULT_MASTER = ROOT / "assets/pc-client/about/about-shatranj.png"
DEFAULT_OUTPUT = ROOT / "assets/sprinter/about640.png"

# Stored size. Width is the physically-square width for a 256-row image in
# mode #82 (see GEOMETRY above); it is also exactly 4 asset pages once
# packed 2 pixels/byte, which is why the packer does not pillarbox on disk.
TARGET_W, TARGET_H = 512, 256
PALETTE_COLORS = 16

# TONE MAPPING, and why it is not optional.
#
# The master is a candle-lit night scene: measured on it, 90% of the pixels
# sit below luminance 30. Quantisers split by POPULATION, so a straight
# 14-colour median cut spent NINE of its entries on tones between luma 0 and
# 13 -- mutually indistinguishable near-blacks -- and left three for
# everything visible. The first MAME run showed the result: a flat brown
# smear with the warm candlelight gone (human tester, 2026-08-17: "потерян
# теплый оттенок, очень много индексов уходит на шум в темных цветах").
#
# The fix is to spend the 14 entries where an eye can use them, by lifting
# the shadows BEFORE quantising and keeping the lifted colours as the final
# palette. Deliberately not "faithful": reproducing nine shades of black
# faithfully is what produced the smear.
#
# The curve is applied to HSV *Value* only. Applying it to R/G/B directly
# raises the near-zero blue channel proportionally hardest, which drags the
# whole picture toward olive-grey -- exactly the lost warmth being fixed.
# Hue and saturation pass through untouched, then a modest saturation boost
# restores the chroma the downscale averaged away.
#
# 1.8/1.35 chosen by eye from a sweep of gamma 1.5-2.6 x saturation 1.0-1.6
# (contact sheets in the 2026-08-17 working notes): enough lift to read the
# faces, the robes and the board, while keeping the intimate darkness that
# is the artwork's whole character. Higher gammas open the shadows further
# but flatten it into a daylit scene.
TONE_GAMMA = 1.8
TONE_SATURATION = 1.35

# FIXED PALETTE CONTRACT (tools/build_sprinter_about.py re-checks it, and
# asm/sprinter/zcc/about_sprinter.asm hardcodes the two indices as its text
# colour byte). The caption the About screen prints over the picture needs a
# colour that is guaranteed readable, and every entry a quantiser picks is
# by definition some colour that is already IN the picture -- picking one of
# those would put light text on whatever happens to be light. So the top two
# entries are reserved instead and the artwork is quantised to the other 14:
#
#   index 14  caption background (black)
#   index 15  caption foreground (warm cream, matching the artwork's title)
#
# Costing the image 2 of 16 entries is a real price; it is paid because a
# version string nobody can read is worth less than two shades of brown.
IMAGE_COLORS = 14
CAPTION_BG_INDEX = 14
CAPTION_FG_INDEX = 15
CAPTION_BG_RGB = (0, 0, 0)
CAPTION_FG_RGB = (0xF0, 0xE0, 0xC0)


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def tone_map(image: Image.Image) -> Image.Image:
    """Lift the shadows via HSV Value, then restore chroma. See the
    TONE_MAPPING note above for why both halves are needed."""
    hue, sat, val = image.convert("HSV").split()
    lut = [min(255, int(round(255 * ((i / 255.0) ** (1.0 / TONE_GAMMA)))))
           for i in range(256)]
    val = val.point(lut)
    out = Image.merge("HSV", (hue, sat, val)).convert("RGB")
    return ImageEnhance.Color(out).enhance(TONE_SATURATION)


def prepare(master: Image.Image) -> Image.Image:
    rgb = master.convert("RGB")
    # LANCZOS, and deliberately non-uniform: see GEOMETRY above.
    scaled = tone_map(rgb.resize((TARGET_W, TARGET_H), Image.Resampling.LANCZOS))
    # No dithering. Measured on this master (2026-08-17): Floyd-Steinberg
    # made the error WORSE at 16 colours (RMSE 10.22 vs 8.63) and the noise
    # is plainly visible in the large dark areas this artwork is mostly
    # made of. Flat quantisation posterises the candle glow instead, which
    # reads as a stylisation rather than as dirt.
    quantized = scaled.quantize(colors=IMAGE_COLORS,
                                 method=Image.Quantize.MEDIANCUT,
                                 dither=Image.Dither.NONE)

    # Pillow sizes the palette to what it used; pad it back out to 16 and
    # append the two reserved caption entries (see the contract above).
    raw = list(quantized.getpalette() or [])
    raw = (raw + [0] * (IMAGE_COLORS * 3))[:IMAGE_COLORS * 3]
    raw += list(CAPTION_BG_RGB) + list(CAPTION_FG_RGB)
    quantized.putpalette(raw)

    highest = max(quantized.tobytes())
    if highest >= IMAGE_COLORS:
        fail(f"quantiser emitted index {highest}, but indices "
             f"{CAPTION_BG_INDEX}/{CAPTION_FG_INDEX} are reserved for the "
             "caption -- the image may only use 0.." f"{IMAGE_COLORS - 1}")
    return quantized


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--master", type=Path, default=DEFAULT_MASTER)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = ap.parse_args()

    if not args.master.is_file():
        fail(f"missing master artwork: {args.master}")

    out = prepare(Image.open(args.master))
    if out.size != (TARGET_W, TARGET_H):
        fail(f"prepared image is {out.size}, expected {(TARGET_W, TARGET_H)}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    out.save(args.output, optimize=True)

    used = len(set(out.tobytes()))
    print(f"[OK] {args.output}: {TARGET_W}x{TARGET_H}, "
          f"{used} of {PALETTE_COLORS} palette entries used")
    print("     Review the diff before committing; a rerun can reshuffle "
          "colours and would discard manual retouching.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
