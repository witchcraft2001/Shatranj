; Platform primitives (port.md section 3.10/S5, plan D1/D4): everything the
; resident C image and the two z88dk-z80asm modules (render_core.asm,
; overlay_loader_sprinter.asm, both later substeps) call back into --
; graphics, text, palette/RTC, boot-time IM2/canary machinery, and the
; network funnel. Assembled standalone by sjasmplus into its own --raw
; blob, ORG'd at WIN2_BASE (0x8000) through WIN2_END (0xC000): the whole
; WIN2 half except for PSP_LANDING's runtime-owned bytes, which this file
; still reserves (zero-filled placeholder) so the image is a single
; contiguous WIN2 blob for the splicer.
;
; Successor to resident_s1.asm's WIN2-half section plus the production
; subset of its WIN1-half stand modules (bench_s2.asm, video_s1.asm) --
; the S1-S4 stand's own debug/benchmark/hotkey code (main_loop's dispatch,
; draw_grid/accel_smoke/win0_probe/mode_switch_probe, every bench_*
; routine, echo_s3.asm, ovl_s3.asm's probe entry, scene_s4.asm,
; dummy_overlay.asm, font_hex.asm) is deleted, not migrated (plan D4 --
; the stand's job was to prove mechanics on real hardware one at a time;
; S5 builds the real resident on top of what it proved). gfx_core.asm and
; text640.asm carry over unchanged: pure render primitives, no stand-only
; code ever lived there.
;
; Does NOT include overlay dispatch (ovl_exec/ovl_exec_cached): that
; becomes overlay_loader_sprinter.asm in substep 2, a z88dk-z80asm module
; linked alongside the C image instead of a sjasmplus one -- this file
; only reserves OVL_SLOT's bytes.

        DEVICE NOSLOT64K
        INCLUDE "dss.inc"
        INCLUDE "fixed_layout.inc"
        INCLUDE "hdr.inc"
        ; Constants only (S5 substep 3): render_core.asm (a z88dk-z80asm
        ; module) cannot INCLUDE this file itself -- z88dk-z80asm does not
        ; parse sjasmplus's "#XX" hex literal syntax (confirmed 2026-08-10)
        ; -- so its BOARD_*/PANEL_*/band constants are bridged the same way
        ; OVL_SLOT_ADDR/OVL_SLOT_SIZE already are: sjasmplus assembles them
        ; here (as EQUs, no bytes emitted), gen_sprinter_platform_defs.py
        ; picks the needed names out of platform_primitives.sym.
        INCLUDE "render_layout.inc"

        ORG     WIN2_BASE

        ASSERT  $ = PSP_LANDING_ADDR
        DS      PSP_LANDING_SIZE, 0    ; loader overwrites with the real PSP

; --- primitives --------------------------------------------------------

        INCLUDE "gfx_core.asm"
        INCLUDE "text640.asm"
        INCLUDE "buffers.asm"
        INCLUDE "video.asm"

; Every SetVMod call leaves the WIN1 *mapping* pointing elsewhere (page
; contents survive): the proven spevosdk loader re-maps WIN1 after each
; SetVMod for exactly this reason -- and WIN1 is where the C image lives
; now, so leaving it unmapped would pull the instruction stream out from
; under whichever WIN1-half code is running the moment the RST returns.
; Saves the WIN1 page, makes the call, re-maps WIN1 before returning.
;
; MUST be called under DI: while WIN1 is foreign, an IM2 frame tick would
; write frame_flag (a WIN2 address, so actually safe either way -- but the
; discipline is load-bearing for the C image itself, which does live in
; WIN1). Used only by the fatal/exit paths below (im2_s1.asm's
; fatal_stack_overflow/exit_stand, net_gate.asm's ng_trap_screen), all of
; which already run under DI.
;
; A=mode, B=screen (DSS SetVMod convention). Clobbers AF, C.
svmod_safe:
        push    af
        in      a,(WIN1_PORT)
        ld      (.saved_win1),a
        pop     af
        ld      c,DSS_SETVMOD
        rst     RST_DSS
        ld      a,(.saved_win1)
        out     (WIN1_PORT),a
        ret
.saved_win1: DB 0

; frame_flag/im2_saved_i (and the routines around them) live in this WIN2
; blob, not the C image's WIN1 one: S3 proved that l_call sequences run
; with WIN1 occupied by a DLL and interrupts enabled, so a frame tick
; during any blocking DLL call must not write into whatever the DLL
; occupies. tools/check_sprinter_net_sections.py pins this placement.
        INCLUDE "im2_s1.asm"

        ; libman (extern/libman, pinned) and net_gate.asm's funnel: this
        ; WIN2 blob only, so a DLL loaded into WIN1 during l_call never
        ; displaces them. LIBMAN_NO_LEGACY_API keeps every reference
        ; module-qualified; LIBMAN_MAX_LIBS 1 matches one backend DLL at a
        ; time; LIBMAN_DIAGNOSTICS exposes l_load_stage/l_init_status.
        DEFINE  LIBMAN_MAX_LIBS 1
        DEFINE  LIBMAN_DIAGNOSTICS
        DEFINE  LIBMAN_NO_LEGACY_API
        INCLUDE "libman.asm"
        INCLUDE "net_gate.asm"

; esx-ABI-over-DSS file I/O gate (S6, port.md section 3.10 item 4): the
; SAVELOAD/RESTORE/FILEUI overlays run mode-1 (WIN3 mapped to their own
; page), so this needs to be WIN2-resident the same way net_gate.asm is.
; References ovl_win3_page (buffers.asm, above) and WIN3_PORT (dss.inc,
; above); its own reentry trap reuses svmod_safe/im2_uninstall, both
; already in scope by this point.
        INCLUDE "dss_fileio.asm"

; Copies OVL_SLOT_SIZE bytes from the asset page (bench_asset_page) into
; OVL_SLOT_ADDR via win0_map_di/LDIR/win0_restore (R1) -- the one primitive
; overlay_loader_sprinter.asm (a z88dk-z80asm module, substep 2) needs to
; touch WIN0 at all. Keeps win0_map_di/win0_restore's "only these two
; write WIN0_PORT" contract (R1, tools/check_sprinter_win0.py) intact: that
; gate scans asm/sprinter/*.asm source text and would not see a z88dk-
; z80asm file's own WIN0 access.
;
; HL=source address within the WIN0 window (caller's chosen slot*256,
; already in #0000-#3FFF range). CF=1 (nothing copied) if no asset page is
; present. Clobbers AF, BC, DE, HL.
ovl_copy_slot:
        ld      a,(bench_asset_page)
        cp      #FF
        jr      z,.no_page
        ld      de,OVL_SLOT_ADDR
        ld      bc,OVL_SLOT_SIZE
        win0_map_di
        ldir
        win0_restore
        or      a
        ret
.no_page:
        scf
        ret

; NET_FRAME_C reserves the tail of the WIN2 code gap for the net_frame.c
; C-blob (S7, port.md section 3.7): a fourth, independently zcc-built image
; spliced in here by make_sprinter_resident.py, the same "several blobs
; agree only on fixed_layout.json anchors" shape trampoline/resident_c/
; platform_primitives already use. This ASSERT is that agreement's build-
; time enforcement on THIS side: if net_gate.asm/dss_fileio.asm ever grow
; enough to reach NET_FRAME_C_ADDR, sjasmplus fails here (negative DS)
; instead of the splicer silently overlapping two blobs later.
;
; net_gate_gap_end is a plain label, not a boundary anything reads at
; runtime -- it exists so NET_FRAME_C_ADDR - net_gate_gap_end (readable
; straight off the .sym file) answers "how many free bytes are left in
; this code gap" without re-deriving it from a raw-binary trailing-zero
; scan, which the IM2 table's own fill byte makes unreliable past this
; point anyway.
net_gate_gap_end:
        ASSERT  $ <= NET_FRAME_C_ADDR
        DS      NET_FRAME_C_ADDR - $, 0
        DS      NET_FRAME_C_SIZE, 0     ; net_frame.c splice target (S7)

        ASSERT  $ = OVL_SLOT_ADDR       ; NET_FRAME_C_SIZE is flush against it
        DS      OVL_SLOT_SIZE, 0        ; overlay_loader_sprinter.asm's slot

        DS      CANARY_ADDR - $, 0
        ASSERT  $ = CANARY_ADDR
        DW      0                       ; canary word, set by trampoline.asm

        ASSERT  $ = STACK_ADDR
        DS      STACK_SIZE, 0           ; $ is now STACK_TOP

        ; STACK_TOP..IM2_STUB_ADDR is reserve/scratch (port.md section
        ; 3.1), except for RTC_PRESENT_ADDR inside it (trampoline.asm's
        ; own write target, aliased as rtc_present in video.asm).
        DS      IM2_STUB_ADDR - $, 0
        ASSERT  $ = IM2_STUB_ADDR

; Minimal ISR (R6, 15 bytes): discriminate a frame tick from a keyboard
; interrupt via SIO RR0 bit 0, then either tail-jump into im2_s1.asm's
; im2_frame_isr (frame tick: sets frame_flag and acts on a pending
; flip_request, S5-finish plan D11) or DSS's own #0038 handler (anything
; else). Pinned to this exact address by gen_sprinter_layout.py's
; fill_byte*0x101 invariant -- `jp im2_frame_isr` is 2 bytes shorter than
; the `ld a,1 / ld (frame_flag),a` it replaces, padded back to size so the
; ASSERT below still holds; the pad bytes are never reached (the jp always
; jumps away, .chain is only reached via the jr c above).
im2_stub:
        push    af
        in      a,(SIO_A_CTRL)
        rra
        jr      c,.chain
        jp      im2_frame_isr
        DS      2, 0
.chain: pop     af
        jp      #0038
        ASSERT  $ - im2_stub = IM2_STUB_SIZE

        ; IM2_STUB_ADDR+IM2_STUB_SIZE..IM2_TABLE_ADDR is reserve (the
        ; table must start 256-aligned).
        DS      IM2_TABLE_ADDR - $, 0
        ASSERT  $ = IM2_TABLE_ADDR
        DS      IM2_TABLE_SIZE, IM2_FILL_BYTE

        ; IM2_TABLE_ADDR+IM2_TABLE_SIZE..WIN2_END is reserve/scratch.
        DS      WIN2_END - $, 0
        ASSERT  $ = WIN2_END
        END
