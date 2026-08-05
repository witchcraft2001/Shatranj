#!/usr/bin/env python3
"""Build the self-contained Sprinter Stage-2 graphical client."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import pack_sprinter_banks


BASE_SOURCES = (
    "src/sprinter/hotseat_app.c",
    "src/spectrum/config/session.c",
    "src/common/protocol/game_protocol.c",
    "src/sprinter/echo_link.c",
    "src/spectrum/board/board.c",
    "src/spectrum/board/san.c",
    "src/spectrum/saveload/saveload.c",
    "src/spectrum/fileui/fileui.c",
    "src/spectrum/restore/restore.c",
    "src/spectrum/ui/gui.c",
    "src/spectrum/overlay/overlay.c",
    "src/sprinter/client_glue.c",
    "asm/sprinter/base_api.asm",
    "asm/sprinter/base_aliases.asm",
    "asm/spectrum/text.asm",
    "asm/spectrum/shrink_kernels.asm",
)

RUNTIME_C_SOURCES = (
    "src/sprinter/render_layout.c",
    "src/sprinter/render.c",
    "src/sprinter/platform.c",
    "src/sprinter/gfx_runtime.c",
    "extern/sprinter-libs/gfx320/bindings/sdcc/gfx320.c",
)

COLD_ASM_SOURCES = (
    "asm/overlay/rules/entry_rules.asm",
    "asm/overlay/rules/rules_stub.asm",
    "asm/overlay/board/entry_board.asm",
    "asm/overlay/board/helpers.asm",
    "asm/overlay/gui_log/entry_gui_log.asm",
    "asm/sprinter/cold/menu_config.asm",
    "asm/overlay/menu_logic/entry_menu_logic.asm",
    "asm/overlay/setup/entry_setup.asm",
    "asm/overlay/input_edit/entry_input_edit.asm",
    "asm/overlay/saveload/entry_saveload.asm",
    "asm/overlay/restore/entry_restore.asm",
    "asm/overlay/about/entry_about.asm",
    "asm/overlay/fileui/entry_fileui.asm",
    "asm/overlay/control/entry_control.asm",
    "asm/sprinter/cold/control_helpers.asm",
)

COLD_C_SOURCES = (
    "src/spectrum/overlay/board_apply_ovl.c",
    "src/spectrum/overlay/gui_log_ovl.c",
    "src/spectrum/overlay/status_ovl.c",
    "src/spectrum/overlay/input_edit_ovl.c",
    "src/spectrum/overlay/saveload_ovl.c",
    "src/spectrum/overlay/restore_ovl.c",
    "src/spectrum/overlay/fileui_ovl.c",
    "src/spectrum/overlay/control_ovl.c",
)


def run(command: list[str], cwd: Path) -> None:
    subprocess.run(command, cwd=cwd, check=True)


def object_for_asm(cold: Path, source: str) -> Path:
    return cold / Path(source).with_suffix(".o")


def object_for_c(cold: Path, source: str) -> Path:
    return cold / (Path(source).stem + ".o")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--z88dk", type=Path, required=True)
    args = parser.parse_args()

    root = args.root.resolve()
    build = args.build_dir.resolve()
    release = args.release_dir.resolve()
    z88dk = args.z88dk.resolve()
    zcc = z88dk / "bin/zcc"
    z80asm = z88dk / "bin/z80asm"
    z80nm = z88dk / "bin/z88dk-z80nm"
    for tool in (zcc, z80asm, z80nm):
        if not tool.is_file():
            raise SystemExit(f"missing pinned Sprinter tool: {tool}")

    build.mkdir(parents=True, exist_ok=True)
    cold = build / "cold"
    libman = build / "libman"
    shutil.rmtree(cold, ignore_errors=True)
    shutil.rmtree(libman, ignore_errors=True)
    cold.mkdir(parents=True)

    run([
        sys.executable, str(root / "tools/gen_sprinter_layout.py"),
        "--layout", str(root / "src/sprinter/fixed_layout.json"),
        "--asm-out", str(build / "sprinter_layout.inc"),
        "--c-out", str(build / "sprinter_layout.h"),
    ], root)
    (build / "sprinter_layout.stamp").touch()
    run([
        sys.executable, str(root / "tools/build_sprinter_assets.py"),
        "--pieces", str(root / "assets/next/lichess_piece_sprites.bin"),
        "--piece-palette", str(root / "assets/next/lichess_sprite_palette.bin"),
        "--piece-meta", str(root / "assets/next/lichess_piece_sprites.json"),
        "--about", str(root / "assets/next/about_screen.nxi"),
        "--page-prefix", str(build / "asset_page_"),
        "--manifest-out", str(build / "asset_manifest.json"),
        "--asm-out", str(build / "sprinter_assets.inc"),
        "--c-out", str(build / "sprinter_assets.h"),
    ], root)
    run([
        sys.executable, str(root / "tools/adapt_sprinter_libman.py"),
        "--source", str(root / "extern/libman/libman/z80asm"),
        "--output", str(libman),
    ], root)

    common_c = [
        str(zcc), "+z80", "-vn", "-clib=sdcc_iy", "-SO3",
        "-compiler=sdcc", "-Cs--reserve-regs-iy", "-Cs--no-reg-params",
        "--opt-code-size", "--fomit-frame-pointer",
        f"-custom-copt-rules={root / 'tools/netchesszx_bool_copt'}",
        "-DNETCHESSZX_SPRINTER", "-DNETCHESSZX_SPRINTER_STAGE2_ECHO",
        "-DNETCHESSZX_SDCC_IY", "-DNETCHESSZX_FIXED_LOW_RAM",
        f"-I{root / 'src'}", f"-I{build}",
        f"-I{root / 'extern/sprinter-libs/gfx320/bindings/sdcc'}",
    ]
    base_command = [
        str(zcc), "+z80", "-vn", "-startup=0", "-clib=sdcc_iy", "-SO3", "-m",
        "-compiler=sdcc", "-Cs--reserve-regs-iy", "-Cs--no-reg-params",
        "--opt-code-size", "--fomit-frame-pointer",
        f"-custom-copt-rules={root / 'tools/netchesszx_bool_copt'}",
        "-DNETCHESSZX_SPRINTER", "-DNETCHESSZX_SPRINTER_STAGE2_ECHO",
        "-DNETCHESSZX_SDCC_IY", "-DNETCHESSZX_FIXED_LOW_RAM",
        "-Ca-DNETCHESSZX_SPRINTER", "-Ca-DNETCHESSZX_SDCC_IY",
        f"-Ca-I{root}", f"-Ca-I{build}", f"-I{root / 'src'}", f"-I{build}",
        "-pragma-define:CLIB_MALLOC_HEAP_SIZE=0",
        "-pragma-define:CLIB_STDIO_HEAP_SIZE=0",
        "-pragma-define:CRT_ENABLE_STDIO=0", "-pragma-define:CRT_ENABLE_EIDI=0",
        "-pragma-define:CRT_STACK_SIZE=0", "-pragma-define:CRT_ORG_CODE=0x4100",
        "-pragma-define:CRT_ORG_DATA=0xBA30", "-pragma-define:CRT_ORG_BSS=0xBA70",
        "-zorg=0x4100", "-Wl,--gc-sections",
        *(str(root / source) for source in BASE_SOURCES),
        "-o", str(build / "client"), "-create-app",
    ]
    run(base_command, root)
    run([
        sys.executable, str(root / "tools/gen_sprinter_base_data_defs.py"),
        "--map", str(build / "client.map"),
        "--output", str(build / "base_data_defs.asm"),
    ], root)

    for source in RUNTIME_C_SOURCES:
        output = build / (Path(source).stem + ".o")
        run([*common_c, "-c", str(root / source), "-o", str(output)], root)
    runtime_asm_sources = (
        "asm/sprinter/render_hw.asm",
        "asm/sprinter/gfx_bridge.asm",
    )
    for source in runtime_asm_sources:
        run([
            str(z80asm), f"-I={root}", f"-I={build}", f"-O={build}",
            source,
        ], root)
    run([
        str(z80asm), f"-I={root}", f"-I={build}", "-O=.",
        "base_data_defs.asm",
    ], build)

    for source in COLD_ASM_SOURCES:
        run([
            str(z80asm), "-DNETCHESSZX_SPRINTER", "-DNETCHESSZX_SDCC_IY",
            f"-I={root}", f"-I={build}", f"-O={cold}", source,
        ], root)
    for source in COLD_C_SOURCES:
        run([*common_c, "-c", str(root / source),
             "-o", str(object_for_c(cold, source))], root)

    support = z88dk / "libsrc/newlib/target/z80/obj/sdcc_ix"
    sdcc = support / "l/sdcc"
    enter = sdcc / "___sdcc_enter_ix.o"
    copy2 = sdcc / "____sdcc_2_copy_src_mhl_dst_deix.o"
    modules: list[tuple[int, str, list[Path]]] = [
        (0, "rules", [object_for_asm(cold, COLD_ASM_SOURCES[0]),
                       object_for_asm(cold, COLD_ASM_SOURCES[1])]),
        (1, "board", [object_for_asm(cold, COLD_ASM_SOURCES[2]),
                       object_for_asm(cold, COLD_ASM_SOURCES[3]),
                       cold / "board_apply_ovl.o", enter]),
        (2, "gui_log", [object_for_asm(cold, COLD_ASM_SOURCES[4]),
                         cold / "gui_log_ovl.o", enter]),
        (6, "menu_config", [object_for_asm(cold, COLD_ASM_SOURCES[5])]),
        (7, "menu_logic", [object_for_asm(cold, COLD_ASM_SOURCES[6]),
                            cold / "status_ovl.o", enter]),
        (8, "setup", [object_for_asm(cold, COLD_ASM_SOURCES[7])]),
        (9, "input_edit", [object_for_asm(cold, COLD_ASM_SOURCES[8]),
                            cold / "input_edit_ovl.o", enter]),
        (10, "saveload", [object_for_asm(cold, COLD_ASM_SOURCES[9]),
                           cold / "saveload_ovl.o", enter]),
        (11, "restore", [object_for_asm(cold, COLD_ASM_SOURCES[10]),
                          cold / "restore_ovl.o", enter]),
        (12, "about", [object_for_asm(cold, COLD_ASM_SOURCES[11])]),
        (13, "fileui", [object_for_asm(cold, COLD_ASM_SOURCES[12]),
                         cold / "fileui_ovl.o", enter, copy2]),
        (14, "control", [object_for_asm(cold, COLD_ASM_SOURCES[13]),
                          cold / "control_ovl.o",
                          object_for_asm(cold, COLD_ASM_SOURCES[14]), enter]),
    ]
    module_args: list[str] = []
    for module_id, name, objects in modules:
        module_args.extend(["--module", f"{module_id}:{name}:" +
                            ",".join(str(path) for path in objects)])
    run([
        sys.executable, str(root / "tools/gen_sprinter_cold_imports.py"),
        "--z80nm", str(z80nm), "--base-map", str(build / "client.map"),
        *module_args, "--thunks-out", str(build / "sprinter_far_thunks.inc"),
        "--plan-out", str(build / "cold_import_plan.json"),
    ], root)
    pack_sprinter_banks.write_atlas(build / "sprinter_atlas.inc", {})

    runtime_objects = [
        build / "render_layout.o", build / "render.o", build / "platform.o",
        build / "gfx_runtime.o",
        *(object_for_asm(build, source) for source in runtime_asm_sources),
        build / "gfx320.o", build / "base_data_defs.o",
        sdcc / "___sdcc_enter_ix.o",
        sdcc / "____sdcc_4_copy_srcd_hlix_dst_deix.o",
        sdcc / "____sdcc_4_push_hlix.o", sdcc / "__divuint_callee.o",
        support / "math/integer/l_divu_16_16x16.o",
        support / "math/integer/small/l_small_divu_16_16x16.o",
        support / "error/z80/error_divide_by_zero_mc.o",
        support / "error/z80/error_edom_mc.o", support / "error/z80/error_mc.o",
        support / "error/z80/error_zc.o", support / "error/z80/_errno.o",
        support / "error/z80/errno_mc.o",
    ]

    def link_runtime() -> None:
        run([
            str(z80asm), f"-I={root}", f"-I={build}", f"-I={libman}",
            "-O=.", "-b", "-m", "-r=0x8000", "-o=runtime.bin",
            str(root / "asm/sprinter/runtime.asm"),
            *(str(path) for path in runtime_objects),
        ], build)

    link_runtime()
    run([
        sys.executable, str(root / "tools/gen_sprinter_cold_imports.py"),
        "--plan", str(build / "cold_import_plan.json"),
        "--runtime-map", str(build / "runtime.map"),
        "--defs-out", str(build / "cold_import_defs.asm"),
        "--manifest-out", str(build / "cold_import_manifest.json"),
    ], root)
    run([str(z80asm), f"-I={root}", f"-I={build}", f"-O={cold}",
         str(build / "cold_import_defs.asm")], root)
    defs_candidates = list(cold.rglob("cold_import_defs.o"))
    if len(defs_candidates) != 1:
        raise SystemExit("cold import definitions did not produce one object")
    defs = defs_candidates[0]
    packed_args: list[str] = []
    for module_id, name, objects in modules:
        packed_args.extend(["--module", f"{module_id}:{name}:" +
                            ",".join(str(path) for path in [*objects, defs])])
    run([
        sys.executable, str(root / "tools/pack_sprinter_banks.py"),
        "--root", str(root), "--build-dir", str(build), "--z80asm", str(z80asm),
        *packed_args, "--atlas-out", str(build / "sprinter_atlas.inc"),
        "--manifest-out", str(build / "bank_manifest.json"),
        "--page-prefix", str(build / "cold_page_"),
    ], root)
    link_runtime()

    run([
        str(z80asm), f"-I={root}", f"-I={build}", "-O=.", "-b", "-m",
        "-r=0x4000", "-o=base_stub.bin", str(root / "asm/sprinter/base_bank.asm"),
    ], build)
    run([
        sys.executable, str(root / "tools/compose_sprinter_pages.py"),
        "--base-stub", str(build / "base_stub.bin"),
        "--client-code", str(build / "client_CODE.bin"),
        "--client-data", str(build / "client_DATA.bin"),
        "--client-map", str(build / "client.map"),
        "--runtime", str(build / "runtime.bin"),
        "--base-out", str(build / "base_bank.bin"),
        "--runtime-out", str(build / "runtime_page.bin"),
    ], root)
    run([
        str(z80asm), f"-I={root}", f"-I={build}", "-O=.", "-b", "-m",
        "-r=0x8100", "-o=preload_loader.bin",
        str(root / "asm/sprinter/preload_loader.asm"),
    ], build)

    shutil.rmtree(release, ignore_errors=True)
    release.mkdir(parents=True)
    run([
        sys.executable, str(root / "tools/make_sprinter_exe.py"),
        "--loader", str(build / "preload_loader.bin"),
        "--base", str(build / "base_bank.bin"),
        "--runtime", str(build / "runtime_page.bin"),
        "--bank-manifest", str(build / "bank_manifest.json"),
        "--asset-manifest", str(build / "asset_manifest.json"),
        "--manifest-out", str(build / "monoblock_manifest.json"),
        "--output", str(release / "SHATRANJ.EXE"),
    ], root)
    shutil.copyfile(root / "extern/sprinter-libs/gfx320/GFX320.DLL",
                    release / "GFX320.DLL")
    print("[OK] Sprinter Stage-2 release: SHATRANJ.EXE + GFX320.DLL")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
