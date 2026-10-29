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

Pipeline: Chrome renders a fixed 1024x1024 viewport via DevTools; empty or
clipped source images are fatal. Source alpha, semantic colour and stroke
masks share one 8% bbox fit. Nine quarter-pixel grid phases are scored by
source topology, silhouette error, then stroke coverage, with zero preferred
on ties. Black pieces receive a source-derived, aspect-correct exterior rim.
Profiles record intentional per-piece exceptions; candidates go under build/.

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

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import gen_sprinter_palette as gsp  # noqa: E402
from build_sprinter_piece_tiles import TILE_W, TILE_H, GEOMETRY
from sprinter_svg_browser import SvgBrowser

SVG_ROOT = ROOT / "assets/lichess/piece"
SELECTED_SETS_JSON = ROOT / "assets/lichess/selected_next_sets.json"
DEFAULT_PALETTE = ROOT / "assets/sprinter/palette.json"
DEFAULT_PIECES_OUT = ROOT / "build/sprinter/pieces40-candidates"
DEFAULT_PREVIEW_OUT = ROOT / "build/sprinter/preview/pieces_raster.png"

PIECE_KINDS = ["K", "Q", "R", "B", "N", "P"]
SIDES = ["w", "b"]

RENDER_SIZE_LADDER = (1024,)
PROFILE_PATH = ROOT / "assets/sprinter/piece_conversion.json"
_RENDERER = None
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
    """Render once at the explicit viewport; clipping is never retried smaller."""
    if sizes != (1024,):
        fail("SVG viewport must be 1024x1024")
    size = sizes[0]
    page = tmpdir / f"{svg.parent.name}_{svg.stem}.html"
    page.write_text('<!doctype html><meta name="viewport" content="width=1024">'
                    '<style>html,body{margin:0;width:1024px;height:1024px;overflow:hidden}'
                    'img{display:block;width:1024px;height:1024px;object-fit:contain}</style>'
                    f'<img src="{file_uri(svg)}">', encoding="utf-8")
    renderer = _RENDERER or SvgBrowser(browser, tmpdir / "profile")
    try:
        image = renderer.render(file_uri(page), size)
    finally:
        if _RENDERER is None:
            renderer.close()
    if image.size != (size, size) or image.getchannel("A").getbbox() is None:
        fail(f"{svg}: empty or incorrectly sized browser render")
    if detect_border_clip(image):
        fail(f"{svg}: clipped at the 1024x1024 viewport border")
    return image, size


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


def source_masks(image: Image.Image, set_name: str, side: str,
                 fit_size: int | None = None) -> tuple[Image.Image, dict]:
    """Keep silhouette, colour regions and original dark strokes separate."""
    masks = {index: Image.new("F", image.size, 0) for index in PIECE_QUANTIZE_INDICES}
    source = image.load()
    pixels = {index: mask.load() for index, mask in masks.items()}
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = source[x, y]
            if a:
                pixels[source_index((r, g, b), set_name, side)][x, y] = a
    alpha = image.getchannel("A").convert("F")
    if fit_size is not None:
        bbox = image.getchannel("A").getbbox()
        alpha = fit_to_square(alpha, fit_size, bbox=bbox)
        masks = {index: fit_to_square(mask, fit_size, bbox=bbox) for index, mask in masks.items()}
    return alpha, masks


def reduce_mask(mask: Image.Image, phase=(0, 0)) -> Image.Image:
    """Translate all source masks by the same fraction of an output pixel."""
    dx, dy = phase
    if dx or dy:
        mask = mask.transform(mask.size, Image.Transform.AFFINE,
                              (1, 0, -dx*mask.width/TILE_W,
                               0, 1, -dy*mask.height/TILE_H), Image.Resampling.BILINEAR)
    return mask.resize((TILE_W, TILE_H), Image.Resampling.BOX)


def paint_masks(alpha, masks, refs, phase=(0, 0), threshold=ALPHA_THRESHOLD):
    small = reduce_mask(alpha, phase)
    covers = {index: reduce_mask(mask, phase) for index, mask in masks.items()}
    out = Image.new("RGBA", (TILE_W, TILE_H), (0, 0, 0, 0))
    for y in range(TILE_H):
        for x in range(TILE_W):
            if small.getpixel((x, y)) < threshold:
                continue
            index = max((5, 4, 6, 7), key=lambda i: (covers[i].getpixel((x, y)), i == 5))
            out.putpixel((x, y), refs[index] + (255,))
    return out


def classify_and_downscale(image: Image.Image, set_name: str, side: str,
                           palette: dict, fit_size: int | None = None) -> Image.Image:
    alpha, masks = source_masks(image, set_name, side, fit_size)
    return paint_masks(alpha, masks, piece_palette(palette, set_name))


def topology(image):
    """Foreground is 8-connected, background 4-connected (digital dual)."""
    components = _opaque_components(image)[1]
    exterior = _exterior_transparency(image)
    holes = 0
    seen = set()
    for y in range(image.height):
        for x in range(image.width):
            if image.getpixel((x, y))[3] or exterior[y][x] or (x, y) in seen:
                continue
            holes += 1
            stack = [(x, y)]
            while stack:
                point = stack.pop()
                if point in seen: continue
                seen.add(point)
                px, py = point
                for nx, ny in ((px+1, py), (px-1, py), (px, py+1), (px, py-1)):
                    if (0 <= nx < image.width and 0 <= ny < image.height
                            and not image.getpixel((nx, ny))[3]
                            and (nx, ny) not in seen):
                        stack.append((nx, ny))
    return components, holes


def binary_image(alpha, size):
    out = Image.new("RGBA", size, (255, 255, 255, 0))
    out.putalpha(alpha.resize(size, Image.Resampling.BOX).convert("L").point(
        lambda a: 255 if a >= ALPHA_THRESHOLD else 0))
    return out


def source_rim(alpha):
    """Derive the light rim before reduction, with square physical pixels.

    At 4x physical resolution, three pixels are 0.75 output columns or
    0.375 output rows. Topology protection acts on SOURCE passages and
    components, so quantization cracks never become protected features.
    """
    size = TILE_W * 4
    source = binary_image(alpha, (size, size))
    expanded = source
    for _ in range(3):
        expanded = guarantee_outline(expanded, (255, 255, 255))
    return expanded.getchannel("A").convert("F").resize(alpha.size, Image.Resampling.BOX)


def reopen_source_passages(image, alpha, phase):
    """Reopen reduction-created holes only where the source is exterior.

    A diagonal cut may survive as diagonally touching transparent pixels,
    which a four-connected background sees as holes. The shortest path uses
    source coverage as its cost, so it follows the cut instead of crossing
    the piece body. Source holes remain protected.
    """
    shifted = alpha
    if phase != (0, 0):
        dx, dy = phase
        shifted = alpha.transform(alpha.size, Image.Transform.AFFINE,
                                  (1,0,-dx*alpha.width/TILE_W,0,1,-dy*alpha.height/TILE_H),
                                  Image.Resampling.BILINEAR)
    reference = binary_image(shifted, (TILE_W*4,TILE_H*4))
    source_exterior = _exterior_transparency(reference)
    coverage = reduce_mask(alpha, phase)
    out = image.copy()
    exterior = _exterior_transparency(out)
    for y in range(TILE_H):
        for x in range(TILE_W):
            if out.getpixel((x,y))[3] or exterior[y][x]: continue
            if not source_exterior[y*4+2][x*4+2]: continue
            queue=[(0,x,y)]
            distances={(x,y):0}
            previous={}
            end=None
            while queue:
                cost,cx,cy=heapq.heappop(queue)
                if cost!=distances[cx,cy]: continue
                if exterior[cy][cx]: end=(cx,cy); break
                for nx,ny in ((cx+1,cy),(cx-1,cy),(cx,cy+1),(cx,cy-1)):
                    if not (0<=nx<TILE_W and 0<=ny<TILE_H): continue
                    step=1+(coverage.getpixel((nx,ny)) if out.getpixel((nx,ny))[3] else 0)
                    new_cost=cost+step
                    if new_cost<distances.get((nx,ny),float('inf')):
                        distances[nx,ny]=new_cost; previous[nx,ny]=(cx,cy)
                        heapq.heappush(queue,(new_cost,nx,ny))
            while end is not None:
                out.putpixel(end,(0,0,0,0)); end=previous.get(end)
            exterior=_exterior_transparency(out)
    return out


def select_grid_phase(alpha, masks, refs, profile=None):
    """Lexicographic source-feature, silhouette, stroke error; stable ties."""
    profile = profile or {}
    reference = binary_image(alpha, (TILE_W*4, TILE_H*4))
    expected = topology(reference)
    threshold = profile.get("alpha_threshold", ALPHA_THRESHOLD)
    candidates = []
    for dy in (-0.25, 0, 0.25):
        for dx in (-0.25, 0, 0.25):
            phase = (dx, dy)
            candidate = reopen_source_passages(paint_masks(alpha, masks, refs, phase, threshold), alpha, phase)
            actual = topology(candidate)
            # Source components/holes outrank pixel error. Compare silhouette
            # against the unshifted source so phases cannot move the goal.
            feature_error = abs(actual[0]-expected[0]) + abs(actual[1]-expected[1])
            up = candidate.getchannel("A").resize(reference.size, Image.Resampling.NEAREST)
            silhouette_error = sum(value*count for value,count in enumerate(
                ImageChops.difference(up, reference.getchannel("A")).histogram()))
            strokes = reduce_mask(masks[5], phase)
            stroke_error = sum(abs(strokes.getpixel((x, y)) -
                                   (255 if candidate.getpixel((x, y)) == refs[5]+(255,) else 0))
                               for y in range(TILE_H) for x in range(TILE_W))
            score = (feature_error, silhouette_error, stroke_error,
                     abs(dx)+abs(dy), abs(dy), abs(dx), dy, dx)
            candidates.append((score, phase, candidate))
    _, phase, candidate = min(candidates, key=lambda c: c[0])
    return candidate, phase, candidates


def process_piece(browser: Path, svg: Path, set_name: str, side: str,
                  palette: dict, tmpdir: Path) -> Image.Image:
    square, used_size = render_svg_square(browser, svg, tmpdir)
    alpha, masks = source_masks(square, set_name, side, fit_size=used_size)
    profile = json.loads(PROFILE_PATH.read_text())
    exceptions = profile.get("pieces", {}).get(set_name + "/" + svg.stem, {})
    refs = piece_palette(palette, set_name)
    quantized, phase, candidates = select_grid_phase(alpha, masks, refs, exceptions)
    # California's SVG gray highlights use the shared gray, distinct from
    # the brighter ADDED rim. This is a source-class override, not pixels.
    if side == "b" and set_name in profile.get("muted_source_highlights", []):
        gray = gsp._parse_rgb(profile["muted_source_highlights"][set_name], "highlight")
        for y in range(TILE_H):
            for x in range(TILE_W):
                if quantized.getpixel((x, y)) == refs[7]+(255,):
                    quantized.putpixel((x, y), gray+(255,))
    if side == "b":
        rim = reduce_mask(source_rim(alpha), phase)
        # The source-derived coverage limits rim thickness; the digital
        # topology guard keeps the already source-checked passages/parts.
        safe_rim = guarantee_outline(quantized, refs[7])
        for y in range(TILE_H):
            for x in range(TILE_W):
                if (not quantized.getpixel((x, y))[3] and safe_rim.getpixel((x, y))[3]
                        and rim.getpixel((x, y)) >= ALPHA_THRESHOLD):
                    quantized.putpixel((x, y), refs[7]+(255,))
    for x, y, index in exceptions.get("pixels", []):
        quantized.putpixel((x, y), refs[index]+(255,) if index is not None else (0, 0, 0, 0))
    cache = DEFAULT_PREVIEW_OUT.parent / "source1024"
    cache.mkdir(parents=True, exist_ok=True)
    square.save(cache / f"{set_name}_{svg.stem}.png")
    report = {"phase": phase, "source_topology": topology(binary_image(alpha, (TILE_W*4,TILE_H*4))),
              "output_topology": topology(quantized),
              "candidates": [{"phase": c[1], "score": c[0]} for c in candidates]}
    (cache / f"{set_name}_{svg.stem}.json").write_text(json.dumps(report, indent=2)+'\n')
    return quantized


def load_selected_sets(path: Path, override: list[str] | None) -> list[str]:
    if override:
        return override
    data = json.loads(path.read_text(encoding="utf-8"))
    return list(data.get("selected", []))


def build_preview(tiles: dict[str, dict[str, Image.Image]], palette: dict,
                  out_path: Path) -> None:
    order = [f"{side}{kind}" for side in SIDES for kind in PIECE_KINDS]
    # Centre the unscaled piece tile in its real 48x24 mode-82 square and
    # correct the pixel aspect ratio vertically by 2x.
    cell_w, stored_h = GEOMETRY["BOARD_CELL_W"], GEOMETRY["BOARD_CELL_H"]
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
                tile = tiles[set_name][key]
                cell.alpha_composite(tile, dest=((cell_w-tile.width)//2, (stored_h-tile.height)//2))
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

    global _RENDERER
    tiles: dict[str, dict[str, Image.Image]] = {}
    with tempfile.TemporaryDirectory(prefix="sprinter-piece-raster-") as tmp:
        tmpdir = Path(tmp)
        _RENDERER = SvgBrowser(browser, tmpdir / "profile")
        try:
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

        finally:
            _RENDERER.close()
            _RENDERER = None
    build_preview(tiles, palette, args.preview_out)
    print(f"[OK] {args.preview_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
