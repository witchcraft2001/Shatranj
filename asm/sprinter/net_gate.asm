; net_gate.asm -- S3's single funnel into libman's l_call (port.md section
; 5/S3). WIN2-half only (INCLUDEd from resident_s1.asm after im2_s1.asm),
; prefix ng_. Nothing here ever hands the DLL a pointer the caller owns:
; every uNet argument buffer is one of this file's own WIN2-resident
; staging buffers, copied into before the call -- a literal assembled into
; the WIN1 half would vanish the instant l_call maps the DLL over it.
;
; ng_call dispatches ordinary network operations. UNETLD's lifecycle calls
; run under ng_lifecycle_enter/exit in net_gate_tail.asm. Both enforce:
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
; libman and the uNet ABI come from pinned submodules. UNETLD owns backend
; selection and lifecycle; this file still owns the guarded call funnel.
; tools/check_sprinter_net_sections.py pins every symbol here to the WIN2
; half ([#8000,#C000)) permanently.

        IFNDEF SPRINTER_NET_GATE_INC
        DEFINE SPRINTER_NET_GATE_INC

        INCLUDE "dss.inc"
        INCLUDE "unet.inc"
        INCLUDE "render_layout.inc"     ; PANEL_X/STATUS_Y (net_up_probe)

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
NG_IP_CAPACITY      EQU 16

; SPECTRUM_MQTT_PACKET_MAX (src/spectrum/transport/mqtt_min.h) as a plain
; number, not an INCLUDE -- that header is C-only. Kept next to the ASSERT
; it exists for, not buried at the bottom of the file with the buffers.
SPECTRUM_MQTT_PACKET_MAX_ASM EQU 160
        ASSERT  NG_TX_CAPACITY >= SPECTRUM_MQTT_PACKET_MAX_ASM

NG_TRAP_REENTRY EQU 1

; ---------------------------------------------------------------------------
; The funnel.
; ---------------------------------------------------------------------------
; In: B=uNet function number, A/DE/IX/IY=that function's arguments (unet.inc).
; Out: CF=0 and A=the uNet status, or CF=1 (dispatcher-level failure --
; ng_v_last_nerr/ng_v_last_cf latch the outcome for the diagnostics screen).
; Uses the handle from UNETLD.HANDLE; HL/BC are consumed by the dispatcher (the
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
        ld hl,(UNETLD.HANDLE)
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
; UNETLD owns selection, loading, ABI validation and network lifecycle.
; ng_up_reason uses UNETLD_E_* codes plus TCP and NETSTART call errors.
; ---------------------------------------------------------------------------
NG_UP_ERR_CAPS EQU 10
NG_UP_ERR_NETSTART_CALL EQU 11

ng_close:
        xor     a                       ; channel 0
        ld      b,UNET_FN_CLOSE
        jp      ng_call

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
; writes ng_c_send_ptr/len, calls the wrapper, then reads its result
; cells. ng_c_connect_at takes pointers from the NET screen for both DIRECT
; and MQTT. The zero-argument wrappers expose their result in ng_v_last_*
; or ng_up_reason.
; ---------------------------------------------------------------------------

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

; ng_lasterr_fetch: copies the tail of the DLL's last AT/driver response
; into ng_buf_lasterr (NUL-terminated). Out: A=status, CF=1 on dispatcher
; failure.
ng_lasterr_fetch:
        ld      de,ng_buf_lasterr
        ld      ix,NG_LASTERR_CAPACITY
        ld      b,UNET_FN_LASTERR
        jp      ng_call

; ---------------------------------------------------------------------------
; State (WIN2-resident; tools/check_sprinter_net_sections.py pins the ng_
; prefix to [#8000,#C000)).
; ---------------------------------------------------------------------------
ng_v_depth:      DB 0
ng_v_last_cf:    DB 0
ng_v_last_nerr:  DB 0

ng_initialized:  DB 0
ng_up_reason:    DB 0

; UNETLD owns the first 315 bytes. RX doubles as the transient CONNECT
; host, and TX doubles as its port and LASTERR destination. These uses
; never overlap in time; the live RX and TX buffers remain separate.
ng_dll_name:    EQU UNETLD.DLL_NAME
ng_buf_rx:      EQU UNETLD.STATE_END
ng_buf_host:    EQU ng_buf_rx
ng_buf_tx:      EQU ng_buf_rx + NG_RX_CAPACITY
ng_buf_port:    EQU ng_buf_tx
ng_buf_lasterr: EQU ng_buf_tx
ng_buf_ip:      EQU ng_buf_tx + NG_TX_CAPACITY
NG_GATE_BUFFERS_END EQU ng_buf_ip + NG_IP_CAPACITY
        ASSERT  UNETLD.STATE_SIZE = 315
        ASSERT  NG_HOST_CAPACITY <= NG_RX_CAPACITY
        ASSERT  NG_PORT_CAPACITY <= NG_TX_CAPACITY
        ASSERT  NG_LASTERR_CAPACITY <= NG_TX_CAPACITY
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
ng_c_env_capacity:   DB 0
ng_c_env_found:      DB 0

        ENDIF
