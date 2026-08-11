; Fixed boot handoff target (port.md section 3.10/S5, plan D1/D4). Assembled
; standalone by sjasmplus into its own tiny --raw blob, ORG'd at
; TRAMPOLINE_ADDR (0x4100, right after HDR): preload_loader.asm JPs here
; blindly once it has streamed the resident page and mapped it into WIN1.
;
; Does exactly five things, in order: validate the published HDR magic (the
; loader is the only writer, so this also proves "page streamed intact");
; map WIN2 from HDR_PAGE2; set SP=STACK_TOP; do the two boot-time,
; one-shot probes that used to live in resident_s1.asm's crt0 (canary
; sentinel, BIOS CMOS_TEST -- both trivial and have no natural home in
; either the C image or platform_primitives.asm, since nothing else runs
; before them); then JP unconditionally into C_IMAGE_ENTRY, the fixed entry
; point of the z88dk-built resident C image (asm/sprinter/zcc/
; resident_crt0.asm). Everything past that point -- IM2 install, RTC/
; palette init, the frame loop -- is C's job now, calling back into
; platform_primitives.asm's primitives.
;
; Split out of resident_s1.asm (plan D4): unlike platform_primitives.asm,
; this file's own ORG must start exactly at TRAMPOLINE_ADDR and end well
; before C_IMAGE_ENTRY, so it is assembled and --raw-extracted on its own
; rather than sharing platform_primitives.asm's ORG (which starts at
; PSP_LANDING_END, deep in WIN2) -- gluing the two into one sjasmplus run
; would force a multi-KiB zero-filled gap spanning the entire C image's own
; territory into the middle of the output.

        DEVICE NOSLOT64K
        INCLUDE "dss.inc"
        INCLUDE "fixed_layout.inc"
        INCLUDE "hdr.inc"

; Duplicated from im2_s1.asm (which canary_check also reads this from, in
; platform_primitives.asm's own separate assembly job): trivial constant,
; not an address, so it doesn't belong in fixed_layout.json's region table,
; but the two independently-assembled jobs still need the same value. Keep
; both literals in sync by hand if this ever changes (same convention as
; manifest.inc's asset-page slot layout, shared by hand with
; tools/make_sprinter_exe.py).
CANARY_SENTINEL EQU #5A5A

        ORG     TRAMPOLINE_ADDR

trampoline:
        ld      hl,HDR_ADDR
        ld      de,.magic_ref
        ld      b,4
.magic: ld      a,(de)
        cp      (hl)
        jr      nz,.bad_hdr
        inc     de
        inc     hl
        djnz    .magic
        ld      a,(HDR_ADDR+HDR_PAGE2_OFFSET)
        out     (WIN2_PORT),a
        ld      sp,STACK_TOP

        ld      hl,CANARY_SENTINEL
        ld      (CANARY_ADDR),hl

        ; One-time CMOS probe (im2_s1.asm's canary_check et al. run later,
        ; from C; this one has to happen before rtc_present has a value at
        ; all). DSS SysTime never reports a missing clock on its own (its
        ; .NOCMOS path returns compile-time defaults with CF=0), so
        ; platform_primitives.asm's rtc_sample gates on this flag instead.
        ld      c,BIOS_CMOS_TEST
        rst     RST_BIOS
        ld      a,0
        jr      c,.no_cmos
        inc     a
.no_cmos:
        ld      (RTC_PRESENT_ADDR),a

        jp      C_IMAGE_ENTRY_ADDR

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
.msg:   DB 13,10,"Sprinter S5: resident HDR check failed.",13,10,0

        ASSERT  $ <= C_IMAGE_ENTRY_ADDR
        END     trampoline
