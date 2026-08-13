; z80 unit test for asm/sprinter/net_gate.asm's ng_call funnel and
; ng_select_backend, driven against a real LIBMAN (extern/libman, pinned)
; with a hand-poked lib_table[0] entry and a fake DLL jump table -- the
; same technique extern/libman/tests/fixtures/libman_diag_vectors.asm uses,
; adapted to net_gate's own scenarios instead of l_load's.
;
; A fake RST #10 answers only the two DSS calls this test's code path ever
; issues: SETWIN1 (#39, corecall's own window-mapping call -- corrupts
; IX/IY first, matching libman_diag_vectors.asm's "DSS may clobber public
; DLL arguments" precedent) and ENVIRON (#46, ng_select_backend's NET
; lookup, always answers "WIFI"). l_load is never exercised here (the fake
; lib_table entry is poked directly), so the much larger DSS surface l_load
; needs (OPEN/ALLOC/SETWIN3/FREE/...) is out of scope for this file.

        device  noslot64k

        org     0
        jp      start
        ; sjasmplus does not pad --raw output across a forward ORG gap
        ; (resident_s1.asm's own banner note); RST #10 hard-jumps to #0010
        ; on real hardware, so dss_stub must land exactly there.
        ds      #0010-$,0
dss_stub:
        ld      a,c
        cp      #39                     ; explicit SETWIN1 (corecall's own
        jr      z,.setwin1              ; generic SETWIN #38 is broken on
                                         ; real Estex-DSS for WIN1)
        cp      #46                     ; ENVIRON
        jr      z,.environ
        ld      a,#7f
        scf
        ret
.setwin1:
        ld      ix,#1111                ; DSS may clobber public DLL
        ld      iy,#2222                ; arguments (libman precedent)
        xor     a
        ret
.environ:
        ; B=DSS_ENV_GET, HL=name (ignored, this stub always answers the
        ; same value), DE=destination. A=#FF found.
        ld      hl,dss_env_value
        ld      bc,5
        ldir
        ld      a,#ff
        ret

dss_env_value: DB "WIFI",0

        assert  $ < #0100
        ds      #0100-$,0

        include "harness.inc"

        DEFINE  S3_TEST_HOOK

NG_TEST_FN_SUCCESS EQU 2
NG_TEST_FN_NESTED  EQU 3
NG_TEST_FN_NERR    EQU 4

; net_gate.asm's exit_stand/fatal_stack_overflow (pulled in transitively via
; im2_s1.asm) reference these; neither is ever reached by this test (the
; S3_TEST_HOOK trap path never calls ng_trap_screen, which is the only
; caller of svmod_safe here).
HDR: DS 256,0
svmod_safe: ret

start:
        ld      sp,#e800
        call    t_begin

        ld      hl,CANARY_SENTINEL
        ld      (CANARY_ADDR),hl

; --- Scenario 1: a clean dispatch enters the DLL with EI and the correct
; displaced-page value in C (net_gate's own "ei before l_call" contract,
; exercised end to end rather than just asserted by inspection). ---------
        call    ng_test_install_lib
        xor     a
        ld      (test_dll_c_seen),a
        ld      (test_dll_iff2_seen),a
        in      a,(#a2)
        exx
        ld      c,a                     ; expected displaced page, in C'
        exx
        ld      b,NG_TEST_FN_SUCCESS
        call    ng_call
        ld      a,1
        call    t_expect_nc
        ld      a,(test_dll_c_seen)
        exx
        cp      c
        exx
        ld      a,2
        call    t_expect_z
        ld      a,(test_dll_iff2_seen)
        cp      1
        ld      a,3
        call    t_expect_z
        ld      a,(ng_v_depth)
        or      a
        ld      a,4
        call    t_expect_z

; --- Scenario 2: a DLL function that itself calls ng_call must hit the
; reentry trap (the library is not reentrant) instead of corrupting state,
; and the outer call must still complete normally afterward. ------------
        xor     a
        ld      (s3_test_trap_fired),a
        ld      (test_dll_nested_returned),a
        ld      b,NG_TEST_FN_NESTED
        call    ng_call
        ld      a,5
        call    t_expect_nc
        ld      a,(s3_test_trap_fired)
        cp      1
        ld      a,6
        call    t_expect_z
        ld      a,(s3_test_trap_code)
        cp      NG_TRAP_REENTRY
        ld      a,7
        call    t_expect_z
        ld      a,(test_dll_nested_returned)
        cp      1
        ld      a,8
        call    t_expect_z
        ld      a,(ng_v_depth)
        or      a
        ld      a,9
        call    t_expect_z

; --- Scenario 3: a clean non-CF DLL status passes through unmangled. ----
        ld      b,NG_TEST_FN_NERR
        call    ng_call
        ld      (test_status_seen),a
        ld      a,10
        call    t_expect_nc
        ld      a,(test_status_seen)
        cp      8
        ld      a,11
        call    t_expect_z
        ld      a,(ng_v_depth)
        or      a
        ld      a,12
        call    t_expect_z

; --- Scenario 4: a dispatcher-level failure (table entry unoccupied)
; surfaces as CF=1, and the reentry guard still clears afterward. --------
        xor     a
        ld      (LIBMAN.lib_table),a
        ld      b,NG_TEST_FN_SUCCESS
        call    ng_call
        ld      a,13
        call    t_expect_c
        ld      a,(ng_v_depth)
        or      a
        ld      a,14
        call    t_expect_z

; --- ng_select_backend: NET=WIFI (via the ENVIRON stub) selects the ESP
; DLL by name. ------------------------------------------------------------
        call    ng_select_backend
        ld      a,15
        call    t_expect_nc
        ld      a,(ng_backend)
        cp      NG_BACKEND_WIFI
        ld      a,16
        call    t_expect_z
        ld      de,ng_dll_name_esp
        or      a
        sbc     hl,de
        ld      a,17
        call    t_expect_z

; --- ng_up is idempotent. With LIBMAN_MAX_LIBS 1 a second l_load can only
; fail ("no free table entry"), and nothing frees that entry between
; sessions, so a second join used to report DLL LOAD FAILED with the DLL
; loaded and healthy. lib_table[0] is still cleared by scenario 4, which is
; what makes these three cheap: ANY path that reaches l_load or l_info from
; here fails, so the outcome alone says which branch ran.
;
; 5a: fully up (loaded, reason 0) -> immediate success, no DLL touched. ---
        ld      a,1
        ld      (ng_loaded),a
        xor     a
        ld      (ng_up_reason),a
        call    ng_up
        ld      a,18
        call    t_expect_nc
        ld      a,(ng_up_reason)
        or      a
        ld      a,19
        call    t_expect_z

; 5b: loaded but a previous bring-up died past the load -> resume at the
; call sequence (l_info, which fails here) instead of re-loading. The
; distinguishing evidence is the reason code: NG_UP_ERR_CALL, not
; NG_UP_ERR_LOAD. ---------------------------------------------------------
        ld      a,1
        ld      (ng_loaded),a
        ld      a,NG_UP_ERR_NETINIT
        ld      (ng_up_reason),a
        call    ng_up
        ld      a,20
        call    t_expect_c
        ld      a,(ng_up_reason)
        cp      NG_UP_ERR_CALL
        ld      a,21
        call    t_expect_z

; 5c: nothing loaded -> the guard must not short-circuit the loader. The
; DSS stub answers neither APPINFO nor OPEN, so l_load fails, and that
; failure is the proof it was reached at all. ----------------------------
        xor     a
        ld      (ng_loaded),a
        ld      (ng_up_reason),a
        call    ng_up
        ld      a,22
        call    t_expect_c
        ld      a,(ng_up_reason)
        cp      NG_UP_ERR_LOAD
        ld      a,23
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

; Poke lib_table[0] directly (bypassing l_load entirely -- this test only
; exercises l_call's dispatch, not the loader): occupied=1, memory block
; handle=7 (unused by these scenarios), window base high byte=#40 (WIN1,
; matching corecall's SETWIN1 branch and dss_stub's .setwin1 handler).
; handle=0 selects this same table entry (l_call's HL*4 indexing).
ng_test_install_lib:
        ld      hl,LIBMAN.lib_table
        ld      (hl),1
        inc     hl
        ld      (hl),7
        inc     hl
        ld      (hl),#40
        inc     hl
        ld      (hl),0
        ld      hl,0
        ld      (ng_handle),hl
        ret

; S3_TEST_HOOK double (im2_s1.asm's S1_TEST_HOOK precedent): records the
; trap code. net_gate.asm's ng_call_reentry already discards its saved
; register context before reaching here, so the stack is already balanced
; -- nothing left for this hook to restore.
s3_test_trap_hook:
        ld      (s3_test_trap_code),a
        ld      a,1
        ld      (s3_test_trap_fired),a
        ret

s3_test_trap_code:        DB 0
s3_test_trap_fired:       DB 0
test_dll_c_seen:          DB 0
test_dll_iff2_seen:       DB 0
test_dll_nested_returned: DB 0
test_status_seen:         DB 0

; Fake DLL jump table. corecall computes lcstart = (window_base_high:#20),
; so with window base high byte #40 (poked above) the table must start
; exactly at #4020 -- everything above must fit below that first.
        assert  $ < #4020
        ds      #4020-$,0
fake_dll_table:
        jp      fake_dll_unused         ; fn 0 (INIT, never called via l_call)
        jp      fake_dll_unused         ; fn 1 (FREE, never called via l_call)
        jp      fake_dll_success        ; fn NG_TEST_FN_SUCCESS
        jp      fake_dll_nested         ; fn NG_TEST_FN_NESTED
        jp      fake_dll_nerr           ; fn NG_TEST_FN_NERR

fake_dll_success:
        ld      a,c
        ld      (test_dll_c_seen),a
        ld      a,i                     ; LD A,I copies IFF2 into P/V
        jp      pe,.iff2_set
        xor     a
        jr      .store
.iff2_set:
        ld      a,1
.store:
        ld      (test_dll_iff2_seen),a
        xor     a
        ret

fake_dll_nested:
        ld      b,NG_TEST_FN_SUCCESS    ; must never actually dispatch --
        call    ng_call                 ; the reentry trap must fire first
        ld      a,1
        ld      (test_dll_nested_returned),a
        xor     a
        ret

fake_dll_nerr:
        ld      a,8
        or      a
        ret

fake_dll_unused:
        ld      a,#66
        scf
        ret

; Generous, defensive gap before the real modules (matches
; libman_diag_vectors.asm's own choice): nothing about corecall's
; addressing requires this, it just keeps the fake table/handlers well
; clear of libman/net_gate's own (much larger) code and state.
        assert  $ < #8000
        ds      #8000-$,0

        include "im2_s1.asm"

        ; S5-finish plan D11 (buffer flip): frame_wait (im2_s1.asm) now
        ; references buffers.asm's flip_ring_count/flip_dirty_all/
        ; resolve_buffers/flip_sync unconditionally -- needed to assemble
        ; standalone, even though this test never calls frame_wait itself.
        ; Placed after im2_s1.asm's own include (not before the #8000
        ; padding above) so it cannot disturb that fixed-address
        ; assertion. text640.asm is buffers.asm's own dependency
        ; (bench_init's text_font_page).
        include "text640.asm"
        include "buffers.asm"

        DEFINE  LIBMAN_MAX_LIBS 1
        DEFINE  LIBMAN_DIAGNOSTICS
        DEFINE  LIBMAN_NO_LEGACY_API
        include "libman.asm"
        include "net_gate.asm"

        end     start
