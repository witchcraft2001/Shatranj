#!/usr/bin/env python3
"""Prepare the real Sprinter logo for the S4 banner asset.

Manual, one-off tool (never part of the build, mirroring
tools/rasterize_sprinter_pieces.py): reads the real logo screenshot the
user provided, committed as-is for provenance at
assets/sprinter/source/sprinter_logo_source.png (black background, white
"Sprinter" wordmark, a blue accent stroke), and writes the build-ready
assets/sprinter/logo_sprinter.png -- background keyed to full transparency,
every remaining pixel hard-quantized to exactly one of two existing
palette colours (index 1 "text", index 14 "accent" -- no new palette
entries needed; see assets/sprinter/palette.json), sized for mode #82's
banner band (port.md section 3.4, y 0..15).

Sizing: the source is ~198x37 (aspect ~5.35:1). Sprinter's mode #82 pixels
are visually about half as wide as they are tall -- the same ratio that
makes a 32x16 stored piece tile look square on screen (port.md section
3.6) -- so at a fixed 16-row banner height the stored width has to be
roughly DOUBLE what a naive same-aspect resize would give, or the wordmark
comes out squashed. compute_target_width derives that width from the
source's own aspect ratio instead of hard-coding a guess (port.md's
original "~64x16" estimate in section 3.4 predates having the real asset
and undershoots badly once the geometry is worked out).
"""

from __future__ import annotations

import argparse
import colorsys
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import gen_sprinter_palette as gsp  # noqa: E402

DEFAULT_SOURCE = ROOT / "assets/sprinter/source/sprinter_logo_source.png"
DEFAULT_OUT = ROOT / "assets/sprinter/logo_sprinter.png"
DEFAULT_PALETTE = ROOT / "assets/sprinter/palette.json"
DEFAULT_PREVIEW_OUT = ROOT / "build/sprinter/preview/logo_sprinter_preview.png"

TARGET_H = 16
KEY_THRESHOLD = 40      # max(R,G,B) below this = background, not logo ink
ALPHA_THRESHOLD = 128
# Same stored-pixel-aspect constant the piece pipeline relies on implicitly
# via its 32(w) x 16(h) cell (32 * PIXEL_ASPECT_W == 16, i.e. a square
# source stays visually square): each stored horizontal pixel covers about
# half the visual width of a stored vertical one.
PIXEL_ASPECT_W = 0.5


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def background_key_alpha(image: Image.Image, threshold: int = KEY_THRESHOLD) -> Image.Image:
    """Any pixel with max(R,G,B) < threshold becomes fully transparent
    (the source's black background); everything else keeps its RGB at
    full opacity.

    An RGBA source is composited onto black first, so an already-
    transparent pixel keys out no matter what RGB sits underneath it
    (dropping the alpha channel instead would let a transparent-but-white
    pixel read as ink). For the committed source -- fully opaque, black
    background -- the two paths agree byte for byte.

    Note the threshold is a brightness cut, not a colour one: a dark but
    saturated anti-aliasing pixel at the accent stroke's edge survives it
    and is later quantized to the full-brightness accent. Raising the
    threshold trims those fringes at the cost of thinning the stroke;
    KEY_THRESHOLD is the knob, and any change must be reviewed on the
    regenerated PNG (git diff) before it is committed."""
    if image.mode == "RGBA":
        rgb = Image.new("RGB", image.size, (0, 0, 0))
        rgb.paste(image, (0, 0), image)
    else:
        rgb = image.convert("RGB")
    w, h = rgb.size
    src = rgb.load()
    out = Image.new("RGBA", (w, h))
    dst = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b = src[x, y]
            dst[x, y] = (0, 0, 0, 0) if max(r, g, b) < threshold else (r, g, b, 255)
    return out


def compute_target_width(src_w: int, src_h: int, target_h: int,
                          pixel_aspect_w: float = PIXEL_ASPECT_W) -> int:
    visual_aspect = src_w / src_h
    stored_w = visual_aspect * target_h / pixel_aspect_w
    stored_w = int(round(stored_w / 2.0)) * 2  # even width (4bpp: 2px/byte)
    return max(2, stored_w)


GRAY_SATURATION_THRESHOLD = 0.25


def _hsv(rgb: tuple[int, int, int]) -> tuple[float, float, float]:
    return colorsys.rgb_to_hsv(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255)


def classify_pixel(rgb: tuple[int, int, int], color_a: tuple[int, int, int],
                    color_b: tuple[int, int, int],
                    gray_saturation_threshold: float = GRAY_SATURATION_THRESHOLD
                    ) -> tuple[int, int, int]:
    """Nearest-reference classification by hue/saturation, not raw RGB
    distance. Raw Euclidean distance is a poor fit when the two references
    have very different overall magnitude (e.g. a near-white text colour
    vs. a saturated blue accent with a zero red channel): a dark, low-
    saturation anti-aliasing blend pixel near a white letter's edge can
    end up numerically closer to the low-magnitude blue than to white,
    even though it is visibly grey, not blue. Instead: low-saturation
    pixels always match whichever reference is itself the more achromatic
    one (assumed to be exactly one of the two, true for text-vs-accent
    here); only a genuinely saturated pixel can match a saturated
    reference.

    With exactly one saturated reference -- this logo's case -- the hue
    comparison below does not discriminate: any pixel above the saturation
    threshold goes to the saturated reference whatever its hue, because the
    achromatic one scores the worst possible distance. That is the intended
    rule for a two-colour wordmark ("not grey" means "accent"); the hue term
    only starts deciding anything if a future asset carries two saturated
    references."""
    h, s, _v = _hsv(rgb)
    ha, sa, _ = _hsv(color_a)
    hb, sb, _ = _hsv(color_b)

    def hue_dist(x: float, y: float) -> float:
        d = abs(x - y)
        return min(d, 1 - d)

    if s < gray_saturation_threshold:
        return color_a if sa <= sb else color_b
    da = hue_dist(h, ha) if sa >= gray_saturation_threshold else 1.0
    db = hue_dist(h, hb) if sb >= gray_saturation_threshold else 1.0
    return color_a if da <= db else color_b


def hard_quantize_two(image: Image.Image, color_a: tuple[int, int, int],
                       color_b: tuple[int, int, int],
                       alpha_threshold: int = ALPHA_THRESHOLD) -> Image.Image:
    w, h = image.size
    src = image.load()
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    dst = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = src[x, y]
            if a < alpha_threshold:
                continue
            dst[x, y] = classify_pixel((r, g, b), color_a, color_b) + (255,)
    return out


def hard_quantize_two_paired(image: Image.Image, color_a: tuple[int, int, int],
                              color_b: tuple[int, int, int],
                              alpha_threshold: int = ALPHA_THRESHOLD) -> Image.Image:
    """Like hard_quantize_two, but decides opacity per 2-pixel byte-pair
    (both transparent or both opaque) instead of per pixel: the packed
    4bpp keyed format this asset feeds (tools/build_sprinter_ui_assets.py)
    cannot represent a byte half transparent, half opaque -- the hardware
    key skips whole bytes only. A pair counts opaque if EITHER source
    pixel does (favours keeping thin letterforms over losing them); each
    opaque pixel still gets its own independent colour classification."""
    w, h = image.size
    if w % 2 != 0:
        fail(f"hard_quantize_two_paired: width {w} is odd")
    src = image.load()
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    dst = out.load()
    for y in range(h):
        for bx in range(w // 2):
            x0, x1 = 2 * bx, 2 * bx + 1
            r0, g0, b0, a0 = src[x0, y]
            r1, g1, b1, a1 = src[x1, y]
            if max(a0, a1) < alpha_threshold:
                continue
            dst[x0, y] = classify_pixel((r0, g0, b0), color_a, color_b) + (255,)
            dst[x1, y] = classify_pixel((r1, g1, b1), color_a, color_b) + (255,)
    return out


def prepare_logo(source: Image.Image, palette: dict, target_h: int = TARGET_H,
                  target_w: int | None = None) -> Image.Image:
    by_index = {e["index"]: e["rgb"] for e in palette["base"]}
    text_rgb = gsp._parse_rgb(by_index[1], "text")
    accent_rgb = gsp._parse_rgb(by_index[14], "accent")

    keyed = background_key_alpha(source)
    bbox = keyed.getchannel("A").getbbox()
    if bbox is None:
        fail("source logo has no non-background (non-black) pixels")
    cropped = keyed.crop(bbox)

    if target_w is None:
        target_w = compute_target_width(cropped.width, cropped.height, target_h)
    elif target_w % 2 != 0:
        fail(f"--width {target_w} must be even (4bpp: 2 pixels/byte)")

    resized = cropped.resize((target_w, target_h), Image.Resampling.LANCZOS)
    return hard_quantize_two_paired(resized, text_rgb, accent_rgb)


def aspect_corrected(image: Image.Image, scale: int = 6) -> Image.Image:
    w, h = image.size
    stage = image.resize((w * scale, h * scale), Image.Resampling.NEAREST)
    return stage.resize((w * scale, h * scale * 2), Image.Resampling.NEAREST)


def build_preview(logo: Image.Image, out_path: Path) -> None:
    big = aspect_corrected(logo)
    canvas = Image.new("RGB", big.size, (30, 30, 30))
    canvas.paste(big, (0, 0), big)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out_path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--palette", type=Path, default=DEFAULT_PALETTE)
    parser.add_argument("--height", type=int, default=TARGET_H)
    parser.add_argument("--width", type=int, default=None,
                        help="override the derived stored width (must be even)")
    parser.add_argument("--preview-out", type=Path, default=DEFAULT_PREVIEW_OUT)
    args = parser.parse_args()

    if not args.source.is_file():
        fail(f"missing source logo: {args.source}")

    palette = gsp.load_palette_file(args.palette)
    errors = gsp.validate_palette(palette)
    if errors:
        fail(f"{args.palette} is invalid: " + "; ".join(errors))

    source = Image.open(args.source).convert("RGBA")
    logo = prepare_logo(source, palette, args.height, args.width)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    logo.save(args.out)
    print(f"[OK] {args.out}: {logo.width}x{logo.height}")

    build_preview(logo, args.preview_out)
    print(f"[OK] {args.preview_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
