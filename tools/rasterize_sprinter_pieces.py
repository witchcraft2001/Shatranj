#!/usr/bin/env python3
"""Rasterize the selected Lichess SVG piece sets into committed Sprinter PNGs.

port.md section 4 step A: this is a MANUAL, one-off tool -- it is never part
of the build (tools/build_sprinter_piece_tiles.py, step B, consumes only the
committed PNGs this script writes). Run it once to produce
assets/sprinter/pieces/<set>/{w,b}{K,Q,R,B,N,P}.png; the output is meant to
be hand-edited by an artist afterward and regeneration must never silently
clobber those edits (review via git diff, matching the existing
rasterize_sprinter_pieces.py-adjacent rule for the Next pipeline's asset
tools -- see CLAUDE.md's asset-pipeline note).

Pipeline per piece, mirroring tools/build_next_piece_sprites.py's proven
headless-Chrome technique with two Sprinter-specific differences:

  1. Render the source SVG onto a square canvas via headless Chrome/Edge,
     wrapped in a tiny HTML page that pins the <img> CSS width/height (bare
     SVGs with physical units like mpchess's "10mm", or percentage units
     like totoy's "100%", render at the wrong size or get clipped
     otherwise). Try 256, then 128, then 64 px squares in turn: an opaque
     pixel touching the canvas border means the render clipped, so retry
     smaller (matches the Next pipeline's own documented 64px ceiling for
     mm-unit SVGs).
  2. Box-downscale the *square* render directly to the 32x16 stored cell
     (non-uniform: /8 horizontal, /16 vertical) -- correct, not distorted,
     because Sprinter's mode #82 pixels are visually ~2:1 (width:height),
     so 32 narrow stored columns and 16 taller stored rows depict a square
     source without stretching (port.md section 3.6). Then hard-quantize
     every pixel to the nearest of ALL 4 import quantization targets
     jointly (read from assets/sprinter/palette.json) or full
     transparency -- no anti-aliasing survives the quantization, per
     port.md's "no dithering, hard threshold" rule (section 4 step A.3).
     Those 4 colours bound this IMPORT only: the build accepts a much
     wider palette in the PNGs (tools/build_sprinter_piece_tiles.py's
     PIECE_ALLOWED_INDICES), which is what an artist repainting them
     afterwards works to.

     Quantizing jointly, not restricted to each side's own body/outline
     pair, matters in practice: a source SVG's interior shading strokes
     are almost always dark. For a white piece the dark reference IS its
     "outline" colour, so shading reads as visible interior detail; for a
     black piece the dark reference IS its body colour, so the same
     shading collapses into the flat fill and the piece reads as a
     silhouette with no interior detail at all (found by visual review of
     a MAME screenshot, 2026-08-10).
  3. guarantee_outline then dilates the silhouette's OUTER boundary by 1px
     in the side's own designated outline colour (ported from
     build_next_piece_sprites.py's outline_dark_piece). This still runs
     AFTER the joint quantization above, so it does not touch interior
     detail -- only pixels that were fully transparent and now border the
     silhouette get the rim colour. Two iterations on this same day, for
     the record: dropping the rim entirely (in favour of extending
     whatever interior tone was already at each gap) kept full interior
     detail but made a black piece on a dark board square noticeably hard
     to make out with no defining edge at all -- a visual review of
     assets/sprinter/pieces/*/bB.png against the BROWN theme's dark square
     confirmed it directly. The rim is back for exactly that reason: it
     only defines the boundary, joint quantization still owns everything
     inside it.

Chrome/Edge discovery order: $CHROME or $EDGE env var, common macOS
install paths, common Windows install paths (matching the Next pipeline's
own list), then whatever's on PATH under common Linux binary names.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import gen_sprinter_palette as gsp  # noqa: E402

SVG_ROOT = ROOT / "assets/lichess/piece"
SELECTED_SETS_JSON = ROOT / "assets/lichess/selected_next_sets.json"
DEFAULT_PALETTE = ROOT / "assets/sprinter/palette.json"
DEFAULT_PIECES_OUT = ROOT / "assets/sprinter/pieces"
DEFAULT_PREVIEW_OUT = ROOT / "build/sprinter/preview/pieces_raster.png"

PIECE_KINDS = ["K", "Q", "R", "B", "N", "P"]
SIDES = ["w", "b"]

TILE_W, TILE_H = 32, 16
RENDER_SIZE_LADDER = (256, 128, 64)
ALPHA_THRESHOLD = 128
CLIP_ALPHA_THRESHOLD = 40   # lower bar: catch faint AA fringes at the border
MARGIN_FRAC = 0.08          # fraction of the square canvas reserved as margin

BROWSER_CANDIDATES_MACOS = [
    Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    Path("/Applications/Chromium.app/Contents/MacOS/Chromium"),
    Path("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
]
BROWSER_CANDIDATES_WINDOWS = [
    Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
    Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
    Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
]
BROWSER_NAMES_LINUX = [
    "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
    "microsoft-edge",
]


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def find_browser(env: dict | None = None) -> Path:
    import shutil

    env = env if env is not None else os.environ
    for var in ("CHROME", "EDGE"):
        value = env.get(var)
        if value:
            path = Path(value)
            if path.exists():
                return path
    for candidate in BROWSER_CANDIDATES_MACOS + BROWSER_CANDIDATES_WINDOWS:
        if candidate.exists():
            return candidate
    for name in BROWSER_NAMES_LINUX:
        found = shutil.which(name)
        if found:
            return Path(found)
    raise SystemExit(
        "Error: no headless-capable Chrome/Chromium/Edge found; set "
        "$CHROME or $EDGE to a browser binary path"
    )


def file_uri(path: Path) -> str:
    return path.resolve().as_uri()


def detect_border_clip(image: Image.Image, alpha_threshold: int = CLIP_ALPHA_THRESHOLD) -> bool:
    """True if any pixel on the 1px border ring has meaningful alpha -- the
    render likely got cropped by the screenshot window."""
    w, h = image.size
    alpha = image.getchannel("A")
    px = alpha.load()
    for x in range(w):
        if px[x, 0] >= alpha_threshold or px[x, h - 1] >= alpha_threshold:
            return True
    for y in range(h):
        if px[0, y] >= alpha_threshold or px[w - 1, y] >= alpha_threshold:
            return True
    return False


def fit_to_square(image: Image.Image, size: int, margin_frac: float = MARGIN_FRAC) -> Image.Image:
    """Alpha-bbox crop, uniform scale to fit within (1 - 2*margin_frac) of a
    size x size square, centred. Returns a fully transparent square if the
    source has no opaque pixels."""
    alpha = image.getchannel("A")
    bbox = alpha.getbbox()
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if bbox is None:
        return canvas
    crop = image.crop(bbox)
    draw_size = size * (1.0 - 2 * margin_frac)
    scale = min(draw_size / crop.width, draw_size / crop.height)
    target = (max(1, round(crop.width * scale)), max(1, round(crop.height * scale)))
    resized = crop.resize(target, Image.Resampling.LANCZOS)
    canvas.paste(resized, ((size - target[0]) // 2, (size - target[1]) // 2))
    return canvas


def _nearest(rgb: tuple[int, int, int], candidates: list[tuple[int, int, int]]) -> tuple[int, int, int]:
    best = candidates[0]
    best_d = None
    for c in candidates:
        d = sum((a - b) ** 2 for a, b in zip(rgb, c))
        if best_d is None or d < best_d:
            best_d, best = d, c
    return best


def hard_quantize(image: Image.Image, candidates: list[tuple[int, int, int]],
                   alpha_threshold: int = ALPHA_THRESHOLD) -> Image.Image:
    """Every opaque pixel becomes exactly the nearest of `candidates`; every
    pixel below alpha_threshold becomes fully transparent -- no anti-
    aliasing, no intermediate tones (port.md section 4 step A.3: 'hard
    quantization to the nearest of the 4 [piece] colours ... or
    transparency, no dithering'). `candidates` is deliberately generic
    (not "body, outline"): process_piece passes all 4 piece reference
    colours jointly, not a side-restricted pair -- see the module
    docstring for why the restricted version lost interior detail on one
    side."""
    src = image.load()
    w, h = image.size
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    dst = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = src[x, y]
            if a < alpha_threshold:
                continue
            dst[x, y] = _nearest((r, g, b), candidates) + (255,)
    return out


def guarantee_outline(image: Image.Image, outline_rgb: tuple[int, int, int]) -> Image.Image:
    """Dilate the opaque silhouette by 1px in outline_rgb: any transparent
    pixel touching an opaque one becomes an opaque outline pixel. Guards
    against a thin source stroke box-filtering away to nothing at 32x16,
    and -- since process_piece now quantizes the interior jointly across
    all 4 piece colours first -- also guarantees a defining boundary
    against the board square regardless of how dark or light a piece's
    interior colours land (ported from tools/build_next_piece_sprites.py's
    outline_dark_piece; applied unconditionally, as the goal is silhouette
    definition against ANY board square colour, not dark-on-dark
    contrast)."""
    w, h = image.size
    src = image.load()
    to_paint = []
    for y in range(h):
        for x in range(w):
            if src[x, y][3] != 0:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and src[nx, ny][3] != 0:
                    to_paint.append((x, y))
                    break
    out = image.copy()
    dst = out.load()
    for x, y in to_paint:
        dst[x, y] = outline_rgb + (255,)
    return out


def render_svg_square(browser: Path, svg: Path, tmpdir: Path,
                       sizes: tuple[int, ...] = RENDER_SIZE_LADDER) -> tuple[Image.Image, int]:
    """Render svg onto a square canvas, retrying at smaller sizes if the
    result clips against the border. Returns (image, size_used)."""
    last_image = None
    for size in sizes:
        out = tmpdir / f"{svg.parent.name}_{svg.stem}_{size}.png"
        if out.exists():
            out.unlink()
        page = tmpdir / f"{svg.parent.name}_{svg.stem}_{size}.html"
        page.write_text(
            "<!doctype html><style>*{margin:0;padding:0}img{display:block;"
            f"width:{size}px;height:{size}px}}</style>"
            f'<img src="{file_uri(svg)}">',
            encoding="utf-8",
        )
        profile = tmpdir / f"profile_{size}"
        cmd = [
            str(browser),
            "--headless=new",
            "--disable-gpu",
            "--disable-breakpad",
            "--disable-crash-reporter",
            "--no-first-run",
            "--no-sandbox",
            f"--user-data-dir={profile}",
            "--default-background-color=00000000",
            f"--screenshot={out}",
            f"--window-size={size},{size}",
            file_uri(page),
        ]
        # subprocess.run() here would block until Chrome's process fully
        # exits -- on this machine "--headless=new" reliably writes the
        # screenshot but then hangs around (a GPU-helper shutdown quirk,
        # not a rendering problem), so wait for the *file* instead and
        # terminate the process explicitly once it's there.
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 15.0
        while not out.exists() and time.monotonic() < deadline:
            if proc.poll() is not None:
                break
            time.sleep(0.05)
        if not out.exists():
            proc.kill()
            proc.wait(timeout=5)
            fail(f"browser did not render {svg} at {size}px")
        time.sleep(0.2)  # let the PNG write finish flushing before killing
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        image = Image.open(out).convert("RGBA")
        if image.getchannel("A").getbbox() is None:
            fail(f"{svg}: rendered fully transparent at every tried size")
        last_image = image
        if not detect_border_clip(image):
            return image, size
    fail(
        f"{svg}: still clips against the render border at the smallest "
        f"tried size ({sizes[-1]}px) -- pure-Python SVG rasterization is "
        "not an acceptable fallback (port.md section 4 fidelity rule); "
        "needs a human decision"
    )
    assert last_image is not None  # unreachable, fail() raises


# The colours an imported SVG is quantized DOWN to. This is an import
# baseline, not the rule for finished art: the build's gate
# (tools/build_sprinter_piece_tiles.py's PIECE_ALLOWED_INDICES) accepts a
# far wider set, so the artist who picks these PNGs up afterwards may
# repaint them with any palette entry that is not a precompose background.
# Kept narrow HERE on purpose -- an automatic quantizer handed the HUD
# colours would scatter them through the shading of every piece.
# assets/sprinter/palette.json carries the same list under
# "piece_import_quantize_indices".
PIECE_QUANTIZE_INDICES = (4, 5, 6, 7)


def reference_colors(palette: dict, side: str) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    """This side's own two designated palette entries (still a fact about
    the palette's layout -- indices 4/5 are named "white_*", 6/7 "black_*"
    -- even though process_piece no longer restricts quantization to only
    these two; see all_piece_reference_colors."""
    by_index = {e["index"]: e["rgb"] for e in palette["base"]}
    body_idx, outline_idx = (4, 5) if side == "w" else (6, 7)
    body = gsp._parse_rgb(by_index[body_idx], "piece body")
    outline = gsp._parse_rgb(by_index[outline_idx], "piece outline")
    return body, outline


def all_piece_reference_colors(palette: dict) -> list[tuple[int, int, int]]:
    """All 4 import quantization targets (palette indices 4-7), for JOINT
    quantization -- port.md section 4 step A.3's actual rule. The build's
    validator accepts them regardless of a piece's side (and a good deal
    more besides -- see the comment on PIECE_QUANTIZE_INDICES), so no
    downstream change was needed to support quantizing jointly."""
    by_index = {e["index"]: e["rgb"] for e in palette["base"]}
    return [
        gsp._parse_rgb(by_index[i], "piece reference") for i in PIECE_QUANTIZE_INDICES
    ]


def process_piece(browser: Path, svg: Path, side: str, palette: dict, tmpdir: Path) -> Image.Image:
    square, used_size = render_svg_square(browser, svg, tmpdir)
    fitted = fit_to_square(square, used_size)
    downscaled = fitted.resize((TILE_W, TILE_H), Image.Resampling.BOX)
    candidates = all_piece_reference_colors(palette)
    quantized = hard_quantize(downscaled, candidates)
    _, outline = reference_colors(palette, side)
    return guarantee_outline(quantized, outline)


def load_selected_sets(path: Path, override: list[str] | None) -> list[str]:
    if override:
        return override
    data = json.loads(path.read_text(encoding="utf-8"))
    return list(data.get("selected", []))


def aspect_corrected(image: Image.Image, scale: int = 6) -> Image.Image:
    """Nearest-neighbour upscale for human preview, plus the extra 2x
    vertical stretch that corrects for mode #82's ~2:1 stored pixel
    aspect -- without it a preview of the raw 32x16 raster looks squashed
    even though it displays as a normal proportioned piece on hardware."""
    w, h = image.size
    stage = image.resize((w * scale, h * scale), Image.Resampling.NEAREST)
    return stage.resize((w * scale, h * scale * 2), Image.Resampling.NEAREST)


def build_preview(tiles: dict[str, dict[str, Image.Image]], out_path: Path) -> None:
    sets = list(tiles.keys())
    order = [f"{side}{kind}" for side in SIDES for kind in PIECE_KINDS]
    cell_w, cell_h = TILE_W * 6, TILE_H * 6 * 2
    pad = 4
    checker = Image.new("RGBA", (cell_w, cell_h), (0, 0, 0, 0))
    for y in range(0, cell_h, 8):
        for x in range(0, cell_w, 8):
            if ((x // 8) + (y // 8)) % 2 == 0:
                for yy in range(y, min(y + 8, cell_h)):
                    for xx in range(x, min(x + 8, cell_w)):
                        checker.putpixel((xx, yy), (60, 60, 60, 255))
            else:
                for yy in range(y, min(y + 8, cell_h)):
                    for xx in range(x, min(x + 8, cell_w)):
                        checker.putpixel((xx, yy), (90, 90, 90, 255))

    grid = Image.new(
        "RGBA",
        (len(order) * (cell_w + pad) + pad, len(sets) * (cell_h + pad) + pad),
        (20, 20, 20, 255),
    )
    for row, set_name in enumerate(sets):
        for col, key in enumerate(order):
            cell = checker.copy()
            piece_img = aspect_corrected(tiles[set_name][key])
            cell.alpha_composite(piece_img)
            x = pad + col * (cell_w + pad)
            y = pad + row * (cell_h + pad)
            grid.paste(cell, (x, y))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    grid.convert("RGB").save(out_path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pieces-out", type=Path, default=DEFAULT_PIECES_OUT)
    parser.add_argument("--palette", type=Path, default=DEFAULT_PALETTE)
    parser.add_argument("--sets", nargs="+", default=None,
                        help="override the set list (default: "
                             "assets/lichess/selected_next_sets.json)")
    parser.add_argument("--browser", type=Path, default=None)
    parser.add_argument("--preview-out", type=Path, default=DEFAULT_PREVIEW_OUT)
    args = parser.parse_args()

    palette = gsp.load_palette_file(args.palette)
    errors = gsp.validate_palette(palette)
    if errors:
        fail(f"{args.palette} is invalid: " + "; ".join(errors))

    sets = load_selected_sets(SELECTED_SETS_JSON, args.sets)
    if not sets:
        fail(f"no sets selected ({SELECTED_SETS_JSON} or --sets)")

    browser = args.browser or find_browser()
    print(f"[..] using browser: {browser}")

    tiles: dict[str, dict[str, Image.Image]] = {}
    with tempfile.TemporaryDirectory(prefix="sprinter-piece-raster-") as tmp:
        tmpdir = Path(tmp)
        for set_name in sets:
            set_dir = SVG_ROOT / set_name
            if not set_dir.is_dir():
                fail(f"missing SVG set dir: {set_dir}")
            out_dir = args.pieces_out / set_name
            out_dir.mkdir(parents=True, exist_ok=True)
            tiles[set_name] = {}
            for side in SIDES:
                for kind in PIECE_KINDS:
                    key = f"{side}{kind}"
                    svg = set_dir / f"{key}.svg"
                    if not svg.is_file():
                        fail(f"missing SVG: {svg}")
                    image = process_piece(browser, svg, side, palette, tmpdir)
                    tiles[set_name][key] = image
                    out_path = out_dir / f"{key}.png"
                    image.save(out_path)
                    print(f"[OK] {out_path}")

    build_preview(tiles, args.preview_out)
    print(f"[OK] {args.preview_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
