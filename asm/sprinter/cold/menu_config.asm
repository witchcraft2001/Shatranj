; Sprinter hot-seat setup renderer.  The five-entry ABI matches the shared
; MENU_CONFIG overlay, but no ZX attribute/screen addresses are referenced.

SECTION code_user

EXTERN _spectrum_info_line
EXTERN _spectrum_info_show_setup

    DEFB 5
    DW menu_config_run
    DW menu_config_paint
    DW menu_config_validate
    DW menu_config_edit
    DW menu_config_render

menu_config_run:
menu_config_render:
    call _spectrum_info_show_setup
    ld hl,menu_line_game
    call _spectrum_info_line
    ld hl,menu_line_theme
    call _spectrum_info_line
    ld hl,menu_line_pieces
    call _spectrum_info_line
    ld hl,menu_line_hints
    call _spectrum_info_line
    ld hl,menu_line_start
    call _spectrum_info_line
menu_config_paint:
menu_config_validate:
menu_config_edit:
    ld hl,1
    ret

menu_line_game:   DEFB 4,"LOCAL HOT-SEAT",0
menu_line_theme:  DEFB 6,"T  THEME",0
menu_line_pieces: DEFB 7,"P  PIECES",0
menu_line_hints:  DEFB 8,"H  HINTS",0
menu_line_start:  DEFB 10,"ENTER  START",0
