/* Minimal regression fixture for resident_crt0.asm (port.md section 3.10/S5,
 * plan D1). Not part of the real Shatranj resident -- proves only that a
 * z88dk-compiled C translation unit built with this crt0 (a) links against
 * an external symbol resolved to a fixed address (the shape
 * tools/gen_sprinter_platform_defs.py will produce for real platform_core
 * primitives) and (b) produces a headerless image with _main reachable from
 * a plain CALL, the way tests/tools/test_sprinter_crt0.py checks. Mirrors
 * dummy_overlay.asm's role as a permanent, built-every-run proof fixture
 * for a mechanism rather than a real production module. */

extern void crt0_probe_primitive(void);

void main(void) {
    crt0_probe_primitive();
}
