; HDR runtime header field offsets -- pure constants (no code), so this is
; always safe to INCLUDE before an ORG statement, unlike manifest.inc (which
; also carries manifest_validate code and must be included only after ORG).
;
; The HDR region (fixed_layout.json, HDR_ADDR/HDR_SIZE) is the first
; HDR_SIZE bytes of the resident's own image. preload_loader.asm overwrites
; it in place right before the irreversible SetVMod call (port.md section
; 3.2 step 6), since these values only become known during boot: the
; loader's own GETMEM page table and the video mode DSS was in before
; launch, needed by the resident's own R11 exit path since the loader's
; copy of that state is gone once its WIN2 page is replaced.
;
;   0-3   "SHS1" magic, checked by crt0 before trusting the rest
;   4     HDR_PAGE2: physical page number the trampoline maps into WIN2
;   5     HDR_SAVED_MODE: DSS video mode before launch (GetVMod), for exit
;   6     HDR_SAVED_SCREEN: DSS screen number before launch, for exit
;   7     HDR_ASSET_PAGES: number of asset pages (manifest v2, port.md
;         section 5/S2); 0 on an S1-shaped image with no asset page
;   8+    HDR_ASSET_PAGE0: physical page number of each asset page, one byte
;         per page, HDR_ASSET_PAGES bytes long
;   reserved, zero, from HDR_ASSET_PAGE0_OFFSET+max asset pages to 255

        IFNDEF SPRINTER_HDR_INC
        DEFINE SPRINTER_HDR_INC

HDR_MAGIC_OFFSET         EQU 0
HDR_PAGE2_OFFSET         EQU 4
HDR_SAVED_MODE_OFFSET    EQU 5
HDR_SAVED_SCREEN_OFFSET  EQU 6
HDR_ASSET_PAGES_OFFSET   EQU 7
HDR_ASSET_PAGE0_OFFSET   EQU 8

        ENDIF
