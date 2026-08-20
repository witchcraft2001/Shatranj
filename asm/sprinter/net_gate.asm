; net_gate.asm -- S3's single funnel into libman's l_call (port.md section
; 5/S3). WIN2-half only (INCLUDEd from resident_s1.asm after im2_s1.asm),
; prefix ng_. Nothing here ever hands the DLL a pointer the caller owns:
; every uNet argument buffer is one of this file's own WIN2-resident
; staging buffers, copied into before the call -- a literal assembled into
; the WIN1 half would vanish the instant l_call maps the DLL over it.
;
; ng_call is the ONLY place that invokes LIBMAN.l_call. It enforces, on
; every call:
;   - a reentry guard (the uNet library is documented non-reentrant: one
;     call at a time). A nested call traps instead of corrupting state
;     silently (R5).
;   - a stack-canary check (R4) both before and after the dispatch.
;   - `ei` immediately before the dispatch: the RTL backend enables
;     interrupts internally, and libman's own contract requires entering
;     with EI regardless of backend (ftpclient's precedent). This is safe
;     specifically because frame_flag/im2_saved_i were moved into the WIN2
;     half in the same S3 step that added this file -- a frame tick firing
;     mid-call now always lands in resident state, never in the mapped
;     DLL's image.
;
; The higher-level wrappers (ng_up/ng_connect/ng_send/ng_recv/ng_close/
; ng_lasterr_fetch/ng_shutdown) take no caller pointers at all: callers
; pass small values (channel is implicitly 0 -- this stand drives a single
; connection) or copy into a fixed source register pair, and results land
; in this file's own buffers.
;
; libman itself (extern/libman, pinned, MODULE LIBMAN, LIBMAN_NO_LEGACY_API
; so every reference is qualified) and the uNet ABI (extern/esp_net's
; unet.inc, FROZEN and byte-identical in rtl_net -- tools/check_sprinter_
; deps.py enforces that) are the two frozen contracts this file drives.
; tools/check_sprinter_net_sections.py pins every symbol here to the WIN2
; half ([#8000,#C000)) permanently.

        IFNDEF SPRINTER_NET_GATE_INC
        DEFINE SPRINTER_NET_GATE_INC

        INCLUDE "dss.inc"
        INCLUDE "unet.inc"
        INCLUDE "render_layout.inc"     ; PANEL_X/STATUS_Y (net_up_probe)

UNET_ABI_MAJOR EQU (UNET_ABI_VERSION >> 8)

NG_BACKEND_NONE EQU 0
NG_BACKEND_WIFI EQU 1
NG_BACKEND_RTL  EQU 2

NG_HOST_CAPACITY    EQU 129
NG_PORT_CAPACITY    EQU 16
; S8 step 1: 64 -> 160 (SPECTRUM_MQTT_PACKET_MAX, mqtt_min.h) so a full MQTT
; packet fits ng_send's single staging copy; the S8 plan's own ASSERT below
; keeps this tied to that constant instead of being a second guess at it.
NG_TX_CAPACITY      EQU 160
; 255, not 256: nc_pump's C-side byte count (ng_v_call_len, fed straight
; into nc_feed()'s uint8_t len parameter) must never need a 9th bit.
NG_RX_CAPACITY      EQU 255
NG_LASTERR_CAPACITY EQU 64
NG_INFO_CAPACITY    EQU 32
NG_ENV_CAPACITY     EQU 64
NG_IP_CAPACITY      EQU 16
NG_ENV_HOST_CAPACITY EQU 24
NG_ENV_PORT_CAPACITY EQU 6

; SPECTRUM_MQTT_PACKET_MAX (src/spectrum/transport/mqtt_min.h) as a plain
; number, not an INCLUDE -- that header is C-only. Kept next to the ASSERT
; it exists for, not buried at the bottom of the file with the buffers.
SPECTRUM_MQTT_PACKET_MAX_ASM EQU 160
        ASSERT  NG_TX_CAPACITY >= SPECTRUM_MQTT_PACKET_MAX_ASM

NG_TRAP_REENTRY EQU 1

; ng_up diagnostic reasons (distinct from uNet's own NERR_* and from
; libman's l_reason/l_dss_error -- surfaced by the S3 hotkey N screen).
NG_UP_ERR_ENV      EQU 1   ; NET env not configured/recognised
NG_UP_ERR_LOAD     EQU 2   ; l_load failed (see LIBMAN.l_reason/l_dss_error)
NG_UP_ERR_INFO_TAG EQU 3   ; l_info prefix doesn't match the selected backend
NG_UP_ERR_ABI      EQU 4   ; GETCAPS major version mismatch
NG_UP_ERR_CAPS     EQU 5   ; GETCAPS missing UNET_CAP_TCP
NG_UP_ERR_SETOPT   EQU 6   ; retired (S9): SETOPT CANCELKEYS is no longer
                           ; called at all (see ng_up's .caps_ok:), so this
                           ; reason is unreachable. Number kept unused rather
                           ; than renumbered -- net_ui_sprinter.c's reason
                           ; switch keys off these values and cases 7-9 must
                           ; not shift.
NG_UP_ERR_STATUS   EQU 7   ; STATUS(#FF) neither NERR_OK nor NERR_NONET
NG_UP_ERR_NETINIT  EQU 8   ; NETINIT failed
NG_UP_ERR_CALL     EQU 9   ; a dispatcher-level ng_call failure (CF=1)

; ---------------------------------------------------------------------------
; The funnel.
; ---------------------------------------------------------------------------
; In: B=uNet function number, A/DE/IX/IY=that function's arguments (unet.inc).
; Out: CF=0 and A=the uNet status, or CF=1 (dispatcher-level failure --
; ng_v_last_nerr/ng_v_last_cf latch the outcome for the diagnostics screen).
; Uses the handle from ng_handle; HL/BC are consumed by the dispatcher (the
; caller never supplies or gets them back, matching unet.inc's own contract).
ng_call:
        push af
        push de
        push ix
        push iy
        push bc

        ld a,(ng_v_depth)
        or a
        jr nz,ng_call_reentry

        ld a,1
        ld (ng_v_depth),a
        call canary_check       ; R4, pre-dispatch; does not return on corruption

        pop bc
        pop iy
        pop ix
        pop de
        pop af

        ei                      ; mandatory immediately before l_call (see banner)
        ld hl,(ng_handle)
        call LIBMAN.l_call

        push af
        push de
        push ix
        push iy
        push bc
        call canary_check       ; R4, post-dispatch
        xor a
        ld (ng_v_depth),a
        pop bc
        pop iy
        pop ix
        pop de
        pop af

        push af
        jr nc,.dispatch_ok
        ld a,1
        jr .store_cf
.dispatch_ok:
        xor a
.store_cf:
        ld (ng_v_last_cf),a
        pop af
        ld (ng_v_last_nerr),a
        ret

; A reentrant ng_call: something invoked ng_call again while already inside
; one (the library is not reentrant -- unet.inc's own contract). Discard
; this invocation's saved context first (it never reaches l_call and does
; not need it restored), THEN trap -- the S3_TEST_HOOK path must return to
; its true caller with a balanced stack, not leave five stale register
; pairs sitting under its RET.
ng_call_reentry:
        pop bc
        pop iy
        pop ix
        pop de
        pop af
        IFDEF S3_TEST_HOOK
        ld a,NG_TRAP_REENTRY
        call s3_test_trap_hook
        ret
        ELSE
        ld a,NG_TRAP_REENTRY
        jp ng_trap_screen
        ENDIF

; Fatal screen: net_gate reentrancy trap fired (R5). Does not return.
; Same shape as im2_s1.asm's fatal_stack_overflow: IM2 uninstalled first (a
; soon-to-be-freed IM2 table must not stay pointed at by I), then a plain
; T40 message and DSS_EXIT.
ng_trap_screen:
        di
        call im2_uninstall
        ld b,0
        ld a,DSS_VMOD_T40
        call svmod_safe          ; WIN2-half wrapper (SetVMod clobbers WIN1)
        ld hl,ng_trap_msg
        ld c,DSS_PCHARS
        rst RST_DSS
        ld b,1
        ld c,DSS_EXIT
        rst RST_DSS
.hang:  jr .hang

ng_trap_msg: DB 13,10,"Sprinter S3: net_gate reentrancy trap (R5).",13,10,0

; ---------------------------------------------------------------------------
; Backend selection (weatherc.asm's SELECT_BACKEND sequence).
; ---------------------------------------------------------------------------
; Out: HL=DLL name (ASCIIZ) and CF=0 on success, ng_backend set; CF=1 if the
; NET env var is missing/unrecognised (ng_backend left at NG_BACKEND_NONE).
; Clobbers AF, DE.
ng_select_backend:
        xor     a
        ld      (ng_buf_env),a
        ld      hl,ng_env_name_net
        ld      de,ng_buf_env
        ld      b,DSS_ENV_GET
        ld      c,DSS_ENVIRON
        rst     RST_DSS
        jr      c,.not_configured
        or      a
        jr      z,.not_configured

        ld      hl,ng_buf_env
        ld      de,ng_value_wifi
        call    ng_streq
        jr      z,.wifi

        ld      hl,ng_buf_env
        ld      de,ng_value_rtl
        call    ng_streq
        jr      z,.rtl

.not_configured:
        xor     a
        ld      (ng_backend),a
        scf
        ret
.wifi:
        ld      a,NG_BACKEND_WIFI
        ld      (ng_backend),a
        ld      hl,ng_dll_name_esp
        or      a
        ret
.rtl:
        ld      a,NG_BACKEND_RTL
        ld      (ng_backend),a
        ld      hl,ng_dll_name_rtl
        or      a
        ret

; Compare ASCIIZ HL and DE. Z when equal. Clobbers AF, HL, DE.
ng_streq:
        ld      a,(de)
        ld      c,a
        ld      a,(hl)
        cp      c
        ret     nz
        or      a
        ret     z
        inc     hl
        inc     de
        jr      ng_streq

; CF=0 if ng_buf_info+16 (the DLL's self-reported short name, NUL-
; terminated -- weatherc.asm's convention) matches the tag for the
; currently selected ng_backend; CF=1 otherwise. Clobbers AF, HL, DE.
ng_validate_info_tag:
        ld      a,(ng_backend)
        cp      NG_BACKEND_WIFI
        ld      de,ng_info_tag_esp
        jr      z,.compare
        cp      NG_BACKEND_RTL
        ld      de,ng_info_tag_rtl
        jr      z,.compare
        scf
        ret
.compare:
        ld      hl,ng_buf_info+16
.loop:
        ld      a,(de)
        or      a
        ret     z
        cp      (hl)
        jr      nz,.mismatch
        inc     hl
        inc     de
        jr      .loop
.mismatch:
        scf
        ret

; ---------------------------------------------------------------------------
; Full bring-up (weatherc.asm's SELECT_BACKEND -> NETINIT sequence).
; ---------------------------------------------------------------------------
; Out: A=0 and CF=0 on success; CF=1 and ng_up_reason set otherwise
; (LIBMAN.l_reason/l_dss_error/l_load_stage/l_init_status carry the detail
; when ng_up_reason is NG_UP_ERR_LOAD).
;
; IDEMPOTENT, AND IT HAS TO BE. libman is built here with LIBMAN_MAX_LIBS 1
; (platform_primitives.asm), so lib_table holds exactly one entry; a second
; l_load with that entry still occupied walks the table, finds nothing free
; and returns CF=1 (libman_core13.asm's ll5b loop -> llerr_after_path).
; Nothing ever frees the entry between sessions -- ng_shutdown is the R11
; exit path only, deliberately, because the DLL stays resident for the life
; of the program. So the join screen's second visit used to fail with
; "DLL LOAD FAILED" while the library was in fact loaded and healthy, which
; is exactly what MAME showed on 2026-08-13 (join, disconnect, join).
;
; The three states are told apart by the two bytes that already exist, so
; this costs no new state: nothing loaded (cold, do everything); loaded and
; ng_up_reason==0 (fully up -- return success without touching l_load or
; NETINIT, since re-initialising a live adapter would cost seconds and drop
; the link the caller is about to reuse); loaded but ng_up_reason!=0 (a
; previous attempt died after the load, so resume at the call sequence --
; the retry path in net_ui_sprinter.c depends on this branch).
ng_up:
        ld      a,(ng_loaded)
        or      a
        jr      z,.cold
        ld      a,(ng_up_reason)
        or      a
        jr      nz,.warm
        ret                             ; already up: A=0, CF=0 from `or a`

.cold:
        call    ng_select_backend
        jr      nc,.env_ok
        ld      a,NG_UP_ERR_ENV
        jr      .fail

.env_ok:
        ld      a,1                     ; window 1 -- S3's l_call sequences
        call    LIBMAN.l_load           ; require the DLL resident in WIN1
        jr      nc,.load_ok
        ld      a,NG_UP_ERR_LOAD
        jr      .fail

.load_ok:
        ld      (ng_handle),hl
        ld      a,1
        ld      (ng_loaded),a

.warm:                                  ; DLL already in WIN1 (see the banner)
        ld      hl,(ng_handle)
        ld      de,ng_buf_info
        call    LIBMAN.l_info
        jr      c,.fail_call
        call    ng_validate_info_tag
        jr      nc,.info_ok
        ld      a,NG_UP_ERR_INFO_TAG
        jr      .fail

.info_ok:
        ld      b,UNET_FN_GETCAPS
        call    ng_call
        jr      c,.fail_call
        ld      a,ixh
        cp      UNET_ABI_MAJOR
        jr      z,.abi_ok
        ld      a,NG_UP_ERR_ABI
        jr      .fail
.abi_ok:
        bit     0,e                     ; UNET_CAP_TCP
        jr      nz,.caps_ok
        ld      a,NG_UP_ERR_CAPS
        jr      .fail
.caps_ok:
        ; SETOPT CANCELKEYS is deliberately never called (S9 MQTT-lag fix,
        ; 2026-08-19): with it on, every DLL blocking wait (TICK_AND_CHECK_KEY,
        ; unetrtl.asm) polls DSS_SCANKEY once per ~1ms, and SCANKEY is a
        ; CONSUMING read of the keyboard ring buffer (KEYINTER.ASM's GETSYM)
        ; that discards anything but Esc/Ctrl-C/Ctrl-Z. Shatranj never
        ; inspects NERR_CANCEL, so the option only cost keystrokes -- worst
        ; during TCP SEND's up-to-4s ACK wait, which MQTT (PUBACK/PINGREQ
        ; every few seconds) hits far more often than DIRECT. Leaving it
        ; unset keeps the DLL's own default (CANCEL_MODE=0, "the DLL never
        ; touches the keyboard unless asked", UNETAPI.md), so DSS_SCANKEY is
        ; never called and every keypress waits in SBUF for key_poll.
        ld      a,#FF
        ld      b,UNET_FN_STATUS
        call    ng_call
        jr      c,.fail_call
        cp      NERR_OK
        jr      z,.status_ok
        cp      NERR_NONET
        jr      z,.status_ok
        ld      a,NG_UP_ERR_STATUS
        jr      .fail
.status_ok:
        ld      b,UNET_FN_NETINIT
        call    ng_call
        jr      c,.fail_call
        or      a
        jr      z,.up_ok
        ld      a,NG_UP_ERR_NETINIT
        jr      .fail

.up_ok:
        xor     a
        ld      (ng_up_reason),a
        or      a
        ret

.fail_call:
        ld      a,NG_UP_ERR_CALL
.fail:
        ld      (ng_up_reason),a
        scf
        ret

; ---------------------------------------------------------------------------
; Session wrappers. Channel is always 0 (this stand drives one connection).
; ---------------------------------------------------------------------------

; Copy an ASCIIZ string (HL) into DE, at most BC-1 chars plus NUL. CF=1 if
; the source had to be truncated (ran out of room before its own NUL).
; Clobbers AF, HL, DE, BC.
ng_copy_asciiz:
        ld      a,b
        or      c
        jr      z,.overflow
.loop:
        ld      a,(hl)
        ld      (de),a
        or      a
        jr      z,.done
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.loop
        dec     de
        xor     a
        ld      (de),a
.overflow:
        scf
        ret
.done:
        or      a
        ret

; ng_connect: HL=host ASCIIZ (<=128B), DE=port ASCIIZ (<=15B).
; Out: A=status, CF=1 on dispatcher failure or an oversized argument
; (NERR_PARAM, checked before ever reaching l_call).
ng_connect:
        push    de
        ld      de,ng_buf_host
        ld      bc,NG_HOST_CAPACITY
        call    ng_copy_asciiz
        jr      c,.overflow_pop

        pop     hl
        ld      de,ng_buf_port
        ld      bc,NG_PORT_CAPACITY
        call    ng_copy_asciiz
        jr      c,.overflow

        xor     a                       ; channel 0
        ld      de,ng_buf_host
        ld      ix,ng_buf_port
        ld      b,UNET_FN_CONNECT
        jp      ng_call

.overflow_pop:
        pop     hl
.overflow:
        ld      a,NERR_PARAM
        scf
        ret

; ng_send: HL=source, B=length (1..NG_TX_CAPACITY).
; Out: A=status, DE=bytes sent, CF=1 on dispatcher failure or an oversized
; length (NERR_PARAM, checked before ever reaching l_call).
ng_send:
        ld      a,b
        or      a
        jr      z,.bad_len
        cp      NG_TX_CAPACITY+1
        jr      nc,.bad_len

        push    bc
        ld      c,a
        ld      b,0
        ld      de,ng_buf_tx
        ldir
        pop     bc

        ld      ix,0
        ld      ixl,b
        xor     a                       ; channel 0
        ld      de,ng_buf_tx
        ld      b,UNET_FN_SEND
        jp      ng_call

.bad_len:
        ld      a,NERR_PARAM
        scf
        ret

; ng_recv: IY=timeout_ms (caller-preloaded; IY=0 polls without blocking).
; Received bytes land in ng_buf_rx (not returned by pointer -- the caller
; reads ng_buf_rx directly, same staging-buffer discipline as everywhere
; else in this file). Requests ng_c_recv_max bytes, not a hardcoded
; NG_RX_CAPACITY -- see that cell's own comment (S8 step 7) for why the
; request ceiling has to be adjustable at all, and ng_c_recv_poll for the
; only C-reachable caller that ever lowers it.
; Out: A=status, DE=bytes received, IX=flags (RXF_* bits), CF=1 on
; dispatcher failure.
ng_recv:
        xor     a                       ; channel 0
        ld      de,ng_buf_rx
        ld      ix,(ng_c_recv_max)
        ld      b,UNET_FN_RECV
        jp      ng_call

; ---------------------------------------------------------------------------
; C-callable wrappers (S7): the C image cannot set up HL/DE/B/IX/IY the way
; ng_connect/ng_send/ng_recv expect (register-based ABI -- this file's own
; funnel discipline, see the file banner). ng_c_send takes its argument
; through fixed module-level cells instead (the same "parameter cells"
; pattern gfx_draw_tile/gfx_blit_rows already use for their own non-
; standard-register call surface, gen_sprinter_platform_defs.py's comment
; on tile_dest_base etc.): src/sprinter/transport/unet_link.c (WIN1)
; writes ng_c_send_ptr/len, calls the wrapper with a plain zero-argument C
; call, then reads ng_v_call_status/len/flags/cf. ng_c_connect needs no
; such cell -- it resolves NETHOST/NETPORT itself via ng_env_nethost/
; ng_env_netport, the env-config-only DIRECT join S7 originally shipped.
; NO C IMAGE CALLS ng_c_connect ANY MORE (S9 MQTT-lag pass, 2026-08-19):
; its one caller, unet_link.c's spectrum_net_connect_host, was deleted as
; dead code (its own spectrum_link_connect_host alias is only reached from
; app.c, not linked into this port) -- the NET screen dials out through
; ng_c_connect_at (a caller-supplied host/port) instead. Kept resident and
; still exercised by tests/sprinter/z80/t_net_core.asm, which calls it
; directly, the same way this whole file's ng_/ng_c_ surface is a stable
; funnel regardless of which C callers currently reach each entry. ng_up/
; ng_close/ng_shutdown/ng_lasterr_fetch/ng_getinfo_ip need no wrapper
; either -- they already take zero pointer arguments, and their outcome is
; ng_v_last_nerr/ng_v_last_cf (set by every ng_call dispatch) or (for
; ng_up specifically) ng_up_reason.
; ---------------------------------------------------------------------------

ng_c_connect:
        call    ng_env_nethost
        push    hl
        call    ng_env_netport
        ex      de,hl                   ; DE = port pointer
        pop     hl                      ; HL = host pointer
        call    ng_connect
        jr      ng_c_store_result

; ng_c_connect_at (S8 step 8c): connects to a CALLER-SUPPLIED host/port
; (ng_c_connect_host/ng_c_connect_port, ASCIIZ pointers the C caller writes
; before this call) instead of resolving NETHOST/NETPORT itself. ng_c_connect
; above is untouched -- DIRECT stays env-only (S7's own design, port.md
; section 3.7), byte-identical. MQTT needs an arbitrary broker address the
; NET screen's editor produced, which no env var can stand in for.
ng_c_connect_at:
        ld      hl,(ng_c_connect_host)
        ld      de,(ng_c_connect_port)
        call    ng_connect
        jr      ng_c_store_result

ng_c_send:
        ld      hl,(ng_c_send_ptr)
        ld      a,(ng_c_send_len)
        ld      b,a
        call    ng_send
        jr      ng_c_store_result

; Self-contained non-blocking poll (IY=0 set here -- unlike raw ng_recv,
; the C caller never has to preload IY itself).
ng_c_recv_poll:
        ld      iy,0
        call    ng_recv
        jr      ng_c_store_result

; Shared tail: stash A/DE/IX/CF from whichever wrapper above just ran.
; Plain `ld (nn),rr` never touches flags on Z80, so CF from the call
; above is still valid at the `jr nc` test below. On the two argument-
; validation failure paths inside ng_connect/ng_send (oversized host/
; port/length, returned directly without reaching ng_call), DE/IX are
; whatever they were before the call -- ng_v_call_cf=1 is the signal to
; ignore ng_v_call_len/flags, not just diagnose ng_v_call_status.
ng_c_store_result:
        ld      (ng_v_call_status),a
        ld      (ng_v_call_len),de
        ld      (ng_v_call_flags),ix
        jr      nc,.no_fail
        ld      a,1
        ld      (ng_v_call_cf),a
        ret
.no_fail:
        xor     a
        ld      (ng_v_call_cf),a
        ret

; ng_close -> A=status, CF=1 on dispatcher failure. Idempotent (unet.inc).
ng_close:
        xor     a                       ; channel 0
        ld      b,UNET_FN_CLOSE
        jp      ng_call

; ng_lasterr_fetch: copies the tail of the DLL's last AT/driver response
; into ng_buf_lasterr (NUL-terminated). Out: A=status, CF=1 on dispatcher
; failure.
ng_lasterr_fetch:
        ld      de,ng_buf_lasterr
        ld      ix,NG_LASTERR_CAPACITY
        ld      b,UNET_FN_LASTERR
        jp      ng_call

; ng_getinfo_ip: fetches the station IPv4 (dotted quad) into ng_buf_ip
; (NUL-terminated, empty if unset -- unet.inc UNET_FN_GETINFO contract).
; Out: A=status, CF=1 on dispatcher failure.
ng_getinfo_ip:
        ld      a,UNET_IF_IP
        ld      de,ng_buf_ip
        ld      ix,NG_IP_CAPACITY
        ld      b,UNET_FN_GETINFO
        jp      ng_call

; ---------------------------------------------------------------------------
; NETHOST/NETPORT env config (echo_s3.asm's DSS_ENV_GET pattern, S7).
; ---------------------------------------------------------------------------

; Try DSS ENVIRON: HL=name (ASCIIZ), DE=dest. Out: CF=0 and dest filled
; (NUL-terminated) if found, CF=1 (dest untouched) otherwise. Clobbers AF.
; DSS ENVIRON has no destination-capacity argument (weatherc.asm's
; documented, accepted risk) -- ng_buf_env_host/ng_buf_env_port are sized
; for realistic hostnames/IPs and ports, not hardened against an
; arbitrarily long value.
ng_env_try:
        ld      b,DSS_ENV_GET
        ld      c,DSS_ENVIRON
        rst     RST_DSS
        ret     c
        or      a
        jr      z,.not_found
        or      a
        ret
.not_found:
        scf
        ret

; Resolves NETHOST, falling back to 127.0.0.1.
; Out: HL=ng_buf_env_host if DSS had the variable, HL=ng_default_host if it
; did not. Clobbers AF, DE.
;
; The fallback deliberately returns the default STRING rather than copying
; it into the buffer, so the returned pointer itself says where the value
; came from: net_ui_sprinter.c compares it against ng_default_host and
; prints "(DEFAULT)". Without that, a missing NETHOST and a NETHOST
; deliberately set to 127.0.0.1 are the same line on screen -- the exact
; ambiguity that cost a MAME round on 2026-08-13. Every consumer only ever
; reads through this entry point (ng_c_connect included, and ng_connect
; copies into ng_buf_host before use), so nothing depends on the buffer
; holding the default.
ng_env_nethost:
        ld      hl,ng_env_name_nethost
        ld      de,ng_buf_env_host
        call    ng_env_try
        ld      hl,ng_default_host
        ret     c
        ld      hl,ng_buf_env_host
        ret

; Resolves NETPORT, falling back to 7777. Same contract as ng_env_nethost.
ng_env_netport:
        ld      hl,ng_env_name_netport
        ld      de,ng_buf_env_port
        call    ng_env_try
        ld      hl,ng_default_port
        ret     c
        ld      hl,ng_buf_env_port
        ret

; ng_c_env_get (S8 step 8c): generic C-callable ASCIIZ env resolver --
; (ng_c_env_name)/(ng_c_env_dest) are pointer cells the C caller writes
; before this call, in WIN1 C (net_mqtt_ui_sprinter.c: MQTTHOST/MQTTPORT/
; MQTTROOM defaults for the NET screen's editor). One routine instead of a
; third near-identical 17-byte resolver alongside ng_env_nethost/
; ng_env_netport -- names and destination buffers live in WIN1 C, so this
; costs LOWRAM_NET_GATE nothing (that region has 0 bytes free). Same
; unbounded-destination risk ng_env_try's own comment already documents
; and accepts for the other two resolvers -- the caller sizes its buffer.
; Out: ng_c_env_found=1 and dest filled (NUL-terminated) if DSS had the
; variable, ng_c_env_found=0 (dest untouched -- caller already seeded a
; default) otherwise. Result lands in a cell, not the return register --
; this codebase's established asm-to-C result convention throughout this
; file (ng_v_call_status/ng_v_call_cf etc.), not a raw z88dk classic-ABI
; return value.
ng_c_env_get:
        ld      hl,(ng_c_env_name)
        ld      de,(ng_c_env_dest)
        call    ng_env_try
        ld      a,0
        jr      c,.store
        ld      a,1
.store:
        ld      (ng_c_env_found),a
        ret

; Best-effort CLOSE -> NETDONE -> l_free (R11 exit discipline). A no-op if
; ng_up never got far enough to load a library. Must run under EI (ng_call
; requires it); call before im2_uninstall so the frame ISR chain is still
; live for canary_check's use inside ng_call.
ng_shutdown:
        ld      a,(ng_loaded)
        or      a
        ret     z

        xor     a                       ; channel 0
        ld      b,UNET_FN_CLOSE
        call    ng_call

        ld      b,UNET_FN_NETDONE
        call    ng_call

        ld      hl,(ng_handle)
        call    LIBMAN.l_free

        xor     a
        ld      (ng_loaded),a
        ret

; ---------------------------------------------------------------------------
; State (WIN2-resident; tools/check_sprinter_net_sections.py pins the ng_
; prefix to [#8000,#C000)).
; ---------------------------------------------------------------------------
ng_v_depth:      DB 0
ng_v_last_cf:    DB 0
ng_v_last_nerr:  DB 0

ng_backend:      DB NG_BACKEND_NONE
ng_handle:       DW 0
ng_loaded:       DB 0
ng_up_reason:    DB 0

ng_env_name_net: DB "NET",0
ng_value_wifi:   DB "WIFI",0
ng_value_rtl:    DB "RTL",0
ng_dll_name_esp: DB "UNETESP.DLL",0
ng_dll_name_rtl: DB "UNETRTL.DLL",0
ng_info_tag_esp: DB "UNETESP",0
ng_info_tag_rtl: DB "UNETRTL",0

ng_env_name_nethost: DB "NETHOST",0
ng_env_name_netport: DB "NETPORT",0
ng_default_host:     DB "127.0.0.1",0
ng_default_port:     DB "7777",0

; S8 step 1: these ten buffers used to be DS reservations right here,
; which put their 766 bytes on the wrong side of a very tight ledger --
; platform_primitives.asm's own WIN2 code region had only 19 bytes free
; before NET_FRAME_C_ADDR after S7 round 3 (port.md). They carry no state
; across a frame boundary that anything outside net_gate.asm reads, so
; there is no reason they need to be part of the assembled blob at all:
; LOWRAM_NET_GATE (fixed_layout.json) is always-mapped WIN2 low RAM,
; reachable exactly the same way from every ng_* routine. Moving them here
; is a pure relocation -- every EQU below is spaced by the SAME capacity
; constants as before, in the SAME order, so ng_buf_tx (now 160 bytes,
; NG_TX_CAPACITY) is still immediately followed by ng_buf_rx, etc.
; ASSERT pins the total against the region's own budget so a future buffer
; growing here fails the build loudly instead of silently overrunning into
; LOWRAM_MQTT_STREAM.
ng_buf_host:     EQU LOWRAM_NET_GATE_ADDR
ng_buf_port:     EQU ng_buf_host + NG_HOST_CAPACITY
ng_buf_tx:       EQU ng_buf_port + NG_PORT_CAPACITY
ng_buf_rx:       EQU ng_buf_tx + NG_TX_CAPACITY
ng_buf_lasterr:  EQU ng_buf_rx + NG_RX_CAPACITY
ng_buf_info:     EQU ng_buf_lasterr + NG_LASTERR_CAPACITY
ng_buf_env:      EQU ng_buf_info + NG_INFO_CAPACITY
ng_buf_ip:       EQU ng_buf_env + NG_ENV_CAPACITY
ng_buf_env_host: EQU ng_buf_ip + NG_IP_CAPACITY
ng_buf_env_port: EQU ng_buf_env_host + NG_ENV_HOST_CAPACITY
NG_GATE_BUFFERS_END EQU ng_buf_env_port + NG_ENV_PORT_CAPACITY
        ASSERT  NG_GATE_BUFFERS_END <= LOWRAM_NET_GATE_END

; ng_c_send wrapper parameter cells / ng_c_* result cells (S7 C bridge).
ng_c_send_ptr:   DW 0
ng_c_send_len:   DB 0
ng_v_call_status: DB 0
ng_v_call_len:   DW 0
ng_v_call_flags: DW 0
ng_v_call_cf:    DB 0
; ng_recv's per-poll request ceiling (S8 step 7): net_frame.c's
; nc_mqtt_pump() lowers this to its MQTT stream accumulator's actual free
; room before each ng_c_recv_poll(), because unlike ZX's UART ring, a
; Sprinter ng_recv() poll hands the DLL's bytes over unconditionally --
; there is no way to ask for N bytes and leave the rest queued for next
; time, so asking for more than the C side has room to keep would lose
; them outright. Defaults to (and nc_pump()'s own DIRECT path always asks
; for) NG_RX_CAPACITY, the DLL's own ceiling -- unchanged behaviour for
; the line-oriented path, which has no such loss-on-drop concern (an
; oversize line is dropped as a whole unit, not silently truncated).
ng_c_recv_max:   DW NG_RX_CAPACITY

; S8 step 8c: ng_c_connect_at/ng_c_env_get parameter cells -- ASCIIZ
; pointers into WIN1 C storage, written by the caller before each call.
ng_c_connect_host: DW 0
ng_c_connect_port: DW 0
ng_c_env_name:      DW 0
ng_c_env_dest:       DW 0
ng_c_env_found:      DB 0

        ENDIF
