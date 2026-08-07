#!/usr/bin/env python3
"""Regenerate the pinned Sprinter 640-mode raster sources.

This is a maintenance tool, not a normal build dependency.  It uses
ImageMagick to rasterize the selected SVG piece sets.  The ordinary Sprinter
build consumes only the tracked raw raster files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import struct
import zlib
from pathlib import Path


PIECE_WIDTH = 32
PIECE_HEIGHT = 16
VECTOR_RENDER_SIZE = 512
PIECE_ORDER = ("wK", "wQ", "wR", "wB", "wN", "wP",
               "bK", "bQ", "bR", "bB", "bN", "bP")
DEFAULT_SETS = ("california", "mpchess", "totoy")
ATLAS_COLUMNS = 6
ATLAS_WIDTH = PIECE_WIDTH * ATLAS_COLUMNS
ATLAS_HEIGHT = PIECE_HEIGHT * 2


def write_png_rgba(path: Path, width: int, height: int, rgba: bytes) -> None:
    """Write the restricted, deterministic RGBA PNG format accepted by build."""
    if len(rgba) != width * height * 4:
        raise ValueError("malformed RGBA atlas")
    def chunk(name: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + name + data +
                struct.pack(">I", zlib.crc32(name + data) & 0xffffffff))
    rows = b"".join(b"\0" + rgba[row * width * 4:(row + 1) * width * 4]
                    for row in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" +
                     chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) +
                     chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def find_tools() -> tuple[str, str]:
    executable = shutil.which("magick") or shutil.which("convert")
    if not executable:
        raise SystemExit("ImageMagick not found")
    rsvg = shutil.which("rsvg-convert")
    if not rsvg:
        raise SystemExit("rsvg-convert not found")
    return executable, rsvg


def visible_crop(magick: str, png: bytes) -> str:
    """Return the high-resolution bounds of genuinely visible artwork.

    `-trim` on a full RGBA image considers barely non-zero antialias samples.
    At a final height of sixteen pixels those samples become visible dark
    specks after palette quantisation.  Measure the crop using a binary 50%
    alpha mask instead, then crop the original RGBA image to those bounds.
    """
    geometry = subprocess.run(
        [magick, "png:-", "-alpha", "extract", "-threshold", "50%",
         "-trim", "-format", "%wx%h%O", "info:"],
        input=png, check=True, stdout=subprocess.PIPE,
    ).stdout.decode("ascii").strip()
    if not geometry or "x" not in geometry:
        raise SystemExit("SVG contains no visible artwork")
    return geometry


def render_svg(magick: str, rsvg: str, svg: Path) -> bytes:
    source = svg.read_text(encoding="utf-8", errors="replace")
    pixel_art = "crispEdges" in source
    width, height = ((16, 16) if pixel_art else
                     (VECTOR_RENDER_SIZE, VECTOR_RENDER_SIZE))
    png = subprocess.run(
        [rsvg, "--width", str(width), "--height", str(height), str(svg)],
        check=True, stdout=subprocess.PIPE,
    ).stdout
    command = [magick, "png:-", "-crop", visible_crop(magick, png),
               "+repage", "-alpha", "on"]
    if pixel_art:
        # Preserve hard pixel edges, but remove an artist's transparent frame
        # before expanding to the useful GFX640 raster.  The square, rather
        # than the source SVG canvas, supplies all gameplay padding.
        command.extend(("-filter", "point"))
    else:
        # Lichess SVG view boxes often reserve a large transparent margin.
        # Crop that margin at high resolution before the one final resample;
        # otherwise the visible piece becomes smaller than the former 14x14
        # Next sprite even though its Sprinter storage is 32x16.
        command.extend(("-filter", "Lanczos"))
    command.extend(("-resize", f"{PIECE_WIDTH}x{PIECE_HEIGHT}!",
                    "-depth", "8", "rgba:-"))
    data = subprocess.run(command, input=png, check=True,
                          stdout=subprocess.PIPE).stdout
    expected = PIECE_WIDTH * PIECE_HEIGHT * 4
    if len(data) != expected:
        raise SystemExit(f"{svg}: ImageMagick returned {len(data)}, expected {expected}")
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--output-dir", type=Path,
                        default=Path("assets/sprinter"))
    args = parser.parse_args()
    root = args.root.resolve()
    output = (root / args.output_dir).resolve()
    selected = json.loads(
        (root / "assets/lichess/selected_next_sets.json").read_text()
    )["selected"]
    if tuple(selected) != DEFAULT_SETS:
        raise SystemExit("Sprinter raster source expects the pinned three sets")
    magick, rsvg = find_tools()
    output.mkdir(parents=True, exist_ok=True)
    atlases: dict[str, dict[str, object]] = {}
    sources: dict[str, str] = {}
    for set_name in selected:
        atlas = bytearray(ATLAS_WIDTH * ATLAS_HEIGHT * 4)
        for index, piece in enumerate(PIECE_ORDER):
            source = root / "assets/lichess/piece" / set_name / f"{piece}.svg"
            image = render_svg(magick, rsvg, source)
            x = (index % ATLAS_COLUMNS) * PIECE_WIDTH
            y = (index // ATLAS_COLUMNS) * PIECE_HEIGHT
            for row in range(PIECE_HEIGHT):
                dst = ((y + row) * ATLAS_WIDTH + x) * 4
                src = row * PIECE_WIDTH * 4
                atlas[dst:dst + PIECE_WIDTH * 4] = image[src:src + PIECE_WIDTH * 4]
            sources[source.relative_to(root).as_posix()] = sha256(source)
        atlas_name = f"pieces-{set_name}.png"
        atlas_path = output / atlas_name
        write_png_rgba(atlas_path, ATLAS_WIDTH, ATLAS_HEIGHT, bytes(atlas))
        # Three artwork colours occupy slots 12..14.  The HUD and board slots
        # stay fixed across every set.
        palettes = {
            "california": [(244, 244, 244), (40, 40, 40), (152, 152, 152)],
            "mpchess": [(255, 255, 255), (28, 28, 28), (142, 142, 142)],
            "totoy": [(238, 238, 238), (34, 34, 34), (164, 164, 164)],
        }
        atlases[set_name] = {"file": atlas_name, "palette": palettes[set_name]}

    about_source = root / "assets/pc-client/about/about-shatranj.png"
    about = subprocess.run(
        [magick, str(about_source), "-filter", "Lanczos", "-resize", "384x192!",
         "-depth", "8", "rgb:-"],
        check=True, stdout=subprocess.PIPE,
    ).stdout
    if len(about) != 384 * 192 * 3:
        raise SystemExit("ImageMagick returned a malformed About raster")
    about_path = output / "about-384x192.rgb"
    about_path.write_bytes(about)
    sources[about_source.relative_to(root).as_posix()] = sha256(about_source)
    manifest = {
        "format": "Shatranj Sprinter pinned rasters",
        "version": 1,
        "generator": "tools/build_sprinter_rasters.py",
        "piece_sets": selected,
        "piece_order": list(PIECE_ORDER),
        "piece_width": PIECE_WIDTH,
        "piece_height": PIECE_HEIGHT,
        "piece_format": "PNG RGBA8888",
        "piece_atlas_width": ATLAS_WIDTH,
        "piece_atlas_height": ATLAS_HEIGHT,
        "piece_atlas_columns": ATLAS_COLUMNS,
        "piece_atlases": atlases,
        "about_width": 384,
        "about_height": 192,
        "about_format": "RGB888",
        "files": {
            **{str(info["file"]): {"size": (output / str(info["file"])).stat().st_size,
                                     "sha256": sha256(output / str(info["file"]))}
               for info in atlases.values()},
            about_path.name: {"size": about_path.stat().st_size,
                              "sha256": sha256(about_path)},
        },
        "sources": sources,
    }
    (output / "raster_manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"[OK] pinned Sprinter rasters written to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
