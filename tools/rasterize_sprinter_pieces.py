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
  2. Classify the square render's source tones into semantic palette
     indices 4-7 BEFORE reducing it, using the set and side. Independently
     box-filter alpha coverage and each colour mask to the 32x16 stored
     cell; require at least 50% alpha and select the colour with the most
     coverage (dark lines win ties). This keeps thin lines and distinct
     fills from averaging into colours that do not exist in the palette.
     Mode #82 pixels are visually about 2:1 (width:height), so the stored
     32x16 cell depicts a square source without stretching (port.md §3.6).
     The import's four colours are only a starting point: the packer accepts
     a wider artist palette (PIECE_ALLOWED_INDICES in
     tools/build_sprinter_piece_tiles.py).
  3. For black pieces only, guarantee_outline adds a light rim on exterior
     transparent pixels. Flood-fill from the canvas edges excludes internal
     holes; existing opaque pixels are preserved, and additions that bridge
     components or seal open passages are rejected. White SVG contours are
     left intact so they do not become thicker.

Chrome/Edge discovery order: $CHROME or $EDGE env var, common macOS
install paths, common Windows install paths (matching the Next pipeline's
own list), then whatever's on PATH under common Linux binary names.
"""

from __future__ import annotations

import argparse
import heapq
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
ALPHA_THRESHOLD = 255 / 2  # exactly 50% coverage, including float masks
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


def fit_to_square(image: Image.Image, size: int, margin_frac: float = MARGIN_FRAC,
                  bbox: tuple[int, int, int, int] | None = None) -> Image.Image:
    """Alpha-bbox crop, uniform scale to fit within (1 - 2*margin_frac) of a
    size x size square, centred. Returns a fully transparent square if the
    source has no opaque pixels. For semantic masks, supply the shared
    source-alpha bbox so each colour receives the same transform."""
    if bbox is None:
        bbox = (image.getchannel("A") if image.mode == "RGBA" else image).getbbox()
    canvas = Image.new(image.mode, (size, size), 0)
    if bbox is None:
        return canvas
    crop = image.crop(bbox)
    draw_size = size * (1.0 - 2 * margin_frac)
    scale = min(draw_size / crop.width, draw_size / crop.height)
    target = (max(1, round(crop.width * scale)), max(1, round(crop.height * scale)))
    resized = crop.resize(target, Image.Resampling.BOX)
    canvas.paste(resized, ((size - target[0]) // 2, (size - target[1]) // 2))
    return canvas


def guarantee_outline(image: Image.Image, outline_rgb: tuple[int, int, int]) -> Image.Image:
    """Add an outer rim to black pieces without filling internal holes.

    Only transparency connected to the canvas edge is eligible. Existing
    opaque pixels are immutable. Added pixels may not join two disconnected
    silhouette parts or seal an open transparent passage.
    """
    w, h = image.size
    src = image.load()
    exterior = _exterior_transparency(image)
    labels, component_count = _opaque_components(image)
    directions = ((1, 0), (0, 1), (1, 1), (1, -1))
    neighbours8 = directions + tuple((-dx, -dy) for dx, dy in directions)
    candidates = {}
    for y in range(h):
        for x in range(w):
            if src[x, y][3] != 0 or not exterior[y][x]:
                continue
            owners = {labels[y + dy][x + dx] for dx, dy in neighbours8
                      if 0 <= x + dx < w and 0 <= y + dy < h
                      and labels[y + dy][x + dx] >= 0}
            if len(owners) != 1:
                continue
            # Keep one- and two-pixel channels open, including slanted
            # bishop cuts. Adjacent (rather than opposing) neighbours are
            # corners of the same edge and DO need a continuous rim.
            narrow_gap = False
            for dx, dy in directions:
                distances = []
                for sign in (-1, 1):
                    hit = None
                    for distance in (1, 2):
                        nx, ny = x + sign * dx * distance, y + sign * dy * distance
                        if 0 <= nx < w and 0 <= ny < h and src[nx, ny][3]:
                            hit = distance
                            break
                    distances.append(hit)
                if all(d is not None for d in distances) and sum(distances) <= 3:
                    narrow_gap = True
                    break
            if not narrow_gap:
                candidates[x, y] = next(iter(owners))
    # Two individually eligible rim pixels must not join separate parts.
    # Reject both sides of such a conflict, avoiding scan-order bias.
    conflicts = {(x, y) for (x, y), owner in candidates.items()
                 if any(candidates.get((x + dx, y + dy), owner) != owner
                        for dx, dy in neighbours8)}
    out = image.copy()
    dst = out.load()
    for x, y in candidates:
        if (x, y) not in conflicts:
            dst[x, y] = outline_rgb + (255,)
    # Apply the whole rim first, then reopen any passage it sealed. Testing
    # each pixel in scan order rejects useful corners because a temporary
    # hole can disappear again when the next rim pixel is painted.
    # Shortest paths through ORIGINAL exterior transparency remove the
    # fewest added pixels; original opaque art is never on these paths.
    distance, previous, queue = {}, {}, []
    for y in range(h):
        for x in range(w):
            if exterior[y][x] and (x in (0, w - 1) or y in (0, h - 1)):
                cost = int(dst[x, y][3] != 0)
                distance[x, y] = cost
                heapq.heappush(queue, (cost, x, y))
    while queue:
        cost, x, y = heapq.heappop(queue)
        if cost != distance[x, y]:
            continue
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if not (0 <= nx < w and 0 <= ny < h and exterior[ny][nx]):
                continue
            new_cost = cost + int(dst[nx, ny][3] != 0)
            if new_cost < distance.get((nx, ny), float("inf")):
                distance[nx, ny] = new_cost
                previous[nx, ny] = (x, y)
                heapq.heappush(queue, (new_cost, nx, ny))
    remaining_exterior = _exterior_transparency(out)
    for y in range(h):
        for x in range(w):
            if exterior[y][x] and not dst[x, y][3] and not remaining_exterior[y][x]:
                point = (x, y)
                while point is not None:
                    dst[point] = (0, 0, 0, 0)
                    point = previous.get(point)
                remaining_exterior = _exterior_transparency(out)
    assert _opaque_components(out)[1] == component_count
    return out


def _exterior_transparency(image: Image.Image) -> list[list[bool]]:
    w, h = image.size
    px = image.load()
    seen = [[False] * w for _ in range(h)]
    stack = [(x, 0) for x in range(w)] + [(x, h - 1) for x in range(w)]
    stack += [(0, y) for y in range(h)] + [(w - 1, y) for y in range(h)]
    while stack:
        x, y = stack.pop()
        if seen[y][x] or px[x, y][3] != 0:
            continue
        seen[y][x] = True
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx]:
                stack.append((nx, ny))
    return seen


def _opaque_components(image: Image.Image) -> tuple[list[list[int]], int]:
    w, h = image.size
    px = image.load()
    labels = [[-1] * w for _ in range(h)]
    count = 0
    for y in range(h):
        for x in range(w):
            if px[x, y][3] == 0 or labels[y][x] >= 0:
                continue
            labels[y][x] = count
            stack = [(x, y)]
            while stack:
                cx, cy = stack.pop()
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1),
                               (cx + 1, cy + 1), (cx + 1, cy - 1),
                               (cx - 1, cy + 1), (cx - 1, cy - 1)):
                    if (0 <= nx < w and 0 <= ny < h and labels[ny][nx] < 0
                            and px[nx, ny][3] != 0):
                        labels[ny][nx] = count
                        stack.append((nx, ny))
            count += 1
    return labels, count


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


def piece_palette(palette: dict, set_name: str) -> dict[int, tuple[int, int, int]]:
    """Return the selected set's import colors by palette index."""
    by_name = {entry["name"]: entry for entry in palette["piece_sets"]}
    if set_name not in by_name:
        fail(f"no piece palette for set {set_name!r}")
    return {int(index): gsp._parse_rgb(rgb, f"{set_name} piece palette")
            for index, rgb in by_name[set_name]["entries"].items()}


def source_index(rgb: tuple[int, int, int], set_name: str, side: str) -> int:
    """Classify a source SVG pixel before downsampling, preserving regions."""
    luminance = (299 * rgb[0] + 587 * rgb[1] + 114 * rgb[2]) // 1000
    if side == "w":
        if luminance <= 80:
            return 5
        return 4 if luminance >= 235 else 7
    if set_name == "mpchess":
        if luminance <= 55:
            return 5
        return 7 if luminance >= 190 else 6
    if luminance <= 44:
        return 5
    # California uses #4d4d4d fill and CSS gray (#808080) highlights.
    # Keep those highlights distinct; the king gem #666 stays medium.
    fill_ceiling = 110 if set_name == "california" else 160
    return 6 if luminance <= fill_ceiling else 7


def classify_and_downscale(image: Image.Image, set_name: str, side: str,
                           palette: dict, fit_size: int | None = None) -> Image.Image:
    """Classify before fitting and reduce each colour coverage independently.

    Alpha and each classified colour are box-filtered separately. An output
    pixel must have at least 50% alpha coverage; ties go to the dark line.
    Float masks avoid byte rounding introducing false coverage ties.
    """
    w, h = image.size
    src = image.load()
    classes = PIECE_QUANTIZE_INDICES
    masks = {index: Image.new("F", (w, h), 0) for index in classes}
    mask_px = {index: masks[index].load() for index in classes}
    alpha = image.getchannel("A").convert("F")
    for y in range(h):
        for x in range(w):
            r, g, b, a = src[x, y]
            if a:
                index = source_index((r, g, b), set_name, side)
                mask_px[index][x, y] = a
    # Classify BEFORE the bbox fit as well: fitting RGB with a smooth
    # filter would invent a gray fill where black strokes meet white.
    if fit_size is not None:
        bbox = image.getchannel("A").getbbox()
        if bbox is not None:
            alpha = fit_to_square(alpha, fit_size, bbox=bbox)
            masks = {index: fit_to_square(mask, fit_size, bbox=bbox)
                     for index, mask in masks.items()}
    alpha_small = alpha.resize((TILE_W, TILE_H), Image.Resampling.BOX)
    covers = {index: masks[index].resize((TILE_W, TILE_H), Image.Resampling.BOX)
              for index in classes}
    refs = piece_palette(palette, set_name)
    out = Image.new("RGBA", (TILE_W, TILE_H), (0, 0, 0, 0))
    dst = out.load()
    for y in range(TILE_H):
        for x in range(TILE_W):
            if alpha_small.getpixel((x, y)) < ALPHA_THRESHOLD:
                continue
            # Stable priority at equal coverage: dark strokes, body, then
            # medium and light detail.
            index = max((5, 4, 6, 7), key=lambda i: (covers[i].getpixel((x, y)), i == 5))
            dst[x, y] = refs[index] + (255,)
    return out


def process_piece(browser: Path, svg: Path, set_name: str, side: str,
                  palette: dict, tmpdir: Path) -> Image.Image:
    square, used_size = render_svg_square(browser, svg, tmpdir)
    quantized = classify_and_downscale(square, set_name, side, palette, fit_size=used_size)
    if side == "b":
        outline = piece_palette(palette, set_name)[7]
        return guarantee_outline(quantized, outline)
    return quantized


def load_selected_sets(path: Path, override: list[str] | None) -> list[str]:
    if override:
        return override
    data = json.loads(path.read_text(encoding="utf-8"))
    return list(data.get("selected", []))


def build_preview(tiles: dict[str, dict[str, Image.Image]], palette: dict,
                  out_path: Path) -> None:
    order = [f"{side}{kind}" for side in SIDES for kind in PIECE_KINDS]
    # Centre the unscaled 32x16 tile in its real 48x24 mode-82 square and
    # correct the pixel aspect ratio vertically by 2x.
    cell_w, stored_h = 48, 24
    row_h = stored_h * 2
    pad, label_w = 6, 112
    themes = palette["themes"]
    flash = next(entry["rgb"] for entry in palette["base"] if entry["index"] == 8)
    rows = [(set_name, theme["name"] + " " + tone, theme["entries"][index])
            for set_name in tiles for theme in themes
            for index, tone in (("2", "light"), ("3", "dark"))]
    rows += [(set_name, "FLASH", flash) for set_name in tiles]

    def render_sheet(zoom: int, path: Path) -> None:
        cw, rh = cell_w * zoom, row_h * zoom
        grid = Image.new("RGB", (label_w + len(order) * (cw + pad) + pad,
                                  len(rows) * (rh + pad) + pad), (24, 24, 24))
        from PIL import ImageDraw
        draw = ImageDraw.Draw(grid)
        for row, (set_name, theme_name, background) in enumerate(rows):
            y = pad + row * (rh + pad)
            draw.text((pad, y + 4, ), f"{set_name}\n{theme_name}", fill=(230, 230, 230), spacing=2)
            bg = gsp._parse_rgb(background, "preview square")
            for col, key in enumerate(order):
                cell = Image.new("RGBA", (cell_w, stored_h), bg + (255,))
                cell.alpha_composite(tiles[set_name][key], dest=(8, 4))
                # Double height for the physical pixel aspect ratio.
                cell = cell.resize((cell_w, row_h), Image.Resampling.NEAREST)
                if zoom != 1:
                    cell = cell.resize((cw, rh), Image.Resampling.NEAREST)
                x = label_w + pad + col * (cw + pad)
                grid.paste(cell.convert("RGB"), (x, y))
        grid.save(path)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    render_sheet(1, out_path)
    zoom_path = out_path.with_name(out_path.stem + "_zoom" + out_path.suffix)
    render_sheet(4, zoom_path)


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
                    image = process_piece(browser, svg, set_name, side, palette, tmpdir)
                    tiles[set_name][key] = image
                    out_path = out_dir / f"{key}.png"
                    image.save(out_path)
                    print(f"[OK] {out_path}")

    build_preview(tiles, palette, args.preview_out)
    print(f"[OK] {args.preview_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
