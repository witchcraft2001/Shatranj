; Shatranj Sprinter stage-0 diagnostic bootstrap.
; The resident runtime lives in WIN2; the +pps_low CRT and cold canary live
; in WIN1 so libman can temporarily replace that window with every DLL.

SECTION code_user

PUBLIC sprinter_win1_canary
sprinter_win1_canary:
        defw    05aa5h

SECTION SPRINTER_RUNTIME

PUBLIC _main
EXTERN _dss_exit

defc DSS_RST = 010h
defc DSS_WAITKEY = 030h
defc DSS_ENVIRON = 046h
defc DSS_SETVMOD = 050h
defc DSS_PUTCHAR = 05bh
defc PORT_WIN1 = 0a2h
defc PORT_Y = 089h
defc PORT_RGMOD = 0c9h

defc EXIT_PASS = 0
defc EXIT_NET = 1
defc EXIT_LIBMAN = 2
defc EXIT_UNET = 3
defc EXIT_VIDEO = 4
defc EXIT_GFX = 5

defc UNET_GETCAPS = 2
defc UNET_CAP_TCP = 0001h

defc GFX_INIT = 0
defc GFX_SET_VRAM_WINDOW = 2
defc GFX_GET_VERSION = 4
defc GFX_GET_CONFIG = 5
defc GFX_CLEAR = 6
defc GFX_FILL_RECT = 7
defc GFX_COPY_BUFFER = 11
defc GFX_PALETTE_LOAD256 = 13
defc GFX_SWAP_BUFFERS = 21
defc GFX_PUT_PIXEL = 29

defc GFX_TARGET_BUF0 = 0
defc GFX_TARGET_BUF1 = 1
defc GFX_PAL_BOTH = 3
defc GFX_REQUIRED_CAPS = 0018h

_main:
        ld      sp,0bff0h
        xor     a
        ld      (exit_code),a
        ld      (map_fault),a
        ld      (unet_loaded),a
        ld      (gfx_loaded),a
        ld      (video_active),a
        in      a,(PORT_WIN1)
        ld      (saved_win1_page),a

        call    print_banner
        call    select_backend
        jr      nc,bootstrap_backend_ok
        ld      a,EXIT_NET
        jp      bootstrap_fail

bootstrap_backend_ok:
        ld      hl,(backend_name_ptr)
        ld      a,1
        call    checked_l_load
        jr      nc,bootstrap_unet_loaded
        ld      a,EXIT_LIBMAN
        jp      bootstrap_fail
bootstrap_unet_loaded:
        ld      (unet_handle),hl
        ld      a,1
        ld      (unet_loaded),a

        ld      de,unet_info
        call    checked_l_info_unet
        jr      nc,bootstrap_unet_info_ok
        ld      a,EXIT_LIBMAN
        jp      bootstrap_fail
bootstrap_unet_info_ok:
        ld      hl,unet_info+16
        ld      de,(backend_tag_ptr)
        call    string_has_prefix
        jr      z,bootstrap_unet_name_ok
        ld      a,EXIT_UNET
        jp      bootstrap_fail
bootstrap_unet_name_ok:
        call    getcaps_and_save
        jr      nc,bootstrap_unet_caps_ok
        ld      a,EXIT_UNET
        jp      bootstrap_fail
bootstrap_unet_caps_ok:

        ld      hl,gfx_name
        ld      a,1
        call    checked_l_load
        jr      nc,bootstrap_gfx_loaded
        ld      a,EXIT_LIBMAN
        jp      bootstrap_fail
bootstrap_gfx_loaded:
        ld      (gfx_handle),hl
        ld      a,1
        ld      (gfx_loaded),a

        ld      de,gfx_info
        call    checked_l_info_gfx
        jr      nc,bootstrap_gfx_info_ok
        ld      a,EXIT_LIBMAN
        jp      bootstrap_fail
bootstrap_gfx_info_ok:
        ld      hl,gfx_info+16
        ld      de,gfx_tag
        call    string_has_prefix
        jr      z,bootstrap_gfx_name_ok
        ld      a,EXIT_GFX
        jp      bootstrap_fail
bootstrap_gfx_name_ok:

        ld      b,GFX_INIT
        call    gfx_call
        jp      c,bootstrap_gfx_error
        or      a
        jp      nz,bootstrap_gfx_error

        ld      b,GFX_GET_VERSION
        call    gfx_call
        jp      c,bootstrap_gfx_error
        or      a
        jp      nz,bootstrap_gfx_error
        ld      a,d
        cp      1
        jp      nz,bootstrap_gfx_error
        ld      a,ixl
        and     GFX_REQUIRED_CAPS
        cp      GFX_REQUIRED_CAPS
        jp      nz,bootstrap_gfx_error

        ld      a,16
        ld      (gfx_config),a
        ld      de,gfx_config
        ld      b,GFX_GET_CONFIG
        call    gfx_call
        jp      c,bootstrap_gfx_error
        or      a
        jp      nz,bootstrap_gfx_error
        ld      a,(gfx_config)
        cp      16
        jp      nz,bootstrap_gfx_error
        ld      a,(gfx_config+1)
        cp      081h
        jp      nz,bootstrap_gfx_error
        ld      hl,(gfx_config+2)
        ld      de,320
        or      a
        sbc     hl,de
        jp      nz,bootstrap_gfx_error
        ld      hl,(gfx_config+4)
        ld      de,256
        or      a
        sbc     hl,de
        jp      nz,bootstrap_gfx_error
        ld      a,(gfx_config+8)
        cp      1
        jp      nz,bootstrap_gfx_error

        ld      de,3
        ld      b,GFX_SET_VRAM_WINDOW
        call    gfx_call
        jp      c,bootstrap_gfx_error
        or      a
        jp      nz,bootstrap_gfx_error

        ld      a,081h
        ld      b,1
        call    setvmod_win2
        jr      c,bootstrap_video_error
        ld      a,081h
        ld      b,0
        call    setvmod_win2
        jr      c,bootstrap_video_error
        ld      a,1
        ld      (video_active),a

        call    make_palette
        ld      a,GFX_PAL_BOTH
        ld      de,palette_rgb
        ld      b,GFX_PALETTE_LOAD256
        call    gfx_call
        jp      c,bootstrap_gfx_error
        or      a
        jp      nz,bootstrap_gfx_error

        call    draw_smoke_layout
        jp      c,bootstrap_gfx_error

        call    getcaps_again
        jr      c,bootstrap_unet_error

        ei
        ld      c,DSS_WAITKEY
        rst     DSS_RST
        xor     a
        ld      (exit_code),a
        jr      bootstrap_cleanup

bootstrap_video_error:
        ld      a,EXIT_VIDEO
        jr      bootstrap_fail
bootstrap_gfx_error:
        ld      a,EXIT_GFX
        jr      bootstrap_fail
bootstrap_unet_error:
        ld      a,EXIT_UNET
bootstrap_fail:
        ld      (exit_code),a
        ld      a,(last_call_status)
        ld      (diag_status),a
        ld      a,(l_reason)
        ld      (diag_reason),a
        ld      a,(l_load_stage)
        ld      (diag_stage),a
        ld      a,(l_dss_error)
        ld      (diag_dss),a
        ld      a,(l_init_status)
        ld      (diag_init),a

bootstrap_cleanup:
        call    cleanup_runtime
        call    print_result
        ld      a,(exit_code)
        or      a
        jr      z,bootstrap_exit
        ; Keep the restored DSS console visible on failures.  Returning to
        ; DSS immediately can erase the diagnostic before it is readable.
        ei
        ld      c,DSS_WAITKEY
        rst     DSS_RST
bootstrap_exit:
        ld      a,(exit_code)
        ld      l,a
        ld      h,0
        push    hl
        call    _dss_exit

; A=window, HL=name. Preserve the returned handle in HL while checking WIN1.
checked_l_load:
        call    l_load
        jp      checked_result

checked_l_info_unet:
        ld      hl,(unet_handle)
        or      a                       ; libman l_info requires input CF=0
        call    l_info
        jp      checked_result

checked_l_info_gfx:
        ld      hl,(gfx_handle)
        or      a                       ; libman l_info requires input CF=0
        call    l_info
        jp      checked_result

gfx_call:
        ld      hl,(gfx_handle)
        call    l_call
        jp      checked_result

unet_call:
        ld      hl,(unet_handle)
        call    l_call

; Preserve all DLL results and the original CF. A map/canary failure overrides
; the dispatch result with CF=1 and A=FEh.
checked_result:
        ld      (last_call_status),a
        push    af
        push    bc
        push    de
        push    hl
        push    ix
        push    iy
        call    check_win1
        jr      c,checked_result_bad
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        ret
checked_result_bad:
        ld      a,1
        ld      (map_fault),a
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        ld      a,0feh
        scf
        ret

check_win1:
        in      a,(PORT_WIN1)
        ld      hl,saved_win1_page
        cp      (hl)
        jr      nz,check_win1_bad
        ld      hl,(sprinter_win1_canary)
        ld      de,05aa5h
        or      a
        sbc     hl,de
        ret     z
check_win1_bad:
        scf
        ret

; SETVMOD is always executed from WIN2. It restores the exact displaced WIN1
; page on both DSS success and failure before the canary check.
setvmod_win2:
        push    af
        in      a,(PORT_WIN1)
        ld      (setvmod_saved_page),a
        pop     af
        push    ix
        push    iy
        ld      c,DSS_SETVMOD
        rst     DSS_RST
        pop     iy
        pop     ix
        push    af
        ld      a,(setvmod_saved_page)
        out     (PORT_WIN1),a
        pop     af
        jp      checked_result

select_backend:
        xor     a
        ld      (env_value),a
        ld      hl,env_net
        ld      de,env_value
        ld      b,1
        ld      c,DSS_ENVIRON
        rst     DSS_RST
        cp      0ffh                    ; GETENV reports found in A, not CF
        jr      nz,select_backend_fail
        ld      hl,env_value
        ld      de,value_wifi
        call    string_equal
        jr      z,select_backend_wifi
        ld      hl,env_value
        ld      de,value_rtl
        call    string_equal
        jr      z,select_backend_rtl
select_backend_fail:
        scf
        ret
select_backend_wifi:
        ld      hl,unetesp_name
        ld      (backend_name_ptr),hl
        ld      hl,unetesp_tag
        ld      (backend_tag_ptr),hl
        or      a
        ret
select_backend_rtl:
        ld      hl,unetrtl_name
        ld      (backend_name_ptr),hl
        ld      hl,unetrtl_tag
        ld      (backend_tag_ptr),hl
        or      a
        ret

string_equal:
        ld      a,(de)
        cp      (hl)
        ret     nz
        or      a
        ret     z
        inc     de
        inc     hl
        jr      string_equal

; Z when ASCIIZ DE is a prefix of ASCIIZ HL.
string_has_prefix:
        ld      a,(de)
        or      a
        ret     z
        cp      (hl)
        ret     nz
        inc     de
        inc     hl
        jr      string_has_prefix

getcaps_and_save:
        ld      b,UNET_GETCAPS
        call    unet_call
        ret     c
        or      a
        jr      nz,getcaps_bad
        ld      a,ixh
        cp      1
        jr      nz,getcaps_bad
        ld      a,e
        and     UNET_CAP_TCP
        jr      z,getcaps_bad
        ld      (unet_caps),de
        ld      (unet_abi),ix
        or      a
        ret
getcaps_bad:
        scf
        ret

getcaps_again:
        ld      b,UNET_GETCAPS
        call    unet_call
        ret     c
        or      a
        jr      nz,getcaps_again_bad
        ld      hl,(unet_caps)
        or      a
        sbc     hl,de
        jr      nz,getcaps_again_bad
        push    ix
        pop     hl
        ld      de,(unet_abi)
        or      a
        sbc     hl,de
        ret     z
getcaps_again_bad:
        scf
        ret

make_palette:
        ld      hl,palette_rgb
        ld      b,0
        ld      c,0
make_palette_loop:
        ld      a,c
        ld      (hl),a
        inc     hl
        rlca
        ld      (hl),a
        inc     hl
        ld      a,c
        cpl
        ld      (hl),a
        inc     hl
        inc     c
        djnz    make_palette_loop
        ret

draw_smoke_layout:
        ; Clear both buffers before drawing the fixed 24x24 board layout.
        ld      a,012h
        ld      de,GFX_TARGET_BUF0
        ld      b,GFX_CLEAR
        call    gfx_call
        ret     c
        or      a
        jp      nz,draw_smoke_bad
        ld      a,012h
        ld      de,GFX_TARGET_BUF1
        ld      b,GFX_CLEAR
        call    gfx_call
        ret     c
        or      a
        jp      nz,draw_smoke_bad

        ld      hl,panel_rect
        call    gfx_fill_descriptor
        jp      c,draw_smoke_bad
        ld      hl,footer_rect
        call    gfx_fill_descriptor
        jp      c,draw_smoke_bad

        ld      a,8
        ld      (board_rows),a
        ld      a,32
        ld      (board_rect+2),a
        ld      a,030h
        ld      (board_color),a
draw_board_row:
        ld      hl,8
        ld      (board_rect),hl
        ld      a,8
        ld      (board_cols),a
draw_board_col:
        ld      a,(board_color)
        ld      (board_rect+7),a
        ld      hl,board_rect
        call    gfx_fill_descriptor
        jp      c,draw_smoke_bad
        ld      a,(board_color)
        xor     0e0h
        ld      (board_color),a
        ld      hl,(board_rect)
        ld      de,24
        add     hl,de
        ld      (board_rect),hl
        ld      hl,board_cols
        dec     (hl)
        jr      nz,draw_board_col
        ld      a,(board_color)
        xor     0e0h
        ld      (board_color),a
        ld      a,(board_rect+2)
        add     a,24
        ld      (board_rect+2),a
        ld      hl,board_rows
        dec     (hl)
        jr      nz,draw_board_row

        ; Explicit 16-bit X smoke primitive: x=300 must not wrap to 44.
        ld      a,0f0h
        ld      de,GFX_TARGET_BUF0
        ld      ix,300
        ld      iy,240
        ld      b,GFX_PUT_PIXEL
        call    gfx_call
        jp      c,draw_smoke_bad
        or      a
        jp      nz,draw_smoke_bad

        ; Clone the completed layout to buffer 1 and prove RGMOD toggles.
        ld      de,0001h
        ld      b,GFX_COPY_BUFFER
        call    gfx_call
        jp      c,draw_smoke_bad
        or      a
        jp      nz,draw_smoke_bad
        in      a,(PORT_RGMOD)
        and     1
        ld      (front_before_swap),a
        ld      b,GFX_SWAP_BUFFERS
        call    gfx_call
        jp      c,draw_smoke_bad
        or      a
        jp      nz,draw_smoke_bad
        in      a,(PORT_RGMOD)
        and     1
        ld      hl,front_before_swap
        cp      (hl)
        jr      z,draw_smoke_bad
        or      a
        ret
draw_smoke_bad:
        scf
        ret

gfx_fill_descriptor:
        push    hl
        pop     de
        ld      b,GFX_FILL_RECT
        call    gfx_call
        ret     c
        or      a
        ret     z
        scf
        ret

cleanup_runtime:
        ld      a,(gfx_loaded)
        or      a
        jr      z,cleanup_unet
        ld      hl,(gfx_handle)
        call    l_free
        call    checked_result
        xor     a
        ld      (gfx_loaded),a
cleanup_unet:
        ld      a,(unet_loaded)
        or      a
        jr      z,cleanup_video
        ld      hl,(unet_handle)
        call    l_free
        call    checked_result
        xor     a
        ld      (unet_loaded),a
cleanup_video:
        ld      a,0c0h
        out     (PORT_Y),a
        ld      a,003h
        ld      b,1
        call    setvmod_win2
        ld      a,003h
        ld      b,0
        call    setvmod_win2
        in      a,(PORT_RGMOD)
        and     0feh
        out     (PORT_RGMOD),a
        xor     a
        ld      (video_active),a
        ret

print_banner:
        ld      hl,msg_banner
        jp      puts

print_result:
        ld      a,(exit_code)
        or      a
        jr      nz,print_result_failed
        ld      hl,msg_pass
        call    puts
        jr      print_result_details
print_result_failed:
        ld      hl,msg_fail
        call    puts
        ld      a,(exit_code)
        call    put_hex8
        ld      hl,msg_map
        call    puts
        ld      a,(map_fault)
        call    put_hex8
        ld      hl,msg_status
        call    puts
        ld      a,(diag_status)
        call    put_hex8
        ld      hl,msg_libman
        call    puts
        ld      a,(diag_reason)
        call    put_hex8
        ld      a,'/'
        ld      c,DSS_PUTCHAR
        rst     DSS_RST
        ld      a,(diag_stage)
        call    put_hex8
        ld      a,'/'
        ld      c,DSS_PUTCHAR
        rst     DSS_RST
        ld      a,(diag_dss)
        call    put_hex8
        ld      a,'/'
        ld      c,DSS_PUTCHAR
        rst     DSS_RST
        ld      a,(diag_init)
        call    put_hex8
print_result_details:
        ld      hl,msg_caps
        call    puts
        ld      hl,(unet_caps)
        ld      a,h
        call    put_hex8
        ld      a,l
        call    put_hex8
        ld      hl,msg_abi
        call    puts
        ld      hl,(unet_abi)
        ld      a,h
        call    put_hex8
        ld      a,l
        call    put_hex8
        ld      hl,msg_crlf
        jp      puts

puts:
        ld      a,(hl)
        or      a
        ret     z
        push    hl
        ld      c,DSS_PUTCHAR
        rst     DSS_RST
        pop     hl
        inc     hl
        jr      puts

put_hex8:
        push    af
        rrca
        rrca
        rrca
        rrca
        call    put_hex_nibble
        pop     af
put_hex_nibble:
        and     00fh
        add     a,'0'
        cp      '9'+1
        jr      c,put_hex_emit
        add     a,'A'-'9'-1
put_hex_emit:
        ld      c,DSS_PUTCHAR
        rst     DSS_RST
        ret

msg_banner:             defb "Shatranj Sprinter stage 0",13,10,0
msg_pass:               defb "PASS",0
msg_fail:               defb "FAIL exit=",0
msg_map:                defb " map=",0
msg_status:             defb " status=",0
msg_libman:             defb " libman=",0
msg_caps:               defb " caps=",0
msg_abi:                defb " abi=",0
msg_crlf:               defb 13,10,0
env_net:                defb "NET",0
value_wifi:             defb "WIFI",0
value_rtl:              defb "RTL",0
unetesp_name:           defb "UNETESP.DLL",0
unetrtl_name:           defb "UNETRTL.DLL",0
gfx_name:               defb "GFX320.DLL",0
unetesp_tag:            defb "UNETESP",0
unetrtl_tag:            defb "UNETRTL",0
gfx_tag:                defb "GFX320",0

backend_name_ptr:       defw 0
backend_tag_ptr:        defw 0
unet_handle:            defw 0
gfx_handle:             defw 0
unet_caps:              defw 0
unet_abi:               defw 0
saved_win1_page:        defb 0
setvmod_saved_page:     defb 0
exit_code:              defb 0
map_fault:              defb 0
unet_loaded:            defb 0
gfx_loaded:             defb 0
video_active:           defb 0
front_before_swap:      defb 0
last_call_status:       defb 0
diag_status:            defb 0
diag_reason:            defb 0
diag_stage:             defb 0
diag_dss:               defb 0
diag_init:              defb 0
board_rows:             defb 0
board_cols:             defb 0
board_color:            defb 0
; DSS GETENV has no caller-supplied length and may copy up to 255 bytes.
env_value:              defs 256,0
unet_info:              defs 32,0
gfx_info:               defs 32,0
gfx_config:             defs 16,0

; x,y,width,height,color,target,reserved[3]
panel_rect:
        defw 208
        defb 32
        defw 104
        defw 192
        defb 078h,GFX_TARGET_BUF0,0,0,0
footer_rect:
        defw 8
        defb 232
        defw 304
        defw 16
        defb 090h,GFX_TARGET_BUF0,0,0,0
board_rect:
        defw 8
        defb 32
        defw 24
        defw 24
        defb 030h,GFX_TARGET_BUF0,0,0,0

palette_rgb:
        defs 768,0

; Configuration is intentionally local: stage 0 retains uNet and GFX320 at
; once, with one spare slot for later diagnostics.
defc LIBMAN_MAX_LIBS = 3
defc LIBMAN_DIAGNOSTICS = 1
defc LIBMAN_NO_LEGACY_API = 1
sprinter_libman_start_label:
include "libman.asm"
sprinter_libman_end_label:

PUBLIC sprinter_runtime_start
PUBLIC sprinter_runtime_end
PUBLIC sprinter_dll_name_start
PUBLIC sprinter_dll_name_end
PUBLIC sprinter_register_blocks_start
PUBLIC sprinter_register_blocks_end
PUBLIC sprinter_descriptors_start
PUBLIC sprinter_descriptors_end
PUBLIC sprinter_palette_start
PUBLIC sprinter_palette_end
PUBLIC sprinter_libman_start
PUBLIC sprinter_libman_end
PUBLIC sprinter_stack_top
PUBLIC sprinter_stack_headroom

defc sprinter_runtime_start = _main
defc sprinter_runtime_end = $
defc sprinter_dll_name_start = unetesp_name
defc sprinter_dll_name_end = gfx_name+11
defc sprinter_register_blocks_start = env_value
defc sprinter_register_blocks_end = gfx_config+16
defc sprinter_descriptors_start = panel_rect
defc sprinter_descriptors_end = board_rect+12
defc sprinter_palette_start = palette_rgb
defc sprinter_palette_end = palette_rgb+768
defc sprinter_libman_start = sprinter_libman_start_label
defc sprinter_libman_end = sprinter_libman_end_label
defc sprinter_stack_top = 0bff0h
defc sprinter_stack_headroom = 0400h
