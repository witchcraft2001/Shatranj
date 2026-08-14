; dss_fileio.asm -- esx-ABI-over-DSS file I/O gate (S6, port.md section
; 3.10 item 4 / S6 plan step 1). WIN2-resident: INCLUDEd from
; platform_primitives.asm, the same half net_gate.asm already lives in, and
; for the same reason -- these esx_* entry points are called from the
; SAVELOAD/RESTORE/FILEUI overlays, which run mode-1 (WIN3 mapped to their
; own linked page, overlay_loader_sprinter.asm), so the gate itself must not
; depend on anything WIN3-resident.
;
; Reimplements asm/esxdos/esx_fileio_spectalk.asm's exact ABI (globals
; esx_handle/esx_buf/esx_count/esx_result; esx_fopen/esx_fcreate/esx_fread/
; esx_fwrite/esx_fclose/esx_funlink/esx_opendir/esx_readdir, every entry
; preserving IX/IY) over Estex-DSS's own file functions (dss.inc's RST
; RST_DSS, C=function, CF=1 -> A=error), instead of z88dk's esxDOS trap.
; One superset module -- unlike ZX's two IFDEF'd (ESX_FILEUI vs not)
; subsets -- because a single Sprinter WIN3 page hosts all three
; file-touching overlays and none of them needs a slimmer build.
;
; Handle numbering: DSS's own file handles are zero-based (0 is a valid
; handle), but the esx ABI treats handle==0 as "no file"/error (every ZX
; caller checks `if (esx_handle == 0)`). So esx_handle always stores the
; DSS handle plus one; esx_fclose/esx_fread/esx_fwrite subtract it back off
; before the RST.
;
; DSS has no directory-handle concept the way esxDOS's F_OPENDIR/F_READDIR
; do -- Estex-DSS's F_First/F_Next (dss.inc's DSS_F_FIRST/DSS_F_NEXT) take a
; path+mask and a 48-byte scratch record each call, with no separate "open"
; step. esx_opendir/esx_readdir are therefore a small state machine here:
; opendir builds a "dir*.* " mask into dfio_mask_buf and always reports
; success (there is no cheap way to fail it up front; a genuinely bad path
; just makes the first esx_readdir come back empty, which every caller
; already treats as "no files" -- fileui_ovl.c's own end-of-listing path);
; readdir issues F_First on its first call (dfio_started latches this) and
; F_Next afterward, then translates the 48-byte DSS record into the
; esxDOS-shaped dirent fileui_ovl.c's fileui_entry_stj already parses:
; attr byte, ASCIIZ 8.3 name, 2B time, 2B date, 4B size -- straight from
; dss_equ.inc's own record layout (ATTR +32, name +33, TIME +22, DATE +24,
; SIZE +28, cross-checked against the Estex-DSS source directly, not just
; sprinter_ai_doc -- CLAUDE.md section 4's own warning about that doc).
;
; Every call funnels through dfio_dss: push ix/iy around the RST (Read/
; Write clobber IX, port.md section 3.10), EI immediately before the RST
; and DI immediately after (Estex-DSS's disk/task bookkeeping is written to
; run interruptible -- this port's IM2 stub already tail-jumps to DSS's own
; #0038 handler for anything that is not a frame tick, im2_s1.asm's own
; key_poll precedent, and no Create/Open/Close/Write/Find DSS routine
; touches SLOT2/WIN2, grep-checked against the Estex-DSS sources directly,
; so im2_s1.asm's own WIN2 standing invariant stays satisfied).
;
; S6 round 6 (docs/sprinter-testnotes/S6.md): the file's ACTUAL bug, found
; by re-reading this funnel itself rather than diffing against another
; branch -- dfio_v_depth's own reentry-guard bookkeeping
; (`ld a,(dfio_v_depth) / or a / ... / ld a,1 / ld (dfio_v_depth),a`) ran
; BEFORE the `push af` that was supposed to capture the caller's real DSS
; argument, so it clobbered A first. Every esx_* call reached RST_DSS with
; A=1 (dfio_v_depth's own "in progress" marker), never the caller's actual
; handle/mode/attribute/search-mask. esx_fopen's A=DSS_OPEN_MODE_READ (1)
; happened to match by coincidence, masking the bug there; esx_fclose's
; computed handle did not, in general -- closing the WRONG file manipulator
; slot (a constant 1, not whatever DSS actually assigned this file) is
; exactly the kind of thing Estex-DSS's own Close.asm guards against: it
; checks the closed slot's stamped owning task against the current one and
; returns ACCESS_DENIED (19, dss_equ.inc) on a mismatch -- e.g. slot 1
; belonging to some other still-open handle (the parent shell's) rather
; than the file this port just created. That is "Save failed:IO:19" end to
; end: create succeeds (0-length file appears, since its own directory-size
; flush lives in Close and Close never legitimately reaches that file's own
; record), write and close both silently operate on an unrelated handle.
; Fixed by stashing the caller's A in dfio_call_arg_a before the depth
; bookkeeping touches A at all, and reloading it right before the RST.
;
; A previous attempt this same round (diffing against the abandoned
; sprinter-port branch's own disk gate) added an `IN A,(PORT_CACHE_OFF)`
; here, reasoning that Sprinter's WIN0 SRAM cache latch might be left on.
; Wrong direction: the cache defaults OFF and nothing in this port ever
; turns it on, so if it had been on, the very first RST_DSS this process
; ever issues (AppInfo's own home-dir query, called directly at boot,
; before any esx_* call) would already have jumped into stale SRAM instead
; of DSS's kernel -- boot would never have completed, key_poll's own
; SCANKEY would not have kept working every frame. That fix has been
; removed (PORT_CACHE_ON/OFF constants dropped from dss.inc too); leaving
; it in would have been touching a port to no effect, exactly the kind of
; unfounded change this project's own review culture rejects.
;
; WIN3 gets remapped back to WHATEVER IT WAS AT ENTRY afterward
; UNCONDITIONALLY, under DI again by then. DSS's own Read/Write internally
; save/restore SLOT3 (=WIN3) via IN/OUT around their sub-sector buffer
; detour (Estex-DSS Read.asm/Write.asm), so in the common case this remap
; rewrites the value already there -- a cheap defensive belt, not a
; load-bearing fix, pinned by t_dss_fileio.asm's WIN3-clobbering RST stub.
; The remap touches only A/F (push af around it), so it never disturbs a
; DSS output register a caller still needs (DE for Read's byte count, in
; particular).
;
; S8 step 8b fix: this used to restore a hardcoded (ovl_win3_page) instead
; of what was actually mapped at entry -- already wrong whenever the
; CALLER was the WIN3 cold page (session_sprinter.c's own callers, whose
; page is cold_win3_page, not ovl_win3_page) or, since this same step, the
; NET overlay's own second page (ovl_win3_page2). Every caller of esx_*
; happens to be a mode-1 overlay today, so the bug never surfaced in
; practice, but "happens to be right for the callers that exist so far" is
; exactly the kind of latent defect this project's own review culture does
; not leave in place once found (CLAUDE.md section 2 item 3: a discovered
; defect stops the change until understood). Fixed the same way
; overlay_loader_sprinter.asm's own mode-1 dispatch already does it: save
; what was read (dfio_saved_win3), restore that, never a constant.
;
; A reentry guard (dfio_v_depth) mirrors net_gate.asm's ng_call_reentry --
; nothing here is expected to call dfio_dss recursively in normal
; operation (every esx_* call happens synchronously under DI, never from an
; ISR), so a nested call can only mean a bug; it traps instead of
; corrupting the depth-guarded state silently.

        INCLUDE "dss.inc"      ; guarded (IFNDEF), same self-include
                                ; precedent as net_gate.asm

DFIO_TRAP_REENTRY EQU 1

; Common funnel. In: C=DSS function number, plus whatever A/B/HL/DE that
; function needs (dss.inc's own per-function comments); caller preloads
; them before calling. Out: exactly what the underlying DSS call left in
; AF/BC/DE/HL (this funnel does not touch those beyond the IX/IY save and
; the WIN3 remap, both of which preserve AF around themselves).
dfio_dss:
        ld      (dfio_call_arg_a),a     ; caller's real DSS argument (handle
                                         ; /mode/attribute/search-mask) --
                                         ; must survive the depth-check
                                         ; below, which needs A for itself
                                         ; (S6 round 6, this file's own
                                         ; banner: it did not survive before)
        ld      a,(dfio_v_depth)
        or      a
        jr      nz,dfio_dss_reentry
        ld      a,1
        ld      (dfio_v_depth),a

        in      a,(WIN3_PORT)           ; S8 step 8b: save what the CALLER
        ld      (dfio_saved_win3),a     ; had mapped, not a fixed guess

        push    ix
        push    iy
        ld      a,(dfio_call_arg_a)
        ei
        rst     RST_DSS
        di
        pop     iy
        pop     ix

        push    af                      ; DSS's CF/A result, carried past
        jr      nc,dfio_no_error        ; the remap untouched
        ld      (dfio_last_error),a     ; S6 round 5: last raw DSS error
                                         ; code (dss_errors.z80's own
                                         ; numbering), for spectrum_
                                         ; platform_last_dss_error below --
                                         ; a diagnostic-only side channel,
                                         ; never read by anything that
                                         ; changes control flow here.
dfio_no_error:
        ld      a,(dfio_saved_win3)
        out     (WIN3_PORT),a
        pop     af

        push    af
        xor     a
        ld      (dfio_v_depth),a
        pop     af
        ret

dfio_dss_reentry:
        IFDEF   DFIO_TEST_HOOK
        ld      a,DFIO_TRAP_REENTRY
        call    dfio_test_trap_hook
        ret
        ELSE
        ld      a,DFIO_TRAP_REENTRY
        jp      dfio_trap_screen
        ENDIF

; Fatal screen: dss_fileio reentrancy trap fired. Same shape as
; net_gate.asm's ng_trap_screen (im2_uninstall before a T40 message --
; svmod_safe/im2_uninstall are both already in scope, defined earlier in
; this same platform_primitives.asm assembly job).
dfio_trap_screen:
        di
        call    im2_uninstall
        ld      b,0
        ld      a,DSS_VMOD_T40
        call    svmod_safe
        ld      hl,dfio_trap_msg
        ld      c,DSS_PCHARS
        rst     RST_DSS
        ld      b,1
        ld      c,DSS_EXIT
        rst     RST_DSS
.hang:  jr      .hang

dfio_trap_msg: DB 13,10,"Sprinter S6: dss_fileio reentrancy trap.",13,10,0

dfio_v_depth: DB 0
dfio_call_arg_a: DB 0
dfio_saved_win3: DB 0

; S6 round 5 (docs/sprinter-testnotes/S6.md "MAME round 5"): "Save
; failed:IO" alone doesn't say whether Estex-DSS's own Write/Close refused
; because the media is write-protected, full, unready, or something else --
; dss_errors.z80 enumerates ~40 distinct causes by number (24 = write
; protected, 10 = no free space, 26 = write error, ...), and dfio_dss above
; already sees that number in A on every CF=1 return; it was just being
; thrown away. Last-error-wins across a save's create/write/close sequence
; (whichever esx_* call most recently failed) -- a diagnostic aid, not a
; result code any caller branches on, so an occasional stale value from an
; unrelated earlier call (only possible if write succeeds, close succeeds,
; but the byte count still mismatches -- saveload_ovl.c's own ERR_IO check)
; is an acceptable rough edge, not a correctness bug.
dfio_last_error: DB 0

; const char *spectrum_platform_last_dss_error_text(void). Formats dfio_
; last_error as a 1-2 digit decimal ASCIIZ string into a static buffer and
; returns a pointer to it (same zero-arg/HL-return convention as this
; file's own spectrum_platform_save_dir below). Formatting lives here, in
; asm, rather than as sccz80-compiled arithmetic in main.c: the resident C
; image had only 113 bytes of headroom left after this round's other
; diagnostics, and a manual tens/ones loop compiled through sccz80 alone
; overran the 16000-byte budget by 79 bytes (measured) -- this file's own
; WIN2-resident space is not nearly as tight.
spectrum_platform_last_dss_error_text:
        ld      a,(dfio_last_error)
        ld      b,0                     ; tens digit
.tens_loop:
        cp      10
        jr      c,.ones
        sub     10
        inc     b
        jr      .tens_loop
.ones:  ld      c,a                     ; ones digit, A now free
        ld      hl,dfio_last_error_text
        ld      a,b
        or      a
        jr      z,.skip_tens
        add     a,'0'
        ld      (hl),a
        inc     hl
.skip_tens:
        ld      a,c
        add     a,'0'
        ld      (hl),a
        inc     hl
        ld      (hl),0
        ld      hl,dfio_last_error_text
        ret

dfio_last_error_text: DS 4,0

; ---------------------------------------------------------------------------
; esx ABI globals (asm/esxdos/esx_fileio_spectalk.asm's own names/sizes).
; ---------------------------------------------------------------------------
esx_handle: DB 0
esx_buf:    DW 0
esx_count:  DW 0
esx_result: DW 0

; ---------------------------------------------------------------------------
; esx_fopen/esx_fcreate: void(const char *path) __z88dk_fastcall (path in
; HL). Out: esx_handle = DSS handle + 1, or 0 on error.
; ---------------------------------------------------------------------------
esx_fopen:
        push    iy
        push    ix
        ld      a,DSS_OPEN_MODE_READ
        ld      c,DSS_OPEN_FILE
        call    dfio_dss
        jr      dfio_store_handle

esx_fcreate:
        push    iy
        push    ix
        xor     a                       ; attribute 0: plain file
        ld      c,DSS_CREATE_FILE
        call    dfio_dss
                                         ; falls into dfio_store_handle

dfio_store_handle:
        jr      c,.err
        inc     a                       ; N+1 (DSS handle 0 is valid; esx
        jr      .store                  ; ABI treats 0 as "no file")
.err:   xor     a
.store: ld      (esx_handle),a
        pop     ix
        pop     iy
        ret

; void esx_fclose(void). In: esx_handle. Out: L = 0 ok / 0xFF error
; (asm/esxdos/esx_fileio_spectalk.asm's own "sbc a,a" idiom, matched here).
esx_fclose:
        push    iy
        push    ix
        ld      a,(esx_handle)
        dec     a                       ; back to the DSS handle
        ld      c,DSS_CLOSE_FILE
        call    dfio_dss
        sbc     a,a
        ld      l,a
        pop     ix
        pop     iy
        ret

; void esx_fread(void). In: esx_handle, esx_buf, esx_count. Out: esx_result
; = bytes actually read (0 on error) -- DSS Read's own DE output, unlike
; Write's (port.md section 3.10 item 4).
esx_fread:
        push    iy
        push    ix
        ld      a,(esx_handle)
        dec     a
        ld      hl,(esx_buf)
        ld      de,(esx_count)
        ld      c,DSS_READ_FILE
        call    dfio_dss
        jr      nc,.ok
        ld      de,0
.ok:    ld      (esx_result),de
        pop     ix
        pop     iy
        ret

; void esx_fwrite(void). In: esx_handle, esx_buf, esx_count. Out: esx_result
; = esx_count on success (Write's own DE is not trustworthy -- port.md
; section 3.10 item 4; success is CF=0 alone), 0 on error.
esx_fwrite:
        push    iy
        push    ix
        ld      a,(esx_handle)
        dec     a
        ld      hl,(esx_buf)
        ld      de,(esx_count)
        ld      c,DSS_WRITE_FILE
        call    dfio_dss
        ld      de,0
        jr      c,.store
        ld      de,(esx_count)
.store: ld      (esx_result),de
        pop     ix
        pop     iy
        ret

; void esx_funlink(const char *path) __z88dk_fastcall (path in HL). Out:
; esx_result = 1 ok / 0 error.
esx_funlink:
        push    iy
        push    ix
        ld      c,DSS_DELETE_FILE
        call    dfio_dss
        ld      de,1
        jr      nc,.store
        ld      de,0
.store: ld      (esx_result),de
        pop     ix
        pop     iy
        ret

; void esx_opendir(const char *path) __z88dk_fastcall (path in HL). Builds
; the F_First/F_Next mask (path + "*.*") in dfio_mask_buf; always reports
; success (esx_handle = 1) -- see this file's own banner for why. Resets
; dfio_started so the next esx_readdir issues F_First, not F_Next.
esx_opendir:
        push    iy
        push    ix
        ld      de,dfio_mask_buf
        ld      bc,DFIO_MASK_COPY_MAX
.copy:  ld      a,(hl)
        or      a
        jr      z,.copied
        ld      (de),a
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.copy
.copied:
        ld      hl,dfio_mask_suffix
        ld      bc,4                    ; "*.*" + NUL
        ldir
        ld      a,1
        ld      (esx_handle),a
        xor     a
        ld      (dfio_started),a
        pop     ix
        pop     iy
        ret

dfio_mask_suffix: DB "*.*",0

; void esx_readdir(void). In: esx_handle (nonzero after esx_opendir),
; esx_buf = destination buffer (>=24 bytes, asm/esxdos/esx_fileio_spectalk.
; asm's own contract). Out: esx_result = 1 (entry written to esx_buf) / 0
; (end of listing or error).
esx_readdir:
        push    iy
        push    ix
        ld      a,(esx_handle)
        or      a
        jr      z,.none
        ld      a,(dfio_started)
        or      a
        jr      nz,.next
        ld      a,1
        ld      (dfio_started),a
        ld      hl,dfio_mask_buf
        ld      de,dfio_find_buf
        ld      b,1                     ; DOS name format ("name.ext",0)
        ld      a,DSS_FIND_ATTR_FILE    ; dss.inc's own comment: A=0 hides
                                         ; every file this port ever writes
        ld      c,DSS_F_FIRST
        call    dfio_dss
        jr      .after
.next:  ld      de,dfio_find_buf
        ld      c,DSS_F_NEXT
        call    dfio_dss
.after: jr      c,.none

        ld      hl,(esx_buf)
        ld      a,(dfio_find_buf+32)    ; ATTR (dss_equ.inc offset +32)
        ld      (hl),a
        inc     hl
        ld      de,dfio_find_buf+33     ; ASCIIZ DOS name (offset +33)
.namecopy:
        ld      a,(de)
        ld      (hl),a
        inc     hl
        inc     de
        or      a
        jr      nz,.namecopy
        ex      de,hl                   ; LDIR copies (HL)->(DE): de = the
                                         ; dirent write position just built
                                         ; above, hl takes the source below
        ld      hl,dfio_find_buf+22     ; TIME(2)+DATE(2), verbatim
        ld      bc,4
        ldir
        ld      hl,dfio_find_buf+28     ; SIZE(4) -- offsets 26/27 sit
        ld      bc,4                    ; between DATE and SIZE and are not
        ldir                            ; part of this dirent, verbatim
        ld      de,1
        ld      (esx_result),de
        jr      .done
.none:  ld      de,0
        ld      (esx_result),de
.done:  pop     ix
        pop     iy
        ret

DFIO_MASK_BUF_SIZE  EQU 72
DFIO_MASK_COPY_MAX  EQU DFIO_MASK_BUF_SIZE-4   ; room for "*.*"+NUL

dfio_started:  DB 0
dfio_mask_buf: DS DFIO_MASK_BUF_SIZE,0
dfio_find_buf: DS 48,0

; ---------------------------------------------------------------------------
; FAT date/time shims (saveload_ovl.c's saveload_write_stamp). This file
; used to also host spectrum_net_background_drain as an S6-era no-op
; ("called between esx_* I/O steps so a future networked build can
; service traffic while blocked on disk"); S7 superseded it with a real
; implementation (unet_link.c's nc_pump, WIN1) -- SAVELOAD/FILEUI overlays
; now resolve that name via gen_sprinter_overlay_defs.py's resident_c.map
; bridge instead of this sjasmplus one, the same way they already reach
; netchess_after_prefix.
; ---------------------------------------------------------------------------

; uint16_t spectrum_net_runtime_fat_date(void). Standard FAT date packing
; (bits15-9 year-1980, bits8-5 month, bits4-0 day) from rtc_sample's cached
; rtc_day/rtc_month/rtc_year (video.asm). Returns 0 if the clock was never
; sampled successfully or the sampled year predates 1980 -- saveload_ovl.c's
; own saveload_stamp_valid then reads that as "no timestamp" and blanks the
; stamp rather than writing garbage digits.
spectrum_net_runtime_fat_date:
        ld      a,(rtc_valid)
        or      a
        jr      z,.zero
        ld      hl,(rtc_year)
        ld      de,1980
        or      a
        sbc     hl,de
        jr      c,.zero
        ld      a,l
        and     #7f                     ; FAT's year field is 7 bits
        ld      l,a
        ld      h,0
        ld      b,9
.shl9:  add     hl,hl
        djnz    .shl9
        ld      a,(rtc_month)
        and     #0f
        ld      e,a
        ld      d,0
        ld      b,5
.shl5:  add     de,de
        djnz    .shl5
        add     hl,de
        ld      a,(rtc_day)
        and     #1f
        ld      e,a
        ld      d,0
        add     hl,de
        ret
.zero:  ld      hl,0
        ret

; uint16_t spectrum_net_runtime_fat_time(void). Standard FAT time packing
; (bits15-11 hour, bits10-5 minute, bits4-0 seconds/2) from rtc_sample's
; cached rtc_hour/rtc_minute/rtc_second.
spectrum_net_runtime_fat_time:
        ld      a,(rtc_valid)
        or      a
        jr      z,.zero
        ld      a,(rtc_hour)
        and     #1f
        ld      l,a
        ld      h,0
        ld      b,11
.shl11: add     hl,hl
        djnz    .shl11
        ld      a,(rtc_minute)
        and     #3f
        ld      e,a
        ld      d,0
        ld      b,5
.shl5:  add     de,de
        djnz    .shl5
        add     hl,de
        ld      a,(rtc_second)
        and     #3e                     ; drop the odd bit, FAT stores /2
        srl     a
        ld      e,a
        ld      d,0
        add     hl,de
        ret
.zero:  ld      hl,0
        ret

; ---------------------------------------------------------------------------
; Save directory (S6 design decision: saves live next to the EXE, resolved
; once at boot via DSS AppInfo's home-dir query -- Estex-DSS AppInfo.asm's
; B=1 sub-function, verified against that source: caller sets HL=destination
; buffer, DSS LDIRs the ASCIIZ home directory into it).
; ---------------------------------------------------------------------------

; void spectrum_platform_save_dir_init(void). Populates dss_save_dir once;
; call exactly once at boot (src/sprinter/main.c), before any esx_fopen/
; esx_fcreate/esx_opendir path built from spectrum_platform_save_dir()'s
; result. Normalizes a missing trailing '\' (AppInfo's returned path is not
; guaranteed to end in one -- this file's own risk note).
;
; Deliberately bypasses dfio_dss: it is a one-time boot call, made before
; any overlay -- and therefore any mode-1 WIN3 dispatch -- has ever run, so
; there is nothing for the post-RST WIN3 remap to protect yet.
spectrum_platform_save_dir_init:
        ld      hl,dss_save_dir
        ld      b,DSS_APPINFO_EXE_HOMEDIR
        ld      c,DSS_APPINFO
        rst     RST_DSS
        ld      hl,dss_save_dir
.scan:  ld      a,(hl)
        or      a
        jr      z,.atend
        inc     hl
        jr      .scan
.atend: ld      de,dss_save_dir
        or      a
        sbc     hl,de
        jr      z,.empty                ; empty path: write "\" at offset 0
        add     hl,de                   ; hl = NUL address again
        push    hl
        dec     hl
        ld      a,(hl)
        pop     hl
        cp      #5c                     ; '\' -- hex literal, no assembler
        ret     z                       ; quoting ambiguity (already ends
        jr      .write                  ; in '\')
.empty: ld      hl,dss_save_dir
.write: ld      (hl),#5c                ; '\'
        inc     hl
        ld      (hl),0
        ret

; const char *spectrum_platform_save_dir(void)
spectrum_platform_save_dir:
        ld      hl,dss_save_dir
        ret

DSS_SAVE_DIR_SIZE EQU 68
dss_save_dir: DS DSS_SAVE_DIR_SIZE,0
