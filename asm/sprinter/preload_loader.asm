; Shatranj Sprinter DSS PRELOAD loader.
;
; DSS loads only this blob at #8100, leaves the EXE handle at (IX-3), and
; positions that handle at the monoblock manifest.  The loader allocates one
; contiguous DSS block, resolves all physical pages, streams exact 16 KiB raw
; pages through WIN1, then transfers through the patched base-bank stub before
; replacing itself with the permanent WIN2 runtime.

SECTION code_user

INCLUDE "sprinter_layout.inc"
INCLUDE "asm/sprinter/image_layout.inc"

DEFC DSS_READ = 0x13
DEFC DSS_CLOSE = 0x12
DEFC DSS_GETMEM = 0x3D
DEFC DSS_EXIT = 0x41
DEFC DSS_APPINFO = 0x47
DEFC DSS_PCHARS = 0x5C
DEFC BIOS_GETMEMBLKPAGES = 0xC5

DEFC PORT_WIN1 = 0xA2
DEFC PORT_WIN2 = 0xC2
DEFC PORT_WIN3 = 0xE2

DEFC LOADER_STACK = 0xBFF0
DEFC MANIFEST_SIZE = 32
DEFC PAGE_SIZE = 0x4000
DEFC MAX_PAGES = 64

DEFC L_HANDLE = 0xBA00
DEFC L_MEM_HANDLE = 0xBA01
DEFC L_PAGE_COUNT = 0xBA02
DEFC L_PAGE_INDEX = 0xBA03
DEFC L_SAVED_WIN1 = 0xBA04
DEFC L_SAVED_WIN3 = 0xBA05
DEFC L_READ_PTR = 0xBA06
DEFC L_READ_LEFT = 0xBA08
DEFC L_MANIFEST = 0xBA20
DEFC L_PAGES = 0xBA40

PUBLIC sprinter_preload_start
PUBLIC sprinter_preload_end

sprinter_preload_start:
    DI
    LD SP,LOADER_STACK
    LD A,(IX-3)
    LD (L_HANDLE),A
    IN A,(PORT_WIN1)
    LD (L_SAVED_WIN1),A
    IN A,(PORT_WIN3)
    LD (L_SAVED_WIN3),A

    LD HL,L_MANIFEST
    LD DE,MANIFEST_SIZE
    CALL loader_read_full
    JP C,loader_fail_read

    LD HL,L_MANIFEST
    LD DE,loader_magic
    LD B,4
loader_magic_loop:
    LD A,(DE)
    CP (HL)
    JP NZ,loader_fail_format
    INC DE
    INC HL
    DJNZ loader_magic_loop
    LD A,(L_MANIFEST+4)
    CP 2
    JP NZ,loader_fail_format
    LD A,(L_MANIFEST+5)
    CP 2
    JP C,loader_fail_format
    CP MAX_PAGES+1
    JP NC,loader_fail_format
    LD (L_PAGE_COUNT),A
    LD B,A
    LD A,(L_MANIFEST+6)
    LD C,A
    LD A,(L_MANIFEST+7)
    ADD A,C
    ADD A,2
    CP B
    JP NZ,loader_fail_format
    LD HL,(L_MANIFEST+8)
    LD DE,PAGE_SIZE
    OR A
    SBC HL,DE
    JP NZ,loader_fail_format
    LD HL,(L_MANIFEST+10)
    LD DE,SPRINTER_RUNTIME_ENTRY
    OR A
    SBC HL,DE
    JP NZ,loader_fail_format
    LD HL,(L_MANIFEST+12)
    LD DE,SPRINTER_BASE_TRANSITION
    OR A
    SBC HL,DE
    JP NZ,loader_fail_format
    LD HL,(L_MANIFEST+14)
    LD DE,SPRINTER_PAGE_TABLE
    OR A
    SBC HL,DE
    JP NZ,loader_fail_format
    LD HL,(L_MANIFEST+16)
    LD DE,MANIFEST_SIZE
    OR A
    SBC HL,DE
    JP NZ,loader_fail_format
    LD HL,(L_MANIFEST+18)
    LD DE,0x4001
    OR A
    SBC HL,DE
    JP NZ,loader_fail_format
    LD A,(L_MANIFEST+20)
    CP 2
    JP NZ,loader_fail_format
    LD A,(L_MANIFEST+6)
    ADD A,2
    LD B,A
    LD A,(L_MANIFEST+21)
    CP B
    JP NZ,loader_fail_format
    LD A,(L_MANIFEST+22)
    LD B,A
    LD A,(L_MANIFEST+7)
    OR A
    JP Z,loader_fail_format
    LD C,A
    LD A,B
    CP C
    JP NC,loader_fail_format
    LD A,(L_MANIFEST+23)
    CP C
    JP NC,loader_fail_format
    CP B
    JP C,loader_fail_format
    LD HL,(L_MANIFEST+24)
    LD DE,768
    OR A
    SBC HL,DE
    JP NZ,loader_fail_format
    LD HL,(L_MANIFEST+26)
    LD DE,SPRINTER_ASSET_PAGE_TABLE
    OR A
    SBC HL,DE
    JP NZ,loader_fail_format
    LD HL,(L_MANIFEST+28)
    LD DE,SPRINTER_GFX_PALETTE
    OR A
    SBC HL,DE
    JP NZ,loader_fail_format

    ; Exactly one allocation owns base, runtime and every cold code bank.
    LD A,(L_PAGE_COUNT)
    LD B,A
    LD C,DSS_GETMEM
    RST 0x10
    JP C,loader_fail_memory
    LD (L_MEM_HANDLE),A
    LD HL,L_PAGES
    LD C,BIOS_GETMEMBLKPAGES
    RST 0x08
    JP C,loader_fail_memory

    XOR A
    LD (L_PAGE_INDEX),A
loader_page_loop:
    LD A,(L_PAGE_INDEX)
    LD E,A
    LD D,0
    LD HL,L_PAGES
    ADD HL,DE
    LD A,(HL)
    OUT (PORT_WIN1),A
    LD HL,0x4000
    LD DE,PAGE_SIZE
    CALL loader_read_full
    JP C,loader_fail_read
    LD A,(L_PAGE_INDEX)
    INC A
    LD (L_PAGE_INDEX),A
    LD B,A
    LD A,(L_PAGE_COUNT)
    CP B
    JP NZ,loader_page_loop

    ; AppInfo derives the EXE directory from the PSP that still lives beside
    ; this loader in WIN2.  Capture it directly into the future runtime page
    ; through WIN3 before the base transition replaces WIN2 and destroys PSP.
    LD A,(L_PAGES+1)
    OUT (PORT_WIN3),A
    LD HL,0xC000+(SPRINTER_APP_DIR-0x8000)
    LD B,1
    LD C,DSS_APPINFO
    RST 0x10
    JP C,loader_fail_appinfo

    LD A,(L_HANDLE)
    LD C,DSS_CLOSE
    RST 0x10
    LD A,0xFF
    LD (L_HANDLE),A

    ; Publish the allocation in the runtime page through WIN3.
    LD A,(L_PAGES+1)
    OUT (PORT_WIN3),A
    LD HL,L_PAGES
    LD DE,0xC000+(SPRINTER_PAGE_TABLE-0x8000)
    LD A,(L_PAGE_COUNT)
    LD C,A
    LD B,0
    LDIR
    LD A,(L_PAGE_COUNT)
    LD (0xC000+(SPRINTER_PAGE_COUNT-0x8000)),A
    LD A,(L_MEM_HANDLE)
    LD (0xC000+(SPRINTER_MEM_HANDLE-0x8000)),A
    LD A,(L_SAVED_WIN1)
    LD (0xC000+(SPRINTER_LOADER_WIN1-0x8000)),A
    LD A,(L_SAVED_WIN3)
    LD (0xC000+(SPRINTER_LOADER_WIN3-0x8000)),A

    ; Convert the asset payload indexes into the physical pages expected by
    ; GFX640.  Only graphics pages are published; the RGB888 palette page is
    ; copied into permanent WIN2 and never exposed as a tile source.
    LD A,(L_MANIFEST+21)
    LD E,A
    LD D,0
    LD HL,L_PAGES
    ADD HL,DE
    LD DE,0xC000+(SPRINTER_ASSET_PAGE_TABLE-0x8000)
    LD A,(L_MANIFEST+22)
    LD C,A
    LD B,0
    LDIR
    LD A,(L_MANIFEST+7)
    LD (0xC000+(SPRINTER_ASSET_PAGE_COUNT-0x8000)),A
    LD A,(L_MANIFEST+22)
    LD (0xC000+(SPRINTER_GFX_PAGE_COUNT-0x8000)),A

    ; Stage the RGB888 palette in permanent WIN2.  The source page belongs to
    ; the same PRELOAD allocation and is mapped only for this bounded copy.
    LD A,(L_MANIFEST+21)
    LD B,A
    LD A,(L_MANIFEST+23)
    ADD A,B
    LD E,A
    LD D,0
    LD HL,L_PAGES
    ADD HL,DE
    LD A,(HL)
    LD (0xC000+(SPRINTER_PALETTE_PAGE_INDEX-0x8000)),A
    OUT (PORT_WIN1),A
    LD HL,0x4000
    LD DE,0xC000+(SPRINTER_GFX_PALETTE-0x8000)
    LD BC,768
    LDIR

    ; Patch the runtime physical page into the WIN1 transition instruction.
    LD A,(L_PAGES)
    OUT (PORT_WIN1),A
    LD A,(L_PAGES+1)
    LD (0x4001),A
    JP SPRINTER_BASE_TRANSITION

; Read exactly DE bytes from the PRELOAD handle into HL.  Short reads are
; retried; zero-byte EOF is a format failure.
loader_read_full:
    LD (L_READ_PTR),HL
    LD (L_READ_LEFT),DE
loader_read_loop:
    LD HL,(L_READ_LEFT)
    LD A,H
    OR L
    RET Z
    EX DE,HL
    LD HL,(L_READ_PTR)
    LD A,(L_HANDLE)
    LD C,DSS_READ
    PUSH IX
    RST 0x10
    POP IX
    RET C
    LD A,D
    OR E
    SCF
    RET Z
    LD HL,(L_READ_PTR)
    ADD HL,DE
    LD (L_READ_PTR),HL
    LD HL,(L_READ_LEFT)
    OR A
    SBC HL,DE
    LD (L_READ_LEFT),HL
    JP loader_read_loop

loader_fail_format:
    LD HL,loader_msg_format
    JP loader_fail
loader_fail_read:
    LD HL,loader_msg_read
    JP loader_fail
loader_fail_memory:
    LD HL,loader_msg_memory
    JP loader_fail
loader_fail_appinfo:
    LD HL,loader_msg_appinfo
loader_fail:
    LD A,(L_SAVED_WIN1)
    OUT (PORT_WIN1),A
    LD A,(L_SAVED_WIN3)
    OUT (PORT_WIN3),A
    LD C,DSS_PCHARS
    RST 0x10
    LD A,(L_HANDLE)
    CP 0xFF
    JP Z,loader_exit_failure
    LD C,DSS_CLOSE
    RST 0x10
loader_exit_failure:
    DI
    IM 1
    EI
    LD B,1
    LD C,DSS_EXIT
    RST 0x10
    DI
    HALT

loader_magic:
    DEFB "STM1"
loader_msg_format:
    DEFB "Shatranj: invalid monoblock",13,10,0
loader_msg_read:
    DEFB "Shatranj: truncated monoblock",13,10,0
loader_msg_memory:
    DEFB "Shatranj: not enough memory",13,10,0
loader_msg_appinfo:
    DEFB "Shatranj: EXE path unavailable",13,10,0

sprinter_preload_end:
