; Sprinter (Estex DSS) platform constants used by the S1 stand.
;
; Own copy, not an include of extern/esp_net's dss.inc: this project pins
; that submodule for its uNet DLL only (port.md rule R2 -- graphics/loader
; code is never linked to a network submodule), and CLAUDE.md section 4
; requires Estex-DSS source as the authority. Values below are cross-checked
; against Estex-DSS/Shared_Includes/constants/{dss_equ.inc,BIOS_equ.inc}
; (CP866-encoded) and against extern/esp_net/src/include/dss.inc, which
; agrees byte-for-byte.
;
; Three unrelated things share small numeric values in this platform --
; keep them straight:
;   - RST_DSS (#10) is the CPU restart used for every DSS function below;
;     the function number goes in C (sometimes B too), e.g. C=DSS_SCANKEY.
;   - RST_MOUSE (#30) is a SEPARATE CPU restart (a literal `RST #30`
;     instruction, not "C=#30, RST DSS"). DSS_WAITKEY (#30) is a DSS
;     function number reached via RST_DSS -- same numeral, unrelated.
;   - DSS_VMOD_G640 (#82) is a SetVMod/GetVMod mode byte carried in A. It is
;     unrelated to WIN0_PORT (#82), an I/O port address. `OUT (#82),page`
;     and `LD A,#82 / RST DSS` (with C=DSS_SETVMOD) do very different
;     things despite the shared #82.

        IFNDEF SPRINTER_DSS_INC
        DEFINE SPRINTER_DSS_INC

RST_DSS               EQU #10
RST_BIOS              EQU #08
RST_MOUSE             EQU #30    ; CPU restart, not a DSS function

; DSS functions (C=function, RST RST_DSS; see the file banner above).
DSS_CLOSE_FILE        EQU #12
DSS_READ_FILE         EQU #13
DSS_SYSTIME           EQU #21
DSS_WAITKEY           EQU #30    ; blocks until a key is available, A=ASCII
DSS_SCANKEY           EQU #31    ; Z=empty, else A=ASCII (non-blocking)
DSS_TESTKEY           EQU #37    ; non-consuming peek at the head
DSS_SETWIN1           EQU #39
DSS_SETWIN2           EQU #3A
DSS_SETWIN3           EQU #3B
DSS_GETMEM            EQU #3D    ; B=16K page count -> A=block handle
DSS_FREEMEM           EQU #3E    ; A=block handle
DSS_EXIT              EQU #41    ; B=exit code; does not return
DSS_APPINFO           EQU #47
DSS_APPINFO_EXE_HOMEDIR EQU #01
DSS_SETVMOD           EQU #50    ; A=mode, B=screen(0/1)
DSS_GETVMOD           EQU #51    ; -> A=mode, B=screen
DSS_PCHARS            EQU #5C    ; HL=NUL-terminated string

; SetVMod/GetVMod mode bytes (carried in A -- see the banner note above).
DSS_VMOD_T40          EQU #02
DSS_VMOD_T80          EQU #03
DSS_VMOD_G320         EQU #81
DSS_VMOD_G640         EQU #82

; BIOS functions (C=function, RST RST_BIOS).
BIOS_GETMEMBLKPAGES   EQU #C5    ; A=block handle, HL=256B buffer ->
                                 ; B=count, list #FF-terminated
BIOS_CMOS_TEST        EQU #F5    ; CF=1 if no working CMOS (needed because
                                 ; DSS SysTime returns defaults with CF=0
                                 ; on a clockless machine -- Time.asm:97)

; CPU I/O window-select ports (16 KiB pages; see the banner note above).
WIN0_PORT             EQU #82
WIN1_PORT             EQU #A2
WIN2_PORT             EQU #C2
WIN3_PORT             EQU #E2

; Video mode #82 (640x256x4bpp) hardware ports.
PORT_Y                EQU #89    ; VRAM row select (this port only ever
                                 ; writes it; the BIOS also reads it)
PORT_RGMOD            EQU #C9    ; bit 0 selects the displayed buffer

; VRAM write aliases (mapped into WIN3 instead of the plain page #50):
; port.md section 3.3. VRAM_ALIAS_OPAQUE mirrors DRAM as well as VRAM;
; VRAM_ALIAS_KEY additionally skips whole #FF bytes in hardware (colour 15
; = transparency key, byte-granular -- not per nibble).
VRAM_ALIAS_OPAQUE     EQU #50
VRAM_ALIAS_KEY        EQU #58

; SIO channel A control register (RR0); bit 0 = Rx Character Available.
; Non-destructive read used by the IM2 stub to discriminate a frame tick
; from a keyboard interrupt (KEYINTER.ASM:519-536).
SIO_A_CTRL            EQU #19

        ENDIF
