; Fixed-address stand-in for a tools/gen_sprinter_platform_defs.py-generated
; symbol (PUBLIC name + defc name = $ADDR): resolves crt0_probe_main.c's one
; external call without a real platform_core.bin to link against yet. See
; crt0_probe_main.c for what this fixture proves.
    PUBLIC _crt0_probe_primitive
    defc _crt0_probe_primitive = $9000
