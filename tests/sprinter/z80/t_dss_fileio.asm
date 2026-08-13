; z80 unit test for asm/sprinter/dss_fileio.asm's esx-ABI-over-DSS gate
; (S6, port.md section 3.10 item 4). Same technique as t_net_gate.asm: a
; fake RST #10 answers the DSS functions this file's code path issues,
; configurable per-scenario via a handful of test_* globals, and every
; handler corrupts IX/IY plus WIN3_PORT before returning -- proving
; dfio_dss's own protection (IX/IY save/restore, unconditional WIN3 remap)
; actually does something, not just that the happy path looks right.

        device  noslot64k

        org     0
        jp      start
        ; sjasmplus does not pad --raw output across a forward ORG gap;
        ; RST #10 hard-jumps to #0010 on real hardware (t_net_gate.asm's own
        ; note), so dss_stub must land exactly there.
        ds      #0010-$,0
dss_stub:
        ; S6 round 6: dfio_dss used to clobber the caller's real A (handle/
        ; mode/attribute/search-mask) with its own reentry-depth bookkeeping
        ; before the RST ever ran, so every call reached here with A=1
        ; regardless of intent -- silently, since nothing below inspected A
        ; before overwriting it with C for dispatch. Capture the real input
        ; first so scenarios 6/8 can pin it against the constant-1 regression.
        ld      (test_last_input_a),a
        ld      a,c
        cp      DSS_OPEN_FILE
        jr      z,.scalar
        cp      DSS_CREATE_FILE
        jr      z,.scalar
        cp      DSS_CLOSE_FILE
        jr      z,.scalar
        cp      DSS_DELETE_FILE
        jr      z,.scalar
        cp      DSS_WRITE_FILE
        jr      z,.scalar
        cp      DSS_READ_FILE
        jr      z,.read
        cp      DSS_F_FIRST
        jr      z,.find
        cp      DSS_F_NEXT
        jr      z,.find
        cp      DSS_APPINFO
        jr      z,.appinfo
        cp      TEST_FN_NESTED
        jr      z,.nested
        ld      a,#7f
        scf
        ret

; Common corruption every real DSS call in this stub performs: IX/IY
; (Read/Write clobber IX on real Estex-DSS, port.md section 3.10 item 4 --
; corrupting both here is the stricter check) and WIN3_PORT (simulating a
; DSS internal SLOT3 detour that did NOT restore the overlay's own page --
; dfio_dss's remap must fix this unconditionally, not just when it's
; already correct).
.corrupt:
        ld      ix,#1111
        ld      iy,#2222
        ld      a,TEST_WIN3_CORRUPT
        out     (WIN3_PORT),a
        ret

; open/create/close/delete/write: single CF+A result, configured by the
; scenario via test_next_cf/test_next_a.
.scalar:
        call    .corrupt
        ld      a,(test_next_cf)
        or      a
        jr      nz,.scalar_err
        ld      a,(test_next_a)
        or      a
        ret
.scalar_err:
        ld      a,(test_next_a)
        scf
        ret

; read: CF+A like .scalar, plus DE = test_next_de on success (Read's own
; actual-bytes-transferred output, port.md section 3.10 item 4).
.read:
        call    .corrupt
        ld      a,(test_next_cf)
        or      a
        jr      nz,.read_err
        ld      a,(test_next_a)
        ld      de,(test_next_de)
        or      a
        ret
.read_err:
        ld      a,(test_next_a)
        scf
        ret

; F_First/F_Next: LDIR a canned 48-byte record into the caller's buffer
; (DE, untouched by .corrupt), record which function number was used (so
; the test can confirm esx_readdir issues F_First once then F_Next
; afterward), then CF per test_next_cf.
.find:
        ld      (test_last_find_fn),a
        call    .corrupt
        push    de
        ld      hl,test_find_record
        pop     de
        push    de
        ld      bc,48
        ldir
        pop     de
        ld      a,(test_next_cf)
        or      a
        jr      nz,.find_err
        xor     a
        ret
.find_err:
        ld      a,1
        scf
        ret

; AppInfo B=1: caller's HL = destination buffer (Estex-DSS AppInfo.asm's own
; EX DE,HL convention -- verified against that source). Copies
; test_appinfo_string, ASCIIZ, in place of the real EXE home dir.
.appinfo:
        call    .corrupt
        ld      de,test_appinfo_string
.appinfo_copy:
        ld      a,(de)
        ld      (hl),a
        inc     hl
        inc     de
        or      a
        jr      nz,.appinfo_copy
        xor     a
        ret

; A DSS function that itself calls esx_fopen -- reachable only while
; dfio_v_depth is already 1 (this stub only runs from inside dfio_dss's own
; `rst RST_DSS`), so the nested esx_fopen's own dfio_dss call must hit the
; reentry trap instead of issuing a second RST_DSS from inside this one
; (net_gate.asm's fake_dll_nested precedent -- the nested call's own
; outcome is deliberately never checked here, same reason that test never
; checks ng_call's reentrant return either: the trap path's CF/A are not a
; meaningful contract).
.nested:
        push    hl
        ld      hl,test_nested_path
        call    esx_fopen
        pop     hl
        ld      a,1
        ld      (test_nested_returned),a
        xor     a
        ret

test_nested_path: DB "X",0

        assert  $ < #0100
        ds      #0100-$,0

        include "harness.inc"

        DEFINE  DFIO_TEST_HOOK

TEST_FN_NESTED     EQU #7e
TEST_WIN3_CORRUPT  EQU #99
TEST_WIN3_PAGE     EQU #42

; im2_uninstall/svmod_safe: never actually reached (DFIO_TEST_HOOK routes
; every reentry trap to dfio_test_trap_hook instead of dfio_trap_screen),
; but dfio_trap_screen's body still references them by name, so they must
; resolve for the assembler regardless -- t_net_gate.asm's own svmod_safe
; stub is the same shape for the same reason.
im2_uninstall: ret
svmod_safe:    ret

; The one resident global dss_fileio.asm expects to already exist
; (buffers.asm, in the real build) -- WIN3_PORT itself comes from dss.inc,
; pulled in transitively by dss_fileio.asm's own self-include.
ovl_win3_page: DB TEST_WIN3_PAGE

; video.asm's rtc_* cache (spectrum_net_runtime_fat_date/fat_time's own
; inputs) -- not exercised by this test's scenarios, but dss_fileio.asm
; references them unconditionally, so they must resolve to assemble.
rtc_valid:  DB 0
rtc_hour:   DB 0
rtc_minute: DB 0
rtc_second: DB 0
rtc_day:    DB 0
rtc_month:  DB 0
rtc_year:   DW 0

; Scratch the mock's .appinfo handler copies from -- dfio_test_set_appinfo_
; source fills it from whichever canned string the current scenario wants.
test_appinfo_string: DS 32,0

start:
        ld      sp,#e800
        call    t_begin

; --- Scenario 1: open (CF=0) maps the DSS handle to esx_handle=N+1, and
; IX/IY survive the whole call despite the mock corrupting them mid-RST.
; (The WIN3 remap itself -- `ld a,(ovl_win3_page) / out (WIN3_PORT),a`
; right after every RST -- is not asserted here: z88dk-ticks does not model
; port state, IN always reads back a fixed floating value regardless of any
; prior OUT (confirmed empirically), so an IN-based check would pass or
; fail independent of dfio_dss's actual behavior. Verified by disassembly
; instead, same as every other Sprinter primitive this session's testnotes
; call out as "untestable in ticks".) ---------------------------------------
        xor     a
        ld      (test_next_cf),a
        ld      a,5
        ld      (test_next_a),a
        ld      ix,#3333
        ld      iy,#4444
        ld      hl,test_open_path
        call    esx_fopen
        ld      a,(esx_handle)
        cp      6
        ld      a,1
        call    t_expect_z
        ld      a,ixh
        cp      #33
        ld      a,2
        call    t_expect_z
        ld      a,ixl
        cp      #33
        ld      a,3
        call    t_expect_z
        ld      a,iyh
        cp      #44
        ld      a,4
        call    t_expect_z

; --- Scenario 2: open with a valid DSS handle 0 maps to esx_handle=1, not
; 0 -- the N+1 convention is what tells 0 apart from a real error. --------
        xor     a
        ld      (test_next_cf),a
        xor     a
        ld      (test_next_a),a
        ld      hl,test_open_path
        call    esx_fopen
        ld      a,(esx_handle)
        cp      1
        ld      a,6
        call    t_expect_z

; --- Scenario 3: open failure (CF=1) -> esx_handle=0. ---------------------
        ld      a,1
        ld      (test_next_cf),a
        ld      a,#42
        ld      (test_next_a),a
        ld      hl,test_open_path
        call    esx_fopen
        ld      a,(esx_handle)
        or      a
        ld      a,7
        call    t_expect_z

; --- Scenario 4: read success -> esx_result = DSS's own DE (actual bytes
; transferred), not esx_count. ---------------------------------------------
        ld      a,9
        ld      (esx_handle),a          ; -> DSS handle 8
        ld      hl,test_read_buf
        ld      (esx_buf),hl
        ld      hl,99
        ld      (esx_count),hl
        xor     a
        ld      (test_next_cf),a
        ld      hl,7
        ld      (test_next_de),hl
        call    esx_fread
        ld      hl,(esx_result)
        ld      de,7
        or      a
        sbc     hl,de
        ld      a,8
        call    t_expect_z

; --- Scenario 5: read failure -> esx_result = 0. ---------------------------
        ld      a,1
        ld      (test_next_cf),a
        call    esx_fread
        ld      hl,(esx_result)
        ld      a,h
        or      l
        ld      a,9
        call    t_expect_z

; --- Scenario 6: write success ignores DSS's own (unreliable) DE and
; reports esx_count instead. -----------------------------------------------
        ld      hl,20
        ld      (esx_count),hl
        xor     a
        ld      (test_next_cf),a
        ld      hl,#eeee                ; garbage DE the mock returns
        ld      (test_next_de),hl
        call    esx_fwrite
        ld      hl,(esx_result)
        ld      de,20
        or      a
        sbc     hl,de
        ld      a,10
        call    t_expect_z

        ; S6 round 6 regression: the RST must see the real DSS handle (8,
        ; esx_handle-1 from scenario 4's esx_handle=9), not the reentry-
        ; depth flag's constant 1.
        ld      a,(test_last_input_a)
        cp      8
        ld      a,43
        call    t_expect_z

; --- Scenario 7: write failure -> esx_result = 0. --------------------------
        ld      a,1
        ld      (test_next_cf),a
        call    esx_fwrite
        ld      hl,(esx_result)
        ld      a,h
        or      l
        ld      a,11
        call    t_expect_z

; --- Scenario 8: close CF=0/CF=1 -> L=0/0xFF (asm/esxdos/esx_fileio_
; spectalk.asm's own "sbc a,a" idiom, matched here). ------------------------
        xor     a
        ld      (test_next_cf),a
        call    esx_fclose
        ld      a,l
        or      a
        ld      a,12
        call    t_expect_z

        ; S6 round 6 regression (same reasoning as scenario 6's own check,
        ; on the exact call that hit Estex-DSS's ACCESS_DENIED in MAME
        ; "Save failed:IO:19": esx_fclose closing handle 1 -- the depth
        ; flag's own value -- instead of the real DSS handle 8).
        ld      a,(test_last_input_a)
        cp      8
        ld      a,44
        call    t_expect_z

        ld      a,1
        ld      (test_next_cf),a
        call    esx_fclose
        ld      a,l
        cp      #ff
        ld      a,13
        call    t_expect_z

; --- Scenario 9: funlink CF=0/CF=1 -> esx_result=1/0. ----------------------
        xor     a
        ld      (test_next_cf),a
        ld      hl,test_open_path
        call    esx_funlink
        ld      hl,(esx_result)
        ld      de,1
        or      a
        sbc     hl,de
        ld      a,14
        call    t_expect_z

        ld      a,1
        ld      (test_next_cf),a
        ld      hl,test_open_path
        call    esx_funlink
        ld      hl,(esx_result)
        ld      a,h
        or      l
        ld      a,15
        call    t_expect_z

; --- Scenario 10: opendir always reports success; readdir issues F_First
; on the first call (translating the canned 48-byte DSS record into the
; esxDOS-shaped dirent fileui_ovl.c's own fileui_entry_stj parses) and
; F_Next on the next, then CF=1 reads as end-of-listing (esx_result=0). ----
        ld      hl,test_open_path
        call    esx_opendir
        ld      a,(esx_handle)
        or      a
        ld      a,16
        call    t_expect_nz

        xor     a
        ld      (test_next_cf),a
        ld      hl,test_dirent_buf
        ld      (esx_buf),hl
        call    esx_readdir
        ld      hl,(esx_result)
        ld      de,1
        or      a
        sbc     hl,de
        ld      a,17
        call    t_expect_z
        ld      a,(test_last_find_fn)
        cp      DSS_F_FIRST
        ld      a,18
        call    t_expect_z
        ; attr byte
        ld      a,(test_dirent_buf)
        cp      #20
        ld      a,19
        call    t_expect_z
        ; name "A.B",0
        ld      a,(test_dirent_buf+1)
        cp      "A"
        ld      a,20
        call    t_expect_z
        ld      a,(test_dirent_buf+2)
        cp      "."
        ld      a,21
        call    t_expect_z
        ld      a,(test_dirent_buf+3)
        cp      "B"
        ld      a,22
        call    t_expect_z
        ld      a,(test_dirent_buf+4)
        or      a
        ld      a,23
        call    t_expect_z
        ; time lo/hi, date lo/hi
        ld      a,(test_dirent_buf+5)
        cp      #12
        ld      a,24
        call    t_expect_z
        ld      a,(test_dirent_buf+6)
        cp      #34
        ld      a,25
        call    t_expect_z
        ld      a,(test_dirent_buf+7)
        cp      #78
        ld      a,26
        call    t_expect_z
        ld      a,(test_dirent_buf+8)
        cp      #56
        ld      a,27
        call    t_expect_z
        ; size, 4 bytes verbatim
        ld      a,(test_dirent_buf+9)
        cp      #aa
        ld      a,28
        call    t_expect_z
        ld      a,(test_dirent_buf+10)
        cp      #bb
        ld      a,29
        call    t_expect_z
        ld      a,(test_dirent_buf+11)
        cp      #cc
        ld      a,30
        call    t_expect_z
        ld      a,(test_dirent_buf+12)
        cp      #dd
        ld      a,31
        call    t_expect_z

        ; Second entry -> F_Next this time, not F_First.
        call    esx_readdir
        ld      hl,(esx_result)
        ld      de,1
        or      a
        sbc     hl,de
        ld      a,32
        call    t_expect_z
        ld      a,(test_last_find_fn)
        cp      DSS_F_NEXT
        ld      a,33
        call    t_expect_z

        ; End of listing (CF=1) -> esx_result=0.
        ld      a,1
        ld      (test_next_cf),a
        call    esx_readdir
        ld      hl,(esx_result)
        ld      a,h
        or      l
        ld      a,34
        call    t_expect_z

; --- Scenario 11: save-dir init appends a missing trailing separator,
; leaves an already-terminated one alone, and turns an empty AppInfo
; result into a bare "\". -----------------------------------------------
        ld      hl,test_appinfo_no_sep
        ld      (test_appinfo_ptr),hl
        call    dfio_test_set_appinfo_source
        call    spectrum_platform_save_dir_init
        call    spectrum_platform_save_dir
        ld      de,test_appinfo_no_sep_want
        call    dfio_test_streq
        ld      a,35
        call    t_expect_z

        ld      hl,test_appinfo_with_sep
        ld      (test_appinfo_ptr),hl
        call    dfio_test_set_appinfo_source
        call    spectrum_platform_save_dir_init
        call    spectrum_platform_save_dir
        ld      de,test_appinfo_with_sep
        call    dfio_test_streq
        ld      a,36
        call    t_expect_z

        ld      hl,test_appinfo_empty
        ld      (test_appinfo_ptr),hl
        call    dfio_test_set_appinfo_source
        call    spectrum_platform_save_dir_init
        call    spectrum_platform_save_dir
        ld      de,test_appinfo_empty_want
        call    dfio_test_streq
        ld      a,37
        call    t_expect_z

; --- Scenario 12: a DSS call issued from inside another one traps instead
; of firing a second RST_DSS; the outer call still completes afterward. ---
        xor     a
        ld      (test_trap_fired),a
        ld      (test_nested_returned),a
        ld      c,TEST_FN_NESTED
        call    dfio_dss
        ld      a,38
        call    t_expect_nc
        ld      a,(test_trap_fired)
        cp      1
        ld      a,39
        call    t_expect_z
        ld      a,(test_trap_code)
        cp      DFIO_TRAP_REENTRY
        ld      a,40
        call    t_expect_z
        ld      a,(test_nested_returned)
        cp      1
        ld      a,41
        call    t_expect_z
        ld      a,(dfio_v_depth)
        or      a
        ld      a,42
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

; Copies (test_appinfo_ptr) into test_appinfo_string (the mock's actual
; AppInfo source) -- an indirection so the scenario-11 loop can point the
; mock at different canned strings without three near-duplicate .appinfo
; handlers.
dfio_test_set_appinfo_source:
        ld      hl,(test_appinfo_ptr)
        ld      de,test_appinfo_string
.copy:  ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     de
        or      a
        jr      nz,.copy
        ret

; ASCIIZ compare, HL (from spectrum_platform_save_dir's own return) vs DE.
; Z on equal. Clobbers AF, HL, DE.
dfio_test_streq:
        ld      a,(de)
        cp      (hl)
        ret     nz
        or      a
        ret     z
        inc     hl
        inc     de
        jr      dfio_test_streq

; DFIO_TEST_HOOK double (net_gate.asm's s3_test_trap_hook precedent).
dfio_test_trap_hook:
        ld      (test_trap_code),a
        ld      a,1
        ld      (test_trap_fired),a
        ret

; DB strings mix quoted text with explicit hex bytes for '\' (#5c) rather
; than embedding a backslash inside the quotes -- avoids relying on
; whichever escaping convention sjasmplus applies inside string literals
; (the same reason dss_fileio.asm itself uses #5c instead of a '\' char
; literal). ng_trap_msg (net_gate.asm) is the existing precedent for mixing
; quoted segments and literal byte values in one DB.
test_open_path:  DB "01.STJ",0
test_read_buf:   DS 4,0
test_dirent_buf: DS 24,0

test_appinfo_ptr:          DW 0
test_appinfo_no_sep:       DB "C:",#5c,"GAMES",#5c,"SHATRANJ",0
test_appinfo_no_sep_want:  DB "C:",#5c,"GAMES",#5c,"SHATRANJ",#5c,0
test_appinfo_with_sep:     DB "C:",#5c,0
test_appinfo_empty:        DB 0
test_appinfo_empty_want:   DB #5c,0

test_last_find_fn:      DB 0
test_last_input_a:       DB 0
test_trap_code:          DB 0
test_trap_fired:         DB 0
test_nested_returned:    DB 0
test_next_cf: DB 0
test_next_a:  DB 0
test_next_de: DW 0

; Canned 48-byte DSS F_First/F_Next record: ATTR at +32, ASCIIZ DOS name at
; +33, TIME at +22, DATE at +24, SIZE at +28 (dss_equ.inc offsets, verified
; against Estex-DSS directly).
test_find_record:
        ds      22,0
        db      #12,#34                 ; +22 TIME lo/hi
        db      #78,#56                 ; +24 DATE lo/hi
        ds      2,0                     ; +26,+27 unused by this file
        db      #aa,#bb,#cc,#dd         ; +28 SIZE, 4 bytes
        db      #20                     ; +32 ATTR
        db      "A.B",0                 ; +33 ASCIIZ DOS name
        ds      48-(22+2+2+2+4+1+4),0   ; pad to exactly 48 bytes
        assert  $ - test_find_record = 48

        include "dss_fileio.asm"

        end     start
