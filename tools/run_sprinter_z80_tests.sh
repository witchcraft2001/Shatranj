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

byte_at() { dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 | tr -d ' \n'; }

fail=0
ran=0
shopt -s nullglob
for src in "$repo_root"/tests/sprinter/z80/t_*.asm; do
  ran=$((ran + 1))
  name="$(basename "$src" .asm)"
  bin="$build_dir/$name.bin"
  dump="$build_dir/$name.out"
  rm -f "$dump"
  sjasmplus --nologo --fullpath \
    -I "$repo_root/asm/sprinter" -I "$generated_dir" -I "$harness_dir" \
    -I "$repo_root/extern/libman/libman" -I "$repo_root/extern/esp_net/src/include" \
    --raw="$bin" "$src"
  "$ticks" -pc 0 -counter "${SPRINTER_Z80_TEST_CYCLES:-4000000}" \
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
