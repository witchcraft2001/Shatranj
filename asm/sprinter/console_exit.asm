; Called after restoring DSS's saved video mode/screen, with IM2 removed.
; DSS PCHARS prints without replacing cell attributes. CLEAR resets both
; characters and attributes, and also DSS's color for scrolling/clearing.
; Leave graphical callers' saved screen untouched.
console_clear_home:
        ld      a,(HDR_ADDR+HDR_SAVED_MODE_OFFSET)
        ld      hl,#2028                ; 32 rows, 40 columns
        cp      DSS_VMOD_T40
        jr      z,.clear
        cp      DSS_VMOD_T80
        ret     nz
        ld      l,80
.clear:
        ld      de,0                    ; top-left cell
        ld      a,' '
        ld      bc,#0700+DSS_CLEAR      ; light gray ink, black paper
        rst     RST_DSS
        ld      de,0                    ; do not depend on CLEAR's registers
        ld      c,DSS_LOCATE
        rst     RST_DSS
        ret
