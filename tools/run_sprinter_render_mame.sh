#!/usr/bin/env bash
# Called by the root Makefile; the smoke image is the sole test floppy.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
release="${SPRINTER_MAME_RELEASE:-/Users/dmitry/dev/zx/sprinter/mame_images/mame_release_v306_25.05.2025}"
mame="${SPRINTER_MAME:-/Users/dmitry/dev/zx/sprinter/mame_esp/mame_kiselev_3com_ne1000}"
out="$root/build/sprinter/${1:-render-profile}"
cd "$out"
"$mame" sprinter -rompath "$release/roms" -hard1 "$release/IMG/sp_hdd_sys.chd" \
 -bios v3.06 -beta:wd179x:1 35hd -flop2 "$root/build/sprinter/SHATRANJ-SMOKE.IMG" \
 -isa1 rtl8019as -debug -debugger none -video none -nothrottle -sound none \
 -skip_gameinfo -log -autoboot_delay 0 -autoboot_script "$out/review.lua" \
 -snapshot_directory "$out/snap" -cfg_directory "$out/cfg" \
 -nvram_directory "$out/nvram" -diff_directory "$out/diff" > "$out/run.log" 2>&1
