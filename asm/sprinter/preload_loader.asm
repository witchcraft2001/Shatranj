; Sprinter PRELOAD loader for the S1 platform stand (port.md section 3.2).
;
; Runs from WIN2 (the first SetVMod would otherwise destroy WIN1 --
; HW_NOTES.md:435), streams the resident's 16 KiB pages through WIN1, then
; hands off to the resident's own trampoline at TRAMPOLINE_ADDR. Mirrors the
; proven pattern in sources/weather-forecast/src/weather_loader.asm (strict-
; equality reads, DSS-error-is-carry convention); adapted for a flat 2-page
; resident with no compression, streamed via WIN1 instead of WIN3.
;
; This file assembles to pure code starting at LD_ADDR, with no embedded
; EXE header: tools/make_sprinter_exe.py builds the 512-byte header itself
; (same convention as the S0 stub_main.asm it replaces), so the raw --loader
; input it takes is exactly this file's --raw output.

        DEVICE NOSLOT64K
        INCLUDE "dss.inc"               ; constants only, safe before ORG
        INCLUDE "fixed_layout.inc"      ; constants only, safe before ORG;
                                         ; self-guarded (build/sprinter/generated)

LD_ADDR            EQU #8100
LOADER_SP          EQU #BFF0

        ORG     LD_ADDR
LOADER_START:
        ld      sp,LOADER_SP
        ld      a,(ix-3)                ; DSS PRELOAD file handle
        ld      (l_file_handle),a

        ; Save video mode/screen and WIN1/WIN3 pages before anything else
        ; can disturb them (port.md section 3.2 step 1).
        ld      c,DSS_GETVMOD
        rst     RST_DSS
        jp      c,l_fail
        ld      (l_saved_mode),a
        ld      a,b
        ld      (l_saved_screen),a
        in      a,(WIN1_PORT)
        ld      (l_saved_win1),a
        in      a,(WIN3_PORT)
        ld      (l_saved_win3),a

        ld      hl,l_banner
        ld      c,DSS_PCHARS
        rst     RST_DSS

        ; Step 2: read and validate the 32-byte STM1 manifest, which
        ; immediately follows this loader body in the file.
        ld      hl,l_manifest
        ld      de,MANIFEST_SIZE
        call    l_read_exact
        jp      c,l_fail
        ld      hl,l_manifest
        call    manifest_validate
        jp      c,l_fail
        ld      a,b                     ; B = validated total page_count
        ld      (l_page_count),a
        ld      a,e                     ; E = validated asset page count
        ld      (l_asset_pages),a
        ld      a,b
        sub     e                       ; resident page count = total - asset
        ld      (l_resident_pages),a
        dec     a
        ld      (l_last_page_index),a   ; PSP lands on the last RESIDENT page,
                                         ; not the last page overall (asset
                                         ; pages carry no runnable code)

        ; Step 3: one GETMEM allocation for every resident page; physical
        ; pages resolved via BIOS GetMemBlkPages (port.md sections 3.1/3.2).
        ld      a,(l_page_count)
        ld      b,a
        ld      c,DSS_GETMEM
        rst     RST_DSS
        jp      c,l_fail
        ld      (l_block_handle),a
        ld      a,1
        ld      (l_block_allocated),a
        ld      a,(l_block_handle)
        ld      hl,l_physical_pages
        ld      c,BIOS_GETMEMBLKPAGES
        rst     RST_BIOS
        jp      c,l_fail

        ; Step 4: stream each page through WIN1, 16 KiB at a time.
        xor     a
        ld      (l_page_index),a
.page_loop:
        ld      a,(l_page_index)
        ld      hl,l_physical_pages
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(hl)
        cp      #FF
        jp      z,l_fail                ; fewer physical pages than page_count
        di
        out     (WIN1_PORT),a
        ei
        ld      hl,#4000
        ld      de,MANIFEST_PAGE_SIZE
        call    l_read_exact
        jp      c,l_fail

        ; The last page becomes WIN2 at runtime; land the PSP there so
        ; AppInfo keeps working once this page replaces the loader's own
        ; WIN2 mapping (weather_loader.asm:113-120 pattern).
        ld      a,(l_page_index)
        ld      hl,l_last_page_index
        cp      (hl)
        jr      nz,.next_page
        ld      hl,#8000
        ld      de,#4000
        ld      bc,PSP_LANDING_SIZE
        ldir
.next_page:
        ld      hl,l_page_index
        inc     (hl)
        ld      a,(hl)
        ld      hl,l_page_count
        cp      (hl)
        jp      c,.page_loop

        ; Publish the boot header into page 0 (the WIN1 half) before the
        ; irreversible SetVMod call (port.md section 3.2 step 6), while
        ; WIN0/SP are still canonical.
        ld      a,(l_physical_pages)
        di
        out     (WIN1_PORT),a
        ei
        ld      hl,l_hdr_magic
        ld      de,#4000
        ld      bc,4
        ldir
        ; HDR_PAGE2 is the physical number of the last RESIDENT page (the
        ; one the trampoline maps into WIN2 at runtime) -- l_last_page_index
        ; already holds that page's index into l_physical_pages.
        ld      a,(l_last_page_index)
        ld      hl,l_physical_pages
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(hl)
        ld      (HDR_ADDR+HDR_PAGE2_OFFSET),a
        ld      a,(l_saved_mode)
        ld      (HDR_ADDR+HDR_SAVED_MODE_OFFSET),a
        ld      a,(l_saved_screen)
        ld      (HDR_ADDR+HDR_SAVED_SCREEN_OFFSET),a

        ; Publish the asset pages' physical numbers (manifest v2, port.md
        ; section 5/S2): they stream right after the resident pages, so
        ; l_physical_pages[resident_pages .. total_page_count-1] is the list.
        ld      a,(l_asset_pages)
        ld      (HDR_ADDR+HDR_ASSET_PAGES_OFFSET),a
        ld      c,a
        ld      b,0
        ld      a,c
        or      a
        jr      z,.no_asset_pages
        ld      a,(l_resident_pages)
        ld      hl,l_physical_pages
        ld      e,a
        ld      d,0
        add     hl,de                   ; HL -> first asset page's entry
        ld      de,HDR_ADDR+HDR_ASSET_PAGE0_OFFSET
        ldir
.no_asset_pages:

        ; Step 6 (R10): program both screens before handoff.
        ld      b,1
        ld      a,DSS_VMOD_G640
        ld      c,DSS_SETVMOD
        rst     RST_DSS
        jp      c,l_fail
        ld      b,0
        ld      a,DSS_VMOD_G640
        ld      c,DSS_SETVMOD
        rst     RST_DSS
        jp      c,l_fail

        ; Step 7: close the file, map WIN1 to page 0, hand off to the
        ; resident's trampoline. DSS pushes RETFAR on entry, so this code
        ; never returns to it -- only the resident's own exit path (R11)
        ; leaves via DSS_EXIT.
        ld      a,(l_file_handle)
        ld      c,DSS_CLOSE_FILE
        rst     RST_DSS
        ld      a,#FF
        ld      (l_file_handle),a

        di
        ld      a,(l_physical_pages)
        out     (WIN1_PORT),a
        jp      TRAMPOLINE_ADDR

        ; manifest.inc emits real code (manifest_validate) and data (the
        ; "STM1" magic): it must be included here, after ORG LD_ADDR, or its
        ; bytes end up at address 0 instead of inside this loader body.
        INCLUDE "manifest.inc"

; HL=destination, DE=expected bytes. Carry on DSS error or any size
; mismatch (weather_loader.asm's strict-equality contract, not a retry
; loop: a short read is treated as fatal).
l_read_exact:
        ld      (l_expected),de
        ld      a,(l_file_handle)
        ld      c,DSS_READ_FILE
        rst     RST_DSS
        ret     c
        ld      hl,(l_expected)
        or      a
        sbc     hl,de
        ret     z
        scf
        ret

l_fail:
        ei
        ld      a,(l_saved_screen)
        ld      b,a
        ld      a,(l_saved_mode)
        ld      c,DSS_SETVMOD
        rst     RST_DSS
        ld      a,(l_saved_win1)
        di
        out     (WIN1_PORT),a
        ei
        ld      a,(l_saved_win3)
        di
        out     (WIN3_PORT),a
        ei
        ld      a,(l_file_handle)
        cp      #FF
        jr      z,.no_file
        ld      c,DSS_CLOSE_FILE
        rst     RST_DSS
        ld      a,#FF
        ld      (l_file_handle),a
.no_file:
        ld      a,(l_block_allocated)
        or      a
        jr      z,.no_block
        xor     a
        ld      (l_block_allocated),a
        ld      a,(l_block_handle)
        ld      c,DSS_FREEMEM
        rst     RST_DSS
.no_block:
        ld      hl,l_fail_msg
        ld      c,DSS_PCHARS
        rst     RST_DSS
        ld      b,1
        ld      c,DSS_EXIT
        rst     RST_DSS

l_banner: DB "Shatranj Sprinter S1 stand: loading...",13,10,0
l_fail_msg: DB 13,10,"Sprinter S1 loader: boot failed.",13,10,0
l_hdr_magic: DB "SHS1"

l_file_handle:     DB #FF
l_saved_mode:       DB 0
l_saved_screen:     DB 0
l_saved_win1:       DB 0
l_saved_win3:       DB 0
l_block_handle:     DB 0
l_block_allocated:  DB 0
l_page_count:       DB 0
l_asset_pages:      DB 0
l_resident_pages:   DB 0
l_page_index:       DB 0
l_last_page_index:  DB 0
l_expected:         DW 0
l_manifest:         DS MANIFEST_SIZE, 0
; BIOS GetMemBlkPages documents a 256-byte buffer (FUNC_RAM_ROM_DRV.ASM):
; with a valid handle it writes page_count+1 bytes, but a corrupted chain
; may legally fill all 256 -- reserve the full contract size.
l_physical_pages:   DS 256, #FF

LOADER_SIZE EQU $ - LOADER_START
        ASSERT  LOADER_SIZE < (LOADER_SP - LD_ADDR)
        END     LOADER_START
