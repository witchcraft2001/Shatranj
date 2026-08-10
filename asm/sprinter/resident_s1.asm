; Resident image for the S1 platform stand (port.md section 5/S1). ORG'd as
; one flat --raw unit spanning RESIDENT_BASE..WIN2_END (32768 bytes, the
; WIN1+WIN2 halves back to back). sjasmplus does NOT pad gaps created by a
; forward ORG in --raw output (bytes are silently skipped, corrupting every
; later offset) -- every anchor transition below is bridged by an explicit
; DS fill, confirmed by an ASSERT immediately after.
;
; crt0 installs the real IM2 chain (im2_s1.asm, port.md section 3.9, R6)
; and drives a visible tick counter, replacing step 4's temporary IM1 body
; (fill screen, WaitKey, exit) now that PRELOAD/manifest/GETMEM/streaming/
; PSP/trampoline are already proven. video_s1.asm (step 6) replaces this
; file's minimal main loop with the full stand (palette/grid/flip/accel
; smoke/WIN0 probe/mode switch/RTC); the fixed-address skeleton (HDR,
; TRAMPOLINE, PSP_LANDING, CANARY, STACK, IM2_STUB, IM2_TABLE) does not
; change between the two.

        DEVICE NOSLOT64K
        INCLUDE "dss.inc"
        INCLUDE "fixed_layout.inc"
        INCLUDE "hdr.inc"

        ORG     RESIDENT_BASE
HDR:
        ; Deliberately all zero in the static image: preload_loader.asm is
        ; the ONLY writer of the magic (hdr.inc), so the trampoline's check
        ; below proves both "page 0 streamed intact" and "the loader really
        ; published boot info" -- with the magic baked into the image, a
        ; skipped publish would go unnoticed and HDR_PAGE2 (then 0) would
        ; be OUT to WIN2 blindly.
        DS      HDR_SIZE, 0
        ASSERT  $ = TRAMPOLINE_ADDR

; Fixed handoff target: preload_loader.asm JPs here (under DI, WIN1 already
; mapped to this page, its own SP/WIN2 still live). Validates the published
; HDR magic before trusting anything else in HDR, then maps WIN2 from
; HDR_PAGE2, sets the resident stack, and hands off to crt0. On a bad
; magic the loader's stack and WIN2 page are still intact, so a best-effort
; message + DSS_EXIT is possible.
trampoline:
        ld      hl,HDR
        ld      de,.magic_ref
        ld      b,4
.magic: ld      a,(de)
        cp      (hl)
        jr      nz,.bad_hdr
        inc     de
        inc     hl
        djnz    .magic
        ld      a,(HDR+HDR_PAGE2_OFFSET)
        out     (WIN2_PORT),a
        ld      sp,STACK_TOP
        jp      crt0
.bad_hdr:
        ei
        ld      hl,.msg
        ld      c,DSS_PCHARS
        rst     RST_DSS
        ld      b,2
        ld      c,DSS_EXIT
        rst     RST_DSS
.hang:  jr      .hang
.magic_ref: DB "SHS1"
.msg:   DB 13,10,"Sprinter S1: resident HDR check failed.",13,10,0

crt0:
        ld      hl,CANARY_SENTINEL
        ld      (CANARY_ADDR),hl

        ; One-time CMOS probe: DSS SysTime never reports a missing clock
        ; (its .NOCMOS path returns compile-time defaults with CF=0 --
        ; Estex-DSS Time.asm), so rtc_sample gates on this flag instead
        ; and draw_rtc shows dashes on a clockless machine.
        ld      c,BIOS_CMOS_TEST
        rst     RST_BIOS
        ld      a,0
        jr      c,.no_cmos
        inc     a
.no_cmos:
        ld      (rtc_present),a

        call    bench_init
        call    video_init
        di
        call    im2_install
        ei

main_loop:
        call    frame_wait
        jr      c,main_loop             ; timeout (R6 doc note): just retry
        ld      hl,(tick_count)
        inc     hl
        ld      (tick_count),hl

        call    rtc_sample              ; DSS call: EI, canonical windows
        call    echo_tick               ; S3: no-op unless ECHO_STATE_ECHO

        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,#50
        out     (WIN3_PORT),a
        ld      ix,16
        ld      c,16
        ld      de,(tick_count)
        call    draw_hex16
        ld      ix,16
        ld      c,32
        call    draw_rtc
        call    echo_draw_stats         ; S3: rows C=48..96, same DI/WIN3 span
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei

        ld      c,DSS_SCANKEY
        rst     RST_DSS
        jr      z,main_loop
        cp      '1'
        jr      z,.do_flip
        cp      '2'
        jr      z,.do_accel
        cp      '3'
        jr      z,.do_win0
        cp      '4'
        jr      z,.do_mode
        cp      '5'
        jr      z,.do_bench_board
        cp      '6'
        jr      z,.do_bench_text
        cp      '7'
        jr      z,.do_cpu_probe
        cp      '8'
        jr      z,.do_accel_probe
        cp      '9'
        jr      z,.do_board_strip
        cp      'N'
        jr      z,.do_net_up
        cp      'C'
        jr      z,.do_echo_connect
        cp      'D'
        jr      z,.do_echo_disconnect
        cp      'L'
        jr      z,.do_echo_lasterr
        cp      'O'
        jr      z,.do_overlay_probe
        cp      'Q'
        jr      z,.quit
        cp      'q'
        jp      nz,main_loop
.quit:
        jp      exit_stand
.do_flip:
        in      a,(PORT_RGMOD)
        xor     1
        out     (PORT_RGMOD),a
        jp      main_loop
.do_accel:
        call    accel_smoke
        jp      main_loop
.do_win0:
        call    win0_probe
        jp      main_loop
.do_mode:
        call    mode_switch_probe
        jp      main_loop
.do_bench_board:
        call    bench_board
        jp      main_loop
.do_bench_text:
        call    bench_text
        jp      main_loop
.do_cpu_probe:
        call    bench_cpu_probe
        jp      main_loop
.do_accel_probe:
        call    bench_accel_probe
        jp      main_loop
.do_board_strip:
        call    bench_board_strip
        jp      main_loop
.do_net_up:
        call    net_up_probe
        call    echo_note_net_up
        jp      main_loop
.do_echo_connect:
        call    echo_connect_probe
        jp      main_loop
.do_echo_disconnect:
        call    echo_disconnect_probe
        jp      main_loop
.do_echo_lasterr:
        call    echo_lasterr_probe
        jp      main_loop
.do_overlay_probe:
        call    ovl_probe
        jp      main_loop
.saved_win3: DB 0

tick_count: DW 0

        INCLUDE "font_hex.asm"
        INCLUDE "video_s1.asm"
        INCLUDE "gfx_core.asm"
        INCLUDE "text640.asm"
        INCLUDE "bench_s2.asm"
        INCLUDE "ovl_s3.asm"

        ; S3 overlay probe slot (port.md section 3.10/S3): empty in the
        ; static image. ovl_s3.asm copies a packed overlay here at runtime
        ; from the asset page via win0_map_di/LDIR/win0_restore under DI.
        DS      OVL_SLOT_ADDR - $, 0
        ASSERT  $ = OVL_SLOT_ADDR
        DS      OVL_SLOT_SIZE, 0
        ; OVL_SLOT ends exactly where PSP_LANDING begins (no gap): an extra
        ; DS PSP_LANDING_ADDR-$,0 here would be a zero-length fill and
        ; sjasmplus warns on that ("shortblock"), so just assert instead.
        ASSERT  $ = PSP_LANDING_ADDR
        DS      PSP_LANDING_SIZE, 0    ; loader overwrites with the real PSP

; --- WIN2-half code --------------------------------------------------------
; Every SetVMod call leaves the WIN1 *mapping* pointing elsewhere (page
; contents survive): HW_NOTES.md:431-436, and the proven spevosdk
; loader.asm re-maps WIN1 after each SetVMod for exactly this reason. A
; SetVMod issued from WIN1-half code would therefore pull the instruction
; stream out from under itself the moment the RST returns. This wrapper
; lives in the WIN2 half (always mapped: stack, IM2 stub and table are
; here too), saves the WIN1 page, makes the call, and re-maps WIN1 before
; returning to its (usually WIN1-half) caller.
;
; MUST be called under DI: while WIN1 is foreign, an IM2 frame tick would
; write frame_flag (a WIN1-half address) into whatever page SetVMod left
; mapped there. All resident SetVMod calls go through here; the loader is
; already WIN2-resident and re-maps WIN1 itself.
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

; frame_flag/im2_saved_i (and the routines around them) live here, in the
; WIN2 half, not the WIN1 half: S3's l_call sequences run with WIN1 occupied
; by a DLL and interrupts enabled (RTL enables EI internally; entering with
; EI is required -- ftpclient's precedent). A frame tick during any blocking
; DLL call would otherwise write frame_flag into the mapped DLL's image.
; tools/check_sprinter_net_sections.py pins this placement permanently.
        INCLUDE "im2_s1.asm"

        ; libman (extern/libman, pinned) and net_gate.asm's funnel: WIN2-
        ; half only, so a DLL loaded into WIN1 during l_call never displaces
        ; them. LIBMAN_NO_LEGACY_API keeps every reference module-qualified
        ; (LIBMAN.l_call, ...); LIBMAN_MAX_LIBS 1 matches this stand driving
        ; a single backend DLL at a time; LIBMAN_DIAGNOSTICS exposes
        ; l_load_stage/l_init_status for the S3 diagnostics screen.
        DEFINE  LIBMAN_MAX_LIBS 1
        DEFINE  LIBMAN_DIAGNOSTICS
        DEFINE  LIBMAN_NO_LEGACY_API
        INCLUDE "libman.asm"
        INCLUDE "net_gate.asm"
        INCLUDE "echo_s3.asm"

        ; S3 overlay probe context (ovl_s3.asm, WIN1-half dispatch code):
        ; kept here so every piece of S3 cross-mechanism state lives in one
        ; half, alongside net_gate.asm/echo_s3.asm's own -- tools/check_
        ; sprinter_net_sections.py pins the ovl_ctx prefix to WIN2 too.
ovl_ctx: DS 16, 0

        DS      CANARY_ADDR - $, 0
        ASSERT  $ = CANARY_ADDR
        DW      0                       ; canary word, set by crt0 at boot

        ASSERT  $ = STACK_ADDR
        DS      STACK_SIZE, 0           ; $ is now STACK_TOP

        ; STACK_TOP..IM2_STUB_ADDR is reserve/scratch (port.md section 3.1).
        DS      IM2_STUB_ADDR - $, 0
        ASSERT  $ = IM2_STUB_ADDR

; Minimal ISR (R6, 15 bytes): discriminate a frame tick from a keyboard
; interrupt via SIO RR0 bit 0 (non-destructive read: 1 = a scancode is
; waiting, so this is NOT a frame tick and KEYSCAN will collect it), set
; frame_flag on a frame tick, then tail-jump into DSS's own #0038 handler,
; which does keyboard/mouse/cursor work and its own EI/RETI. Inline here
; (not in im2_s1.asm) because it is tiny, single-use, and pinned to this
; exact address by gen_sprinter_layout.py's fill_byte*0x101 invariant.
im2_stub:
        push    af
        in      a,(SIO_A_CTRL)
        rra
        jr      c,.chain
        ld      a,1
        ld      (frame_flag),a
.chain: pop     af
        jp      #0038
        ASSERT  $ - im2_stub = IM2_STUB_SIZE

        ; IM2_STUB_ADDR+IM2_STUB_SIZE..IM2_TABLE_ADDR is reserve (the table
        ; must start 256-aligned).
        DS      IM2_TABLE_ADDR - $, 0
        ASSERT  $ = IM2_TABLE_ADDR
        DS      IM2_TABLE_SIZE, IM2_FILL_BYTE

        ; IM2_TABLE_ADDR+IM2_TABLE_SIZE..WIN2_END is reserve/scratch
        ; (port.md section 3.1).
        DS      WIN2_END - $, 0
        ASSERT  $ = WIN2_END
        END     trampoline
