#!/usr/bin/env bash
# Assemble and run every Sprinter z80 unit test (tests/sprinter/z80/t_*.asm)
# under z88dk-ticks. Protocol matches the pinned extern/sprinter-libs/gfx320
# harness (tools/run_z80_tests.sh in that project): TEST_RESULT=#e000,
# TEST_DONE=#e001 (magic #a5 on completion), TEST_FIRST=#e002,
# TEST_FAILS=#e003.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_dir="$repo_root/build/sprinter/tests"
# Runner-private generated dir: regenerating into build/sprinter/generated
# would bump the mtime of the Makefile-owned fixed_layout.inc and force a
# pointless loader/resident re-assembly on the next make run.
generated_dir="$build_dir/generated"
harness_dir="$repo_root/extern/sprinter-libs/gfx320/tests/z80"

# Same resolution order as the pinned gfx320 runner: explicit $TICKS, then
# the developer-machine default, then whatever is on PATH (the z88dk CI
# container ships z88dk-ticks on PATH but not at the default location).
ticks="${TICKS:-/Users/dmitry/dev/zx/sprinter/z88dk/bin/z88dk-ticks}"
if [[ ! -x "$ticks" ]]; then
  ticks="$(command -v z88dk-ticks || true)"
fi

command -v sjasmplus >/dev/null || { echo "Error: sjasmplus not found" >&2; exit 1; }
[[ -n "$ticks" && -x "$ticks" ]] || { echo "Error: z88dk-ticks not found; set TICKS" >&2; exit 1; }
[[ -f "$harness_dir/harness.inc" ]] || {
  echo "Error: $harness_dir/harness.inc missing; run" \
    "'git submodule update --init extern/sprinter-libs'" >&2
  exit 1
}
mkdir -p "$build_dir" "$generated_dir"

python3 "$repo_root/tools/gen_sprinter_layout.py" \
  --layout "$repo_root/src/sprinter/fixed_layout.json" \
  --inc-out "$generated_dir/fixed_layout.inc" \
  --h-out "$generated_dir/fixed_layout.h" >/dev/null

python3 "$repo_root/tools/gen_sprinter_render_layout.py" \
  --layout "$repo_root/src/sprinter/render_layout.json" \
  --inc-out "$generated_dir/render_layout.inc" \
  --h-out "$generated_dir/render_layout.h" >/dev/null

python3 "$repo_root/tools/gen_sprinter_palette.py" \
  --palette "$repo_root/assets/sprinter/palette.json" \
  --inc-out "$generated_dir/palette_base.inc" \
  --theme-bin-out "$build_dir/theme_table.bin" >/dev/null

# scene_s4.asm's banner. Same generator the Makefile's
# $(SPRINTER_VERSION_INC) rule uses -- the template must not exist twice.
python3 "$repo_root/tools/gen_sprinter_version.py" \
  --version-file "$repo_root/VERSION" \
  --inc-out "$generated_dir/sprinter_version.inc" >/dev/null

# The WIN3 cold-page trampoline, in sjasmplus dialect, for t_cold_thunk.asm.
# Emitted from the same string the real z88dk-z80asm stubs come from, so the
# test runs the instructions that actually ship (see that generator's own
# render_thunks_sjasmplus docstring).
python3 "$repo_root/tools/gen_sprinter_cold_thunks.py" \
  --mode thunks-sjasmplus \
  --out "$generated_dir/cold_thunks_test.inc" >/dev/null

# The real compiled net_frame.c blob's symbol addresses, in sjasmplus syntax,
# for t_net_frame_blob.asm -- which INCBINs that blob and calls into it. The
# point is to run the bytes that ship, not the same C rebuilt by gcc; see that
# test's own banner. Skipped (with the test) when the blob has not been built.
if [[ -f "$repo_root/build/sprinter/net_frame_c.map" ]]; then
  python3 "$repo_root/tools/gen_sprinter_netframe_defs.py" \
    --mode sjasmplus \
    --map "$repo_root/build/sprinter/net_frame_c.map" \
    --out "$generated_dir/netframe_blob_defs.inc" >/dev/null
fi

# The WIN3 cold page's own render entry points, for t_hint_blit.asm -- which
# INCBINs that page and calls render_hint_marker in it. Only cold_page_image.
# map knows those addresses; see that generator's docstring.
if [[ -f "$repo_root/build/sprinter/cold_page_image.map" ]]; then
  python3 "$repo_root/tools/gen_sprinter_coldrender_defs.py" \
    --map "$repo_root/build/sprinter/cold_page_image.map" \
    --sym "$repo_root/build/sprinter/platform_primitives.sym" \
    --out "$generated_dir/coldrender_test_defs.inc" >/dev/null
fi

# Same idea one layer up, for t_net_mqtt_read.asm: that test INCBINs the
# SPLICED resident image (build/sprinter/resident.bin -- WIN1 + WIN2 exactly
# as SHATRANJ.EXE carries them, blob included) and drives its MQTT read path
# through the shipped bytes. Needs both symbol tables: the resident C
# entry points (resident_c.map) and net_gate.asm's own ng_* cells
# (platform_primitives.sym, already sjasmplus-syntax, included directly).
if [[ -f "$repo_root/build/sprinter/resident_c.map" ]]; then
  python3 "$repo_root/tools/gen_sprinter_overlay_defs.py" \
    --mode sjasmplus \
    --map "$repo_root/build/sprinter/resident_c.map" \
    --out "$generated_dir/resident_test_defs.inc" >/dev/null
fi
if [[ -f "$repo_root/build/sprinter/platform_primitives.sym" ]]; then
  python3 "$repo_root/tools/gen_sprinter_platform_defs.py" \
    --mode sjasmplus \
    --sym "$repo_root/build/sprinter/platform_primitives.sym" \
    --out "$generated_dir/platform_test_defs.inc" >/dev/null
fi

byte_at() { dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 | tr -d ' \n'; }

fail=0
ran=0
shopt -s nullglob
for src in "$repo_root"/tests/sprinter/z80/t_*.asm; do
  ran=$((ran + 1))
  name="$(basename "$src" .asm)"
  if [[ "$name" == "t_net_mqtt_read" ]] &&
     { [[ ! -f "$generated_dir/resident_test_defs.inc" ]] ||
       [[ ! -f "$generated_dir/platform_test_defs.inc" ]] ||
       [[ ! -f "$repo_root/build/sprinter/resident.bin" ]]; }; then
    # Same "never built the target" guard t_net_frame_blob has below; the
    # Makefile target depends on resident.bin, so `make sprinter-z80-test`
    # always runs this test.
    echo "SKIP $name: build/sprinter/resident.bin not built" >&2
    ran=$((ran - 1))
    continue
  fi
  if [[ "$name" == "t_about_blit" ]] &&
     { [[ ! -f "$generated_dir/coldrender_test_defs.inc" ]] ||
       [[ ! -f "$repo_root/build/sprinter/overlay_about_sprinter.bin" ]]; }; then
    echo "SKIP $name: build/sprinter/overlay_about_sprinter.bin not built" >&2
    ran=$((ran - 1))
    continue
  fi
  if [[ "$name" == "t_about_restore" ]] &&
     { [[ ! -f "$generated_dir/coldrender_test_defs.inc" ]] ||
       [[ ! -f "$repo_root/build/sprinter/cold_win3_page.bin" ]]; }; then
    echo "SKIP $name: build/sprinter/cold_win3_page.bin not built" >&2
    ran=$((ran - 1))
    continue
  fi
  if [[ "$name" == "t_hint_blit" ]] &&
     { [[ ! -f "$generated_dir/coldrender_test_defs.inc" ]] ||
       [[ ! -f "$repo_root/build/sprinter/cold_win3_page.bin" ]]; }; then
    # Same "never built the target" guard the other blob tests use; the
    # Makefile target depends on the cold page, so `make sprinter-z80-test`
    # always runs this test.
    echo "SKIP $name: build/sprinter/cold_win3_page.bin not built" >&2
    ran=$((ran - 1))
    continue
  fi
  if [[ "$name" == "t_net_frame_blob" && ! -f "$generated_dir/netframe_blob_defs.inc" ]]; then
    # Only reachable when the runner is invoked directly on a tree that has
    # never built the blob; the Makefile target depends on it, so `make
    # sprinter-z80-test` always runs this test.
    echo "SKIP $name: build/sprinter/net_frame_c.bin not built" >&2
    ran=$((ran - 1))
    continue
  fi
  bin="$build_dir/$name.bin"
  dump="$build_dir/$name.out"
  rm -f "$dump"
  sjasmplus --nologo --fullpath \
    -I "$repo_root/asm/sprinter" -I "$generated_dir" -I "$harness_dir" \
    -I "$repo_root/build/sprinter" \
    -I "$repo_root/extern/libman/libman" -I "$repo_root/extern/esp_net/src/include" \
    --raw="$bin" "$src"
  # t_net_mqtt_read drives the real read path through three whole broker-
  # keepalive windows (250 idle frames each), so it needs roughly an order
  # of magnitude more cycles than every other test here. Raising the shared
  # default instead would only make a hung test take that much longer to be
  # reported as hung.
  cycles="${SPRINTER_Z80_TEST_CYCLES:-4000000}"
  if [[ -z "${SPRINTER_Z80_TEST_CYCLES:-}" && "$name" == "t_net_mqtt_read" ]]; then
    cycles=20000000
  fi
  "$ticks" -pc 0 -counter "$cycles" \
    -output "$dump" "$bin" >/dev/null 2>&1 || true
  if [[ ! -f "$dump" ]]; then
    echo "FAIL $name: no memory dump" >&2
    fail=1
    continue
  fi
  done_flag="$(byte_at "$dump" 57345)"
  result="$(byte_at "$dump" 57344)"
  if [[ "$done_flag" != "165" ]]; then
    echo "FAIL $name: did not reach t_end (TEST_DONE=$done_flag, want 165)" >&2
    fail=1
    continue
  fi
  if [[ "$result" != "0" ]]; then
    echo "FAIL $name: assertion $(byte_at "$dump" 57346) failed," \
      "failures=$(byte_at "$dump" 57347)" >&2
    fail=1
    continue
  fi
  echo "[OK] $name"
done

if [[ "$ran" == "0" ]]; then
  # nullglob makes an empty/renamed test dir silently skip the loop; an
  # empty suite must never read as a green one.
  echo "Error: no z80 tests found in tests/sprinter/z80/t_*.asm" >&2
  exit 1
fi
if [[ "$fail" != "0" ]]; then
  exit 1
fi
echo "[OK] Sprinter z80 unit tests"
