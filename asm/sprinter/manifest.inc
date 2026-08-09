; STM1 boot manifest v2: 32 bytes written by tools/make_sprinter_exe.py right
; after the primary loader body in the EXE file, read explicitly by
; preload_loader.asm once the DSS PRELOAD read has already delivered the
; loader itself (port.md section 3.2). manifest_validate is shared by the
; loader and tests/sprinter/z80/t_manifest.asm so both check the exact same
; byte layout. See hdr.inc for the separate runtime HDR header format (the
; loader also writes that, but hdr.inc carries no code, so it stays safe to
; INCLUDE before an ORG statement -- this file is not).
;
;   0-3   "STM1" magic
;   4     format version (2)
;   5     total page count: the loader streams exactly this many 16 KiB
;         pages through WIN1, regardless of what they contain (resident
;         code or an asset page -- port.md section 5/S2)
;   6-7   entry address (LE) -- must equal TRAMPOLINE_ADDR
;   8-9   payload size in MANIFEST_PAYLOAD_UNIT-byte units (LE) -- must
;         equal page_count * (MANIFEST_PAGE_SIZE/MANIFEST_PAYLOAD_UNIT).
;         v1 encoded this in raw bytes, which wraps a 16-bit field past 3
;         pages (4*16384 = 65536); 256-byte units push that ceiling past
;         1000 pages.
;   10    asset page count; must be strictly less than the total page count
;         (at least one resident page). resident page count = total - asset.
;         Resident pages stream first, asset pages follow (preload_loader.asm
;         lands the PSP on the last RESIDENT page and publishes the asset
;         pages' physical numbers into HDR, not the last page overall).
;   11-31 reserved, zero

        IFNDEF SPRINTER_MANIFEST_INC
        DEFINE SPRINTER_MANIFEST_INC

        INCLUDE "fixed_layout.inc"
        INCLUDE "hdr.inc"

MANIFEST_SIZE               EQU 32
MANIFEST_VERSION            EQU 2
MANIFEST_PAGE_SIZE          EQU #4000
MANIFEST_PAYLOAD_UNIT       EQU 256
MANIFEST_MAGIC_OFFSET       EQU 0
MANIFEST_VERSION_OFFSET     EQU 4
MANIFEST_PAGES_OFFSET       EQU 5
MANIFEST_ENTRY_OFFSET       EQU 6
MANIFEST_PAYLOAD_OFFSET     EQU 8
MANIFEST_ASSET_PAGES_OFFSET EQU 10

; HL = 32-byte manifest buffer (preserved). Returns CF=1 on any mismatch
; (bad magic, version, entry address, a payload size that isn't
; page_count * (MANIFEST_PAGE_SIZE/MANIFEST_PAYLOAD_UNIT), or an asset page
; count that isn't strictly less than the total page count); CF=0,
; B=total page count and E=asset page count on success. Clobbers AF, BC, DE.
manifest_validate:
        push    hl                     ; original buffer pointer, restored below
        ld      de,manifest_magic
        ld      b,4
.magic: ld      a,(de)
        cp      (hl)
        jr      nz,.bad
        inc     de
        inc     hl
        djnz    .magic
        ld      a,(hl)
        cp      MANIFEST_VERSION
        jr      nz,.bad
        inc     hl
        ld      a,(hl)                  ; page count
        or      a
        jr      z,.bad
        ld      c,a                     ; C = page count
        inc     hl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)                  ; DE = entry address
        inc     hl
        ld      a,e
        cp      low TRAMPOLINE_ADDR
        jr      nz,.bad
        ld      a,d
        cp      high TRAMPOLINE_ADDR
        jr      nz,.bad
        ld      a,(hl)
        inc     hl
        ld      e,a
        ld      d,(hl)                  ; DE = declared payload size (256-B units)
        inc     hl                      ; HL -> offset 10 (asset page count)
        ld      a,(hl)
        ld      (.asset_pages),a        ; stashed in memory, not the stack: kept
                                         ; free of the push/pop pair below so
                                         ; every jump to .bad still finds the
                                         ; stack holding exactly the one pushed
                                         ; buffer pointer
        ld      a,c                     ; stash page count (C is about to change)
        push    af
        ld      h,0
        ld      l,c
        ld      b,6
.shift: add     hl,hl
        djnz    .shift                  ; HL = page_count * (MANIFEST_PAGE_SIZE
                                         ;      / MANIFEST_PAYLOAD_UNIT)
        pop     af
        ld      c,a                     ; C = page count again
        or      a
        sbc     hl,de
        jr      nz,.bad
        ld      a,(.asset_pages)
        cp      c                       ; asset pages must be strictly < total
        jr      nc,.bad
        ld      e,a                     ; E = asset page count
        ld      b,c                     ; B = total page count
        pop     hl
        or      a
        ret
.bad:   pop     hl
        scf
        ret
.asset_pages: DB 0

manifest_magic: DB "STM1"

        ENDIF
