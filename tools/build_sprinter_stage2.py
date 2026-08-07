#!/usr/bin/env python3
"""Build the banked Sprinter Stage-3 uNet client and release directory."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import pack_sprinter_banks


APP_C_SOURCES = (
    "src/spectrum/app/app.c",
)

UI_C_SOURCES = (
    "src/spectrum/board/board.c",
    "src/spectrum/board/san.c",
    "src/spectrum/saveload/saveload.c",
    "src/spectrum/fileui/fileui.c",
    "src/spectrum/restore/restore.c",
    "src/spectrum/ui/gui.c",
    "src/spectrum/overlay/overlay.c",
    "src/sprinter/client_glue.c",
    "src/sprinter/afnt_text.c",
    "src/sprinter/render_layout.c",
    "src/sprinter/render.c",
    "src/sprinter/platform.c",
    "extern/sprinter-libs/gfx640/bindings/sdcc/gfx640.c",
)

PROTOCOL_C_SOURCES = (
    "src/sprinter/session_classifier.c",
    "src/spectrum/config/session.c",
    "src/common/chess/move_coords.c",
    "src/common/protocol/game_protocol.c",
    "src/common/protocol/game_protocol_extra.c",
    "src/common/protocol/direct_session_protocol.c",
    "src/common/protocol/mqtt_session_protocol.c",
    "src/spectrum/session/direct.c",
    "src/spectrum/session/event.c",
    "src/spectrum/session/mqtt.c",
    "src/spectrum/session/outgoing.c",
    "src/spectrum/session/ping.c",
    "src/spectrum/session/poll.c",
    "src/spectrum/transport/keepalive_protocol.c",
    "src/spectrum/transport/mqtt_session_wire.c",
    "src/spectrum/transport/mqtt_min.c",
    "src/sprinter/unet_link.c",
)

APP_ASM_SOURCES = (
    "asm/spectrum/text.asm",
    "asm/spectrum/shrink_kernels.asm",
)

UI_ASM_SOURCES = (
    "asm/sprinter/base_aliases.asm",
    "asm/sprinter/ui_kernels.asm",
)

PROTOCOL_ASM_SOURCES = (
    "asm/spectrum/text.asm",
    "asm/spectrum/shrink_kernels.asm",
)

COLD_ASM_SOURCES = (
    "asm/overlay/rules/entry_rules.asm",
    "asm/overlay/rules/rules_stub.asm",
    "asm/overlay/board/entry_board.asm",
    "asm/overlay/board/helpers.asm",
    "asm/overlay/gui_log/entry_gui_log.asm",
    "asm/sprinter/cold/unet_connect.asm",
    "asm/sprinter/cold/unet_mqtt_tx.asm",
    "asm/sprinter/cold/unet_direct.asm",
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
    "src/sprinter/unet_connect_ovl.c",
    "src/sprinter/unet_mqtt_tx_ovl.c",
    "src/sprinter/unet_direct_ovl.c",
    "src/spectrum/overlay/status_ovl.c",
    "src/spectrum/overlay/input_edit_ovl.c",
    "src/spectrum/overlay/saveload_ovl.c",
    "src/spectrum/overlay/restore_ovl.c",
    "src/spectrum/overlay/fileui_ovl.c",
    "src/spectrum/overlay/control_ovl.c",
)


def run(command: list[str], cwd: Path) -> None:
    subprocess.run(command, cwd=cwd, check=True)


def c_object(directory: Path, source: str) -> Path:
    return directory / Path(source).with_suffix(".o")


def asm_object(directory: Path, source: str) -> Path:
    return directory / Path(source).with_suffix(".o")


def compile_c(common: list[str], root: Path, directory: Path,
              sources: tuple[str, ...], extra: tuple[str, ...] = ()) -> list[Path]:
    objects = []
    for source in sources:
        output = c_object(directory, source)
        output.parent.mkdir(parents=True, exist_ok=True)
        run([*common, *extra, "-c", str(root / source), "-o", str(output)], root)
        objects.append(output)
    return objects


def compile_asm(z80asm: Path, root: Path, build: Path, directory: Path,
                sources: tuple[str, ...]) -> list[Path]:
    objects = []
    for source in sources:
        output = asm_object(directory, source)
        output.parent.mkdir(parents=True, exist_ok=True)
        run([
            str(z80asm), "-DNETCHESSZX_SPRINTER", "-DNETCHESSZX_SDCC_IY",
            f"-I={root}", f"-I={build}", f"-O={directory}", source,
        ], root)
        if not output.is_file():
            raise RuntimeError(f"assembler did not create {output}")
        objects.append(output)
    return objects


def bank_command(zcc: Path, root: Path, build: Path, code: int, data: int,
                 bss: int, objects: list[Path], imports: Path, output: Path,
                 dummy_main: bool) -> list[str]:
    inputs = [str(path) for path in objects]
    if dummy_main:
        inputs.append(str(root / "asm/sprinter/bank_dummy_main.asm"))
    inputs.append(str(imports))
    return [
        str(zcc), "+z80", "-vn", "-startup=0", "-clib=sdcc_iy", "-SO3", "-m",
        "-compiler=sdcc", "-Cs--reserve-regs-iy", "-Cs--no-reg-params",
        "--opt-code-size", "--fomit-frame-pointer",
        f"-custom-copt-rules={root / 'tools/netchesszx_bool_copt'}",
        "-DNETCHESSZX_SPRINTER", "-DNETCHESSZX_SDCC_IY",
        "-DNETCHESSZX_FIXED_LOW_RAM", "-Ca-DNETCHESSZX_SPRINTER",
        "-Ca-DNETCHESSZX_SDCC_IY", f"-Ca-I{root}", f"-Ca-I{build}",
        f"-I{root / 'src'}", f"-I{build}",
        "-pragma-define:CLIB_MALLOC_HEAP_SIZE=0",
        "-pragma-define:CLIB_STDIO_HEAP_SIZE=0",
        "-pragma-define:CRT_ENABLE_STDIO=0", "-pragma-define:CRT_ENABLE_EIDI=0",
        "-pragma-define:CRT_STACK_SIZE=0",
        f"-pragma-define:CRT_ORG_CODE=0x{code:04X}",
        f"-pragma-define:CRT_ORG_DATA=0x{data:04X}",
        f"-pragma-define:CRT_ORG_BSS=0x{bss:04X}",
        f"-zorg=0x{code:04X}", "-Wl,--gc-sections", *inputs,
        "-o", str(output), "-create-app",
    ]


def write_provisional_data_defs(path: Path) -> None:
    names = (
        "_netchesszx_board_theme_index", "_netchesszx_piece_set_index",
        "_netchesszx_movement_hints", "_netchesszx_hinted_rows",
        "_netchesszx_board_light_attr", "_netchesszx_board_dark_attr",
    )
    lines = ["; Provisional renderer DATA imports; regenerated after bank link."]
    for offset, name in enumerate(names):
        lines.extend((f"PUBLIC {name}", f"DEFC {name} = 0x{0xBCB0 + offset:04X}"))
    lines.extend(("PUBLIC sprinter_app_main", "DEFC sprinter_app_main = 0x4100"))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


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
    banks_dir = build / "resident"
    shutil.rmtree(cold, ignore_errors=True)
    shutil.rmtree(libman, ignore_errors=True)
    shutil.rmtree(banks_dir, ignore_errors=True)
    cold.mkdir(parents=True)
    banks_dir.mkdir(parents=True)

    run([
        sys.executable, str(root / "tools/gen_sprinter_layout.py"),
        "--layout", str(root / "src/sprinter/fixed_layout.json"),
        "--asm-out", str(build / "sprinter_layout.inc"),
        "--c-out", str(build / "sprinter_layout.h"),
    ], root)
    (build / "sprinter_layout.stamp").touch()
    run([
        sys.executable, str(root / "tools/build_sprinter_assets.py"),
        "--raster-manifest", str(root / "assets/sprinter/raster_manifest.json"),
        "--about", str(root / "assets/sprinter/about-384x192.rgb"),
        "--font", str(root / "extern/sprinter-libs/afnt640/font.bin"),
        "--page-prefix", str(build / "asset_page_"),
        "--manifest-out", str(build / "asset_manifest.json"),
        "--asm-out", str(build / "sprinter_assets.inc"),
        "--c-out", str(build / "sprinter_assets.h"),
        "--font-widths-out", str(build / "sprinter_afnt640_widths.h"),
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
        "-DNETCHESSZX_SPRINTER", "-DNETCHESSZX_SDCC_IY",
        "-DNETCHESSZX_FIXED_LOW_RAM", f"-I{root / 'src'}", f"-I{build}",
        f"-I{root / 'extern/sprinter-libs/gfx640/bindings/sdcc'}",
    ]

    app_dir = banks_dir / "app"
    ui_dir = banks_dir / "ui"
    protocol_dir = banks_dir / "protocol"
    # App strings are passed through resident WIN1 gates.  Keep compiler
    # constants in preloaded WIN2 DATA so their pointers survive page changes.
    app_objects = compile_c(
        common_c, root, app_dir, APP_C_SOURCES,
        ("--constseg=data_compiler",),
    )
    app_objects += compile_asm(z80asm, root, build, app_dir, APP_ASM_SOURCES)
    ui_objects = compile_c(common_c, root, ui_dir, UI_C_SOURCES)
    ui_objects += compile_asm(z80asm, root, build, ui_dir, UI_ASM_SOURCES)
    protocol_objects = compile_c(common_c, root, protocol_dir, PROTOCOL_C_SOURCES)
    protocol_objects += compile_asm(
        z80asm, root, build, protocol_dir, PROTOCOL_ASM_SOURCES
    )

    bank_specs = [
        ("app", 0, app_objects), ("ui", 2, ui_objects),
        ("protocol", 3, protocol_objects),
    ]
    discovery_args: list[str] = []
    for name, page, objects in bank_specs:
        discovery_args.extend([
            "--bank", f"{name}:{page}:" + ",".join(str(path) for path in objects)
        ])
    run([
        sys.executable, str(root / "tools/gen_sprinter_resident_imports.py"),
        "--z80nm", str(z80nm), *discovery_args,
        "--runtime-source", str(root / "asm/sprinter/runtime.asm"),
        "--plan-out", str(build / "resident_import_plan.json"),
        "--thunks-out", str(build / "sprinter_resident_thunks.inc"),
    ], root)

    pack_sprinter_banks.write_atlas(build / "sprinter_atlas.inc", {})
    (build / "sprinter_far_thunks.inc").write_text(
        "; No cold imports in the provisional runtime.\n", encoding="utf-8"
    )
    write_provisional_data_defs(build / "base_data_defs.asm")
    run([str(z80asm), f"-I={root}", f"-I={build}", "-O=.",
         "base_data_defs.asm"], build)

    # GFX640 and AFNT640 are loaded into WIN1. Their loader must execute in
    # resident WIN2; placing it in the UI bank would page out the currently
    # executing code during l_load.  The ordinary binding wrappers may remain
    # in UI because l_call itself runs in the resident bridge and restores the
    # UI page before returning.  All bank DATA/BSS, including bound_handle,
    # is still composed into WIN2.
    runtime_c = compile_c(
        common_c, root, build / "runtime_obj",
        (
            "src/sprinter/slow_guard.c",
            "src/sprinter/gfx_runtime.c",
        ),
    )
    runtime_asm_sources = (
        "asm/sprinter/gfx_bridge.asm", "asm/sprinter/unet_bridge.asm",
    )
    runtime_asm = compile_asm(z80asm, root, build, build, runtime_asm_sources)
    support = z88dk / "libsrc/newlib/target/z80/obj/sdcc_ix"
    sdcc = support / "l/sdcc"
    runtime_objects = [
        *runtime_c, *runtime_asm, build / "base_data_defs.o",
        sdcc / "___sdcc_enter_ix.o",
        sdcc / "____sdcc_4_copy_srcd_hlix_dst_deix.o",
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
        sys.executable, str(root / "tools/gen_sprinter_resident_imports.py"),
        "--plan", str(build / "resident_import_plan.json"),
        "--runtime-map", str(build / "runtime.map"),
        "--output-dir", str(build / "resident_imports"),
        "--thunks-out", str(build / "sprinter_resident_thunks.inc"),
    ], root)

    bank_layout = {
        "app": (0x4100, 0xABA0, 0xBA70, False),
        "ui": (0x4000, 0xBB70, 0xBBB0, True),
        "protocol": (0x4000, 0xBCB0, 0xBD70, True),
    }

    def link_banks() -> None:
        for name, _, objects in bank_specs:
            code, data, bss, dummy = bank_layout[name]
            run(bank_command(
                zcc, root, build, code, data, bss, objects,
                build / "resident_imports" / f"{name}_imports.asm",
                build / name, dummy,
            ), root)

    link_banks()
    final_map_args = [
        "--bank-map", f"app:{build / 'app.map'}",
        "--bank-map", f"ui:{build / 'ui.map'}",
        "--bank-map", f"protocol:{build / 'protocol.map'}",
    ]
    run([
        sys.executable, str(root / "tools/gen_sprinter_resident_imports.py"),
        "--plan", str(build / "resident_import_plan.json"),
        "--runtime-map", str(build / "runtime.map"), *final_map_args,
        "--output-dir", str(build / "resident_imports"),
        "--thunks-out", str(build / "sprinter_resident_thunks.inc"),
    ], root)
    run([
        sys.executable, str(root / "tools/gen_sprinter_base_data_defs.py"),
        "--map", str(build / "protocol.map"),
        "--app-map", str(build / "app.map"),
        "--output", str(build / "base_data_defs.asm"),
    ], root)
    run([str(z80asm), f"-I={root}", f"-I={build}", "-O=.",
         "base_data_defs.asm"], build)
    link_runtime()
    run([
        sys.executable, str(root / "tools/gen_sprinter_resident_imports.py"),
        "--plan", str(build / "resident_import_plan.json"),
        "--runtime-map", str(build / "runtime.map"), *final_map_args,
        "--output-dir", str(build / "resident_imports"),
        "--thunks-out", str(build / "sprinter_resident_thunks.inc"),
    ], root)
    link_banks()

    cold_asm_objects = compile_asm(
        z80asm, root, build, cold, COLD_ASM_SOURCES
    )
    cold_c_objects = compile_c(common_c, root, cold, COLD_C_SOURCES)
    cold_asm_by_source = dict(zip(COLD_ASM_SOURCES, cold_asm_objects))
    cold_c_by_source = dict(zip(COLD_C_SOURCES, cold_c_objects))
    enter = sdcc / "___sdcc_enter_ix.o"
    copy2 = sdcc / "____sdcc_2_copy_src_mhl_dst_deix.o"
    modules: list[tuple[int, str, list[Path]]] = [
        (0, "rules", [cold_asm_by_source[COLD_ASM_SOURCES[0]],
                       cold_asm_by_source[COLD_ASM_SOURCES[1]]]),
        (1, "board", [cold_asm_by_source[COLD_ASM_SOURCES[2]],
                       cold_asm_by_source[COLD_ASM_SOURCES[3]],
                       cold_c_by_source[COLD_C_SOURCES[0]], enter]),
        (2, "gui_log", [cold_asm_by_source[COLD_ASM_SOURCES[4]],
                         cold_c_by_source[COLD_C_SOURCES[1]], enter]),
        (3, "unet_connect", [cold_asm_by_source[COLD_ASM_SOURCES[5]],
                              cold_c_by_source[COLD_C_SOURCES[2]], enter]),
        (4, "unet_mqtt_tx", [cold_asm_by_source[COLD_ASM_SOURCES[6]],
                              cold_c_by_source[COLD_C_SOURCES[3]], enter]),
        (5, "unet_direct", [cold_asm_by_source[COLD_ASM_SOURCES[7]],
                             cold_c_by_source[COLD_C_SOURCES[4]], enter]),
        (6, "menu_config", [cold_asm_by_source[COLD_ASM_SOURCES[8]]]),
        (7, "menu_logic", [cold_asm_by_source[COLD_ASM_SOURCES[9]],
                            cold_c_by_source[COLD_C_SOURCES[5]], enter]),
        (8, "setup", [cold_asm_by_source[COLD_ASM_SOURCES[10]]]),
        (9, "input_edit", [cold_asm_by_source[COLD_ASM_SOURCES[11]],
                            cold_c_by_source[COLD_C_SOURCES[6]], enter]),
        (10, "saveload", [cold_asm_by_source[COLD_ASM_SOURCES[12]],
                           cold_c_by_source[COLD_C_SOURCES[7]], enter]),
        (11, "restore", [cold_asm_by_source[COLD_ASM_SOURCES[13]],
                          cold_c_by_source[COLD_C_SOURCES[8]], enter]),
        (12, "about", [cold_asm_by_source[COLD_ASM_SOURCES[14]]]),
        (13, "fileui", [cold_asm_by_source[COLD_ASM_SOURCES[15]],
                         cold_c_by_source[COLD_C_SOURCES[9]], enter, copy2]),
        (14, "control", [cold_asm_by_source[COLD_ASM_SOURCES[16]],
                          cold_c_by_source[COLD_C_SOURCES[10]],
                          cold_asm_by_source[COLD_ASM_SOURCES[17]], enter]),
    ]
    module_args: list[str] = []
    for module_id, name, objects in modules:
        module_args.extend([
            "--module", f"{module_id}:{name}:" +
            ",".join(str(path) for path in objects)
        ])
    run([
        sys.executable, str(root / "tools/gen_sprinter_cold_imports.py"),
        "--z80nm", str(z80nm), "--base-map", str(build / "app.map"),
        "--bank-map", f"2:{build / 'ui.map'}",
        "--bank-map", f"3:{build / 'protocol.map'}",
        *module_args, "--thunks-out", str(build / "sprinter_far_thunks.inc"),
        "--plan-out", str(build / "cold_import_plan.json"),
    ], root)
    link_runtime()
    # The provisional runtime above contained an empty far-thunk table.  The
    # final cold plan changes that table's size and can therefore move direct
    # WIN2 imports used by the resident banks.  Regenerate those imports from
    # the new runtime map and relink every WIN1 bank before packing it.  A
    # stale address here executes unrelated resident code while the caller's
    # return address still belongs to the banked UI, which is catastrophic.
    run([
        sys.executable, str(root / "tools/gen_sprinter_resident_imports.py"),
        "--plan", str(build / "resident_import_plan.json"),
        "--runtime-map", str(build / "runtime.map"), *final_map_args,
        "--output-dir", str(build / "resident_imports"),
        "--thunks-out", str(build / "sprinter_resident_thunks.inc"),
    ], root)
    link_banks()
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
        packed_args.extend([
            "--module", f"{module_id}:{name}:" +
            ",".join(str(path) for path in [*objects, defs])
        ])

    run([
        str(z80asm), f"-I={root}", f"-I={build}", "-O=.", "-b", "-m",
        "-r=0x4000", "-o=base_stub.bin", str(root / "asm/sprinter/base_bank.asm"),
    ], build)
    run([
        sys.executable, str(root / "tools/compose_sprinter_pages.py"),
        "--base-stub", str(build / "base_stub.bin"),
        "--client-code", str(build / "app_CODE.bin"),
        "--client-data", str(build / "app_DATA.bin"),
        "--client-map", str(build / "app.map"),
        "--runtime", str(build / "runtime.bin"),
        "--base-out", str(build / "base_bank.bin"),
        "--runtime-out", str(build / "runtime_page.bin"),
        "--bank", f"ui:{build / 'ui_CODE.bin'}:{build / 'ui_DATA.bin'}:"
                  f"{build / 'ui.map'}:{build / 'ui_bank.bin'}",
        "--bank", f"protocol:{build / 'protocol_CODE.bin'}:"
                  f"{build / 'protocol_DATA.bin'}:{build / 'protocol.map'}:"
                  f"{build / 'protocol_bank.bin'}",
    ], root)
    run([
        sys.executable, str(root / "tools/pack_sprinter_banks.py"),
        "--root", str(root), "--build-dir", str(build), "--z80asm", str(z80asm),
        "--resident-page", str(build / "ui_bank.bin"),
        "--resident-page", str(build / "protocol_bank.bin"),
        *packed_args, "--atlas-out", str(build / "sprinter_atlas.inc"),
        "--manifest-out", str(build / "bank_manifest.json"),
        "--page-prefix", str(build / "bank_page_"),
    ], root)
    link_runtime()
    # Atlas bytes changed, not addresses; rebuild the composed runtime page.
    run([
        sys.executable, str(root / "tools/compose_sprinter_pages.py"),
        "--base-stub", str(build / "base_stub.bin"),
        "--client-code", str(build / "app_CODE.bin"),
        "--client-data", str(build / "app_DATA.bin"),
        "--client-map", str(build / "app.map"),
        "--runtime", str(build / "runtime.bin"),
        "--base-out", str(build / "base_bank.bin"),
        "--runtime-out", str(build / "runtime_page.bin"),
        "--bank", f"ui:{build / 'ui_CODE.bin'}:{build / 'ui_DATA.bin'}:"
                  f"{build / 'ui.map'}:{build / 'ui_bank.bin'}",
        "--bank", f"protocol:{build / 'protocol_CODE.bin'}:"
                  f"{build / 'protocol_DATA.bin'}:{build / 'protocol.map'}:"
                  f"{build / 'protocol_bank.bin'}",
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
    for name, source in (
        ("GFX640.DLL", root / "extern/sprinter-libs/gfx640/GFX640.DLL"),
        ("AFNT640.DLL", root / "extern/sprinter-libs/afnt640/AFNT640.DLL"),
        ("UNETESP.DLL", root / "extern/esp_net/UNETESP.DLL"),
        ("UNETRTL.DLL", root / "extern/rtl_net/UNETRTL.DLL"),
    ):
        shutil.copyfile(source, release / name)
    print("[OK] Sprinter Stage-3 release: SHATRANJ.EXE + GFX640/AFNT640/uNet DLLs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
