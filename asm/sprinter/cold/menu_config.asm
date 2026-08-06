; Sprinter network setup renderer.  The five-entry ABI matches the shared
; MENU_CONFIG overlay, but no ZX attribute/screen addresses are referenced.

SECTION code_user

EXTERN _spectrum_info_line
EXTERN _spectrum_info_show_setup
EXTERN _sprinter_cold_text
EXTERN _setup_choice
EXTERN _setup_focus_choice
EXTERN _setup_focus_board_theme
EXTERN _setup_cursor
EXTERN _setup_room_editing
EXTERN _netchesszx_mqtt_code
EXTERN _netchesszx_direct_host
EXTERN _setup_port_text

    DEFB 5
    DW menu_config_run
    DW menu_config_paint
    DW menu_config_validate
    DW menu_config_edit
    DW menu_config_render

menu_config_run:
menu_config_paint:
menu_config_edit:
menu_config_render:
    call _spectrum_info_show_setup

    ld a,(_setup_focus_choice)
    or a
    ld hl,menu_line_game_host
    jr z,menu_game_ready
    ld hl,menu_line_game_join
menu_game_ready:
    ld b,0
    call menu_draw_line

    ld a,(_setup_focus_choice+1)
    or a
    ld hl,menu_line_link_direct
    jr z,menu_link_ready
    ld hl,menu_line_link_mqtt
menu_link_ready:
    ld b,1
    call menu_draw_line

    ld a,(_setup_choice+1)
    or a
    ld hl,menu_line_room
    ld de,_netchesszx_direct_host
    jr z,menu_endpoint_ready
    ld de,_netchesszx_mqtt_code
menu_endpoint_ready:
    ld b,2
    call menu_draw_value

    ld hl,menu_line_port
    ld de,_setup_port_text
    ld b,3
    call menu_draw_value

    ld a,(_setup_focus_choice+2)
    or a
    ld hl,menu_line_color_white
    jr z,menu_color_ready
    ld hl,menu_line_color_black
menu_color_ready:
    ld b,4
    call menu_draw_line

    ld a,(_setup_focus_choice+3)
    or a
    ld hl,menu_line_coord
    jr z,menu_notation_ready
    ld hl,menu_line_san
menu_notation_ready:
    ld b,5
    call menu_draw_line

    ld a,(_setup_focus_board_theme)
    add a,'1'
    ld (menu_line_board_digit),a
    ld hl,menu_line_board
    ld b,6
    call menu_draw_line

    ld a,(_setup_focus_choice+5)
    add a,'1'
    ld (menu_line_set_digit),a
    ld hl,menu_line_set
    ld b,7
    call menu_draw_line

    ld a,(_setup_focus_choice+4)
    or a
    ld hl,menu_line_hints_off
    jr z,menu_hints_ready
    ld hl,menu_line_hints_on
menu_hints_ready:
    ld b,8
    call menu_draw_line

    ld a,(_setup_room_editing)
    or a
    ld hl,menu_line_start
    jr z,menu_prompt_ready
    ld hl,menu_line_edit
menu_prompt_ready:
    ld b,9
    call menu_draw_line
menu_config_validate:
    ld hl,1
    ret

; HL = row-prefixed ASCIIZ template, B = logical setup row.
menu_draw_line:
    push bc
    call _sprinter_cold_text
    pop bc
    push hl
    inc hl
    ld a,(_setup_cursor)
    cp b
    ld a,' '
    jr nz,menu_draw_marker
    ld a,'>'
menu_draw_marker:
    ld (hl),a
    pop hl
    jp _spectrum_info_line

; HL = row-prefixed template ending in a space, DE = ASCIIZ value, B = row.
menu_draw_value:
    push bc
    push de
    call _sprinter_cold_text
    pop de
    pop bc
    push hl
    push bc
menu_value_end:
    ld a,(hl)
    inc hl
    or a
    jr nz,menu_value_end
    dec hl
    ld c,15
menu_value_copy:
    ld a,(de)
    or a
    jr z,menu_value_done
    ld (hl),a
    inc hl
    inc de
    dec c
    jr nz,menu_value_copy
menu_value_done:
    xor a
    ld (hl),a
    ld a,(_setup_room_editing)
    or a
    jr z,menu_value_cursor_done
    ld a,(_setup_cursor)
    cp b
    jr nz,menu_value_cursor_done
    ld a,'_'
    ld (hl),a
    inc hl
    xor a
    ld (hl),a
menu_value_cursor_done:
    pop bc
    pop hl
    push hl
    inc hl
    ld a,(_setup_cursor)
    cp b
    ld a,' '
    jr nz,menu_value_marker
    ld a,'>'
menu_value_marker:
    ld (hl),a
    pop hl
    jp _spectrum_info_line

menu_line_game_host:   DEFB 4,"  GAME HOST",0
menu_line_game_join:   DEFB 4,"  GAME JOIN",0
menu_line_link_mqtt:   DEFB 6,"  LINK MQTT",0
menu_line_link_direct: DEFB 6,"  LINK DIRECT",0
menu_line_room:        DEFB 8,"  ROOM ",0
menu_line_port:        DEFB 10,"  PORT ",0
menu_line_color_white: DEFB 12,"  COLOR WHITE",0
menu_line_color_black: DEFB 12,"  COLOR BLACK",0
menu_line_coord:       DEFB 14,"  NOTATION COORD",0
menu_line_san:         DEFB 14,"  NOTATION SAN",0
menu_line_board:       DEFB 16,"  BOARD THEME "
menu_line_board_digit: DEFB '1',0
menu_line_set:         DEFB 18,"  PIECES "
menu_line_set_digit:   DEFB '1',0
menu_line_hints_off:   DEFB 20,"  HINTS OFF",0
menu_line_hints_on:    DEFB 20,"  HINTS ON",0
menu_line_start:       DEFB 22,"  ENTER SELECT",0
menu_line_edit:        DEFB 22,"  TYPE; ENTER OK",0
