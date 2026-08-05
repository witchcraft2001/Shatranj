; Shatranj Sprinter Stage-2 permanent WIN2 runtime.
;
; WIN0 remains DSS.  WIN1 is the permanent base bank except while a cold bank
; is executing.  This page owns IM2, dispatch/far-call gates, all mutable state
; and every buffer passed to DSS.  WIN3 is never executable or persistent.

SECTION code_user

INCLUDE "sprinter_layout.inc"
INCLUDE "asm/sprinter/image_layout.inc"

DEFC PORT_WIN1 = 0xA2
DEFC PORT_WIN2 = 0xC2
DEFC PORT_WIN3 = 0xE2
DEFC PORT_Y = 0x89
DEFC PORT_RGMOD = 0xC9
DEFC PORT_CBL_CTRL = 0x004E
DEFC CBL_IDLE = 0x80

DEFC DSS_CREATE = 0x0A
DEFC DSS_DELETE = 0x0E
DEFC SPR_DSS_OPEN = 0x11
DEFC SPR_DSS_CLOSE = 0x12
DEFC DSS_READ = 0x13
DEFC DSS_WRITE = 0x14
DEFC DSS_MOVE_FP = 0x15
DEFC DSS_F_FIRST = 0x19
DEFC DSS_F_NEXT = 0x1A
DEFC DSS_SYSTIME = 0x21
DEFC DSS_WAITKEY = 0x30
DEFC DSS_SCANKEY = 0x31
DEFC DSS_K_CLEAR = 0x35
DEFC DSS_TESTKEY = 0x37
DEFC DSS_EXIT = 0x41
DEFC DSS_SETVMOD = 0x50
DEFC DSS_CLEAR = 0x56
DEFC DSS_PUTCHAR = 0x5B
DEFC DSS_PCHARS = 0x5C

DEFC OVL_SAVELOAD = 10
DEFC OVL_FILEUI = 13
DEFC OVL_INVALID = 0xFF

PUBLIC sprinter_runtime_page_start
PUBLIC sprinter_im2_handler
PUBLIC sprinter_runtime_start
PUBLIC sprinter_runtime_end
PUBLIC _overlay_code_slot
PUBLIC _spectrum_overlay_loaded_id
PUBLIC _spectrum_overlay_context
PUBLIC _spectrum_overlay_exec
PUBLIC _spectrum_overlay_exec_cached
PUBLIC _esx_handle
PUBLIC _esx_buf
PUBLIC _esx_count
PUBLIC _esx_result
PUBLIC _esx_fopen
PUBLIC _esx_fcreate
PUBLIC _esx_fread
PUBLIC _esx_fwrite
PUBLIC _esx_fclose
PUBLIC _esx_funlink
PUBLIC _esx_opendir
PUBLIC _esx_readdir
PUBLIC _spectrum_fileui_count
PUBLIC _spectrum_fileui_used_mask
PUBLIC _spectrum_net_runtime_fat_date
PUBLIC _spectrum_net_runtime_fat_time
PUBLIC _spectrum_net_runtime_clock_ready
PUBLIC _last_ip
PUBLIC _setup_choice
PUBLIC _setup_focus_choice
PUBLIC _setup_focus_board_theme
PUBLIC _setup_defined_mask
PUBLIC _setup_visible_mask
PUBLIC _setup_cursor
PUBLIC _setup_room_editing
PUBLIC _setup_edit_row
PUBLIC _setup_port_text
PUBLIC _local_input_len
PUBLIC _local_input_cursor
PUBLIC _local_input_mode
PUBLIC _input_history_count
PUBLIC _input_history_pos
PUBLIC _spectrum_frame_wait
PUBLIC _sprinter_key_scan_raw
PUBLIC _sprinter_clean_exit
PUBLIC _sprinter_video_graphics
PUBLIC sprinter_disk_gate

EXTERN _spectrum_input_frame_tick
EXTERN _spectrum_input_poll_event
EXTERN _spectrum_input_flush_until_release
EXTERN _spectrum_input_suppress_until_release
EXTERN _spectrum_input_parse_move
EXTERN _spectrum_assets_load
EXTERN _spectrum_assets_fatal
EXTERN _spectrum_key_edit_pressed
EXTERN _netchesszx_board_theme_apply
EXTERN _netchesszx_piece_set_load
EXTERN _spectrum_render_board
EXTERN _spectrum_render_board_area
EXTERN _spectrum_render_board_coords
EXTERN _spectrum_render_board_coord_mark
EXTERN _spectrum_render_status
EXTERN _spectrum_render_status_error
EXTERN _spectrum_render_clock
EXTERN _spectrum_render_game_timer_clear
EXTERN _spectrum_render_game_timer_char
EXTERN _spectrum_render_menu_timer_char
EXTERN _spectrum_render_turn_label
EXTERN _spectrum_render_notice
EXTERN _spectrum_render_notice_error
EXTERN _spectrum_render_notice_success
EXTERN _spectrum_render_connection
EXTERN _spectrum_render_menu
EXTERN _spectrum_render_square
EXTERN _spectrum_render_square_attr
EXTERN _spectrum_render_square_with_hint
EXTERN _spectrum_render_square_mark
EXTERN _spectrum_render_square_mark_with_hint
EXTERN _spectrum_render_moves
EXTERN _spectrum_render_move_at
EXTERN _spectrum_render_moves_scroll
EXTERN _spectrum_render_chat
EXTERN _spectrum_render_chat_at
EXTERN _spectrum_render_chat_scroll
EXTERN _spectrum_render_input
EXTERN _spectrum_render_input_cell
EXTERN _spectrum_render_about
EXTERN _spectrum_render_ikkle_at
EXTERN _spectrum_render_fileui_frame
EXTERN _spectrum_render_fileui_select
EXTERN _spectrum_info_show_game
EXTERN _spectrum_info_show_setup
EXTERN _spectrum_info_show_game_setup
EXTERN _spectrum_info_show_preflight
EXTERN _spectrum_info_clear_tail
EXTERN _spectrum_info_line
EXTERN _sprinter_render_present
EXTERN _sprinter_gfx_start
EXTERN _sprinter_gfx_stop
EXTERN SPRINTER_CLIENT_ENTRY

DEFC _overlay_code_slot = 0x4000
DEFC _spectrum_overlay_loaded_id = SPRINTER_OVERLAY_LOADED_ID
DEFC _spectrum_overlay_context = SPRINTER_OVERLAY_CONTEXT
DEFC _spectrum_overlay_exec = 0x8200
DEFC _spectrum_overlay_exec_cached = 0x8203
DEFC _esx_handle = SPRINTER_ESX_HANDLE
DEFC _esx_buf = SPRINTER_ESX_BUF
DEFC _esx_count = SPRINTER_ESX_COUNT
DEFC _esx_result = SPRINTER_ESX_RESULT
DEFC _esx_fopen = 0x8206
DEFC _esx_fcreate = 0x8209
DEFC _esx_fread = 0x820C
DEFC _esx_fwrite = 0x820F
DEFC _esx_fclose = 0x8212
DEFC _esx_funlink = 0x8215
DEFC _esx_opendir = 0x8218
DEFC _esx_readdir = 0x821B
DEFC _spectrum_fileui_count = SPRINTER_FILEUI_COUNT
DEFC _spectrum_fileui_used_mask = SPRINTER_FILEUI_USED_MASK
DEFC _spectrum_net_runtime_fat_date = 0x8221
DEFC _spectrum_net_runtime_fat_time = 0x8224
DEFC _spectrum_net_runtime_clock_ready = 0x8227
DEFC _spectrum_frame_wait = 0x822A
; State imported by production setup/input overlays.  It remains in WIN2 and
; aliases transient buffers that are never live during those overlay calls.
DEFC _last_ip = SPRINTER_STATUS_BUFFER
DEFC _setup_choice = SPRINTER_DIRENT_BUFFER
DEFC _setup_focus_choice = SPRINTER_DIRENT_BUFFER + 6
DEFC _setup_focus_board_theme = SPRINTER_DIRENT_BUFFER + 12
DEFC _setup_defined_mask = SPRINTER_DIRENT_BUFFER + 13
DEFC _setup_visible_mask = SPRINTER_DIRENT_BUFFER + 15
DEFC _setup_cursor = SPRINTER_DIRENT_BUFFER + 17
DEFC _setup_room_editing = SPRINTER_DIRENT_BUFFER + 18
DEFC _setup_edit_row = SPRINTER_DIRENT_BUFFER + 19
DEFC _setup_port_text = SPRINTER_DIRENT_BUFFER + 20
DEFC _local_input_len = SPRINTER_OVERLAY_CONTEXT + 8
DEFC _local_input_cursor = SPRINTER_OVERLAY_CONTEXT + 9
DEFC _local_input_mode = SPRINTER_OVERLAY_CONTEXT + 10
DEFC _input_history_count = SPRINTER_OVERLAY_CONTEXT + 11
DEFC _input_history_pos = SPRINTER_OVERLAY_CONTEXT + 12

sprinter_runtime_page_start:
    ; Every possible IM2 vector byte resolves to #8181.
    DEFS 257,0x81
    DEFS 0x0181-$,0

sprinter_im2_handler:
    PUSH AF
    ; #FFFE is an I/O port, not a memory address.  The high port byte for
    ; IN A,(n) comes from A, so this reads the display-sync status at #FFFE.
    LD A,0xFF
    IN A,(0xFE)
    BIT 5,A
    JR Z,sprinter_im2_chain
    LD A,(SPRINTER_FRAME_COUNTER)
    INC A
    LD (SPRINTER_FRAME_COUNTER),A
sprinter_im2_chain:
    POP AF
    JP 0x0038

    DEFS 0x0200-$,0

; Fixed three-byte WIN2 gates.  Cold banks never bind to movable runtime code.
    JP sprinter_overlay_exec
    JP sprinter_overlay_exec_cached
    JP sprinter_esx_fopen
    JP sprinter_esx_fcreate
    JP sprinter_esx_fread
    JP sprinter_esx_fwrite
    JP sprinter_esx_fclose
    JP sprinter_esx_funlink
    JP sprinter_esx_opendir
    JP sprinter_esx_readdir
    JP sprinter_esx_move_fp
    JP sprinter_fat_date
    JP sprinter_fat_time
    JP sprinter_clock_ready
    JP sprinter_frame_wait
    JP _spectrum_input_poll_event
    JP _spectrum_input_frame_tick
    JP _spectrum_input_poll_event
    JP _spectrum_input_flush_until_release
    JP _spectrum_input_suppress_until_release
    JP _spectrum_input_parse_move
    JP _spectrum_assets_load
    JP _spectrum_assets_fatal
    JP _spectrum_key_edit_pressed
    JP _netchesszx_board_theme_apply
    JP _netchesszx_piece_set_load
    JP _spectrum_render_board
    JP _spectrum_render_board_area
    JP _spectrum_render_board_coords
    JP _spectrum_render_board_coord_mark
    JP _spectrum_render_status
    JP _spectrum_render_status_error
    JP _spectrum_render_clock
    JP _spectrum_render_game_timer_clear
    JP _spectrum_render_game_timer_char
    JP _spectrum_render_menu_timer_char
    JP _spectrum_render_turn_label
    JP _spectrum_render_notice
    JP _spectrum_render_notice_error
    JP _spectrum_render_notice_success
    JP _spectrum_render_connection
    JP _spectrum_render_menu
    JP _spectrum_render_square
    JP _spectrum_render_square_attr
    JP _spectrum_render_square_with_hint
    JP _spectrum_render_square_mark
    JP _spectrum_render_square_mark_with_hint
    JP _spectrum_render_moves
    JP _spectrum_render_move_at
    JP _spectrum_render_moves_scroll
    JP _spectrum_render_chat
    JP _spectrum_render_chat_at
    JP _spectrum_render_chat_scroll
    JP _spectrum_render_input
    JP _spectrum_render_input_cell
    JP _spectrum_render_about
    JP _spectrum_render_ikkle_at
    JP _spectrum_render_fileui_frame
    JP _spectrum_render_fileui_select
    JP _spectrum_info_show_game
    JP _spectrum_info_show_setup
    JP _spectrum_info_show_game_setup
    JP _spectrum_info_show_preflight
    JP _spectrum_info_clear_tail
    JP _spectrum_info_line
    JP sprinter_noop
    JP sprinter_noop
    JP sprinter_noop
    JP sprinter_noop
    JP sprinter_noop
    JP sprinter_noop
    JP sprinter_noop
    JP sprinter_noop

    DEFS (SPRINTER_RUNTIME_ENTRY-0x8000)-$,0

sprinter_runtime_start:
    DI
    LD SP,SPRINTER_STACK_TOP
    ; Do not erase loader metadata, the palette, or preloaded DATA images.
    LD HL,SPRINTER_OVERLAY_CONTEXT
    XOR A
    LD (HL),A
    LD DE,SPRINTER_OVERLAY_CONTEXT+1
    LD BC,SPRINTER_APP_DIR-SPRINTER_OVERLAY_CONTEXT-1
    LDIR
    LD HL,SPRINTER_CONFIG_DIR
    LD (HL),A
    LD DE,SPRINTER_CONFIG_DIR+1
    LD BC,SPRINTER_GFX_PALETTE-SPRINTER_CONFIG_DIR-1
    LDIR
    LD HL,SPRINTER_GFX_CONFIG
    LD (HL),A
    LD DE,SPRINTER_GFX_CONFIG+1
    LD BC,SPRINTER_BASE_DATA-SPRINTER_GFX_CONFIG-1
    LDIR
    LD HL,SPRINTER_BASE_BSS
    LD (HL),A
    LD DE,SPRINTER_BASE_BSS+1
    LD BC,0x0180-1
    LDIR
    LD A,OVL_INVALID
    LD (SPRINTER_OVERLAY_LOADED_ID),A
    LD (SPRINTER_OVERLAY_CACHE_ID),A
    EI

    ; Keep DSS and GFX320 initialization in the launcher's IM1 environment.
    ; SetVMod reaches BIOS and libman performs several DSS calls; switching to
    ; IM2 before those calls lets a system interrupt return through our vector
    ; while DSS is temporarily using its own mappings.
    CALL sprinter_read_rtc
    JR C,sprinter_start_fail
    CALL sprinter_init_config_path
    JR C,sprinter_start_fail
    CALL _sprinter_gfx_start
    LD A,L
    OR A
    JR Z,sprinter_start_fail
    CALL sprinter_cbl_arm
    LD A,0x80
    LD I,A
    IM 2
    EI
    ; Call the portable application body, not z88dk's CRT entry at #4100.
    ; The CRT entry installs SP=#0000 and halts instead of returning; this
    ; runtime already owns initialization and the permanent WIN2 stack.
    CALL SPRINTER_CLIENT_ENTRY
    LD A,L
    LD (SPRINTER_DIAG_RESULT),A
    JR sprinter_cleanup

sprinter_start_fail:
    LD A,1
    LD (SPRINTER_DIAG_RESULT),A
    JR sprinter_cleanup

_sprinter_clean_exit:
    LD A,L
    LD (SPRINTER_DIAG_RESULT),A

sprinter_cleanup:
    ; Cleanup stays in IM1 permanently.  SetVMod is issued for both screens;
    ; PORT_Y is parked and front buffer zero is selected before DSS.Exit.
    DI
    CALL sprinter_cbl_disarm
    IM 1
    EI
    LD A,3
    LD B,1
    LD C,DSS_SETVMOD
    RST 0x10
    JR NC,sprinter_cleanup_screen_one_clear
    LD A,5
    LD (SPRINTER_DIAG_RESULT),A
    JR sprinter_cleanup_screen_zero
sprinter_cleanup_screen_one_clear:
    CALL sprinter_clear_text_screen
sprinter_cleanup_screen_zero:
    LD A,3
    LD B,0
    LD C,DSS_SETVMOD
    RST 0x10
    JR NC,sprinter_cleanup_screen_zero_clear
    LD A,5
    LD (SPRINTER_DIAG_RESULT),A
    JR sprinter_cleanup_video_done
sprinter_cleanup_screen_zero_clear:
    CALL sprinter_clear_text_screen
sprinter_cleanup_video_done:
    ; GFX320 free does not depend on graphics mode.  Restore DSS text mode
    ; first so a libman/DSS failure can never strand the user on a black page.
    CALL _sprinter_gfx_stop
    IN A,(PORT_RGMOD)
    AND 0xFE
    OUT (PORT_RGMOD),A
    IN A,(PORT_RGMOD)
    AND 1
    JR Z,sprinter_cleanup_front_ok
    LD A,5
    LD (SPRINTER_DIAG_RESULT),A
sprinter_cleanup_front_ok:
    LD A,0xC0
    OUT (PORT_Y),A
    LD A,(SPRINTER_LOADER_WIN1)
    LD B,A
    OUT (PORT_WIN1),A
    IN A,(PORT_WIN1)
    CP B
    JR Z,sprinter_cleanup_win1_ok
    LD A,5
    LD (SPRINTER_DIAG_RESULT),A
sprinter_cleanup_win1_ok:
    LD A,(SPRINTER_LOADER_WIN3)
    LD B,A
    OUT (PORT_WIN3),A
    IN A,(PORT_WIN3)
    CP B
    JR Z,sprinter_cleanup_maps_done
    LD A,5
    LD (SPRINTER_DIAG_RESULT),A
sprinter_cleanup_maps_done:
    LD A,(SPRINTER_DIAG_RESULT)
    OR A
    JR Z,sprinter_exit
    LD HL,msg_stage2_fail
    CALL sprinter_puts
sprinter_exit:
    LD A,(SPRINTER_DIAG_RESULT)
    LD B,A
    LD C,DSS_EXIT
    RST 0x10
    DI
    HALT

; Enter 320x256x256 mode on both display pages from permanent WIN2.  SetVMod
; temporarily changes WIN1, so reinstall the base page after each call.
_sprinter_video_graphics:
    ; This routine is called from SDCC-generated code.  SetVMod is allowed to
    ; clobber both index registers, while SDCC keeps its frame pointer in IX.
    PUSH IX
    PUSH IY
    LD A,0x81
    LD B,1
    LD C,DSS_SETVMOD
    RST 0x10
    JR C,sprinter_video_fail
    LD A,(SPRINTER_PAGE_TABLE)
    OUT (PORT_WIN1),A
    LD A,0x81
    LD B,0
    LD C,DSS_SETVMOD
    RST 0x10
    JR C,sprinter_video_fail
    LD A,(SPRINTER_PAGE_TABLE)
    OUT (PORT_WIN1),A
    IN A,(PORT_RGMOD)
    AND 0xFE
    OUT (PORT_RGMOD),A
    ; GFX320 maps #50 into WIN3 for each bounded operation and restores the
    ; previous page itself.  Leaving WIN3 as DSS's ordinary page between calls
    ; keeps all system services away from VRAM.
    LD A,0xC0
    OUT (PORT_Y),A
    LD HL,1
    POP IY
    POP IX
    RET
sprinter_video_fail:
    LD HL,0
    POP IY
    POP IX
    RET

; SetVMod changes the geometry but leaves text cells with zero attributes on
; real DSS.  Clear each selected text page to a visible console default and
; update DSS's shell colour for programs that do not initialize it themselves.
sprinter_clear_text_screen:
    LD D,0
    LD E,0
    LD H,32
    LD L,80
    LD A,' '
    LD B,0x07
    LD C,DSS_CLEAR
    RST 0x10
    RET

; ---------------------------------------------------------------------------
; Overlay dispatch.  The public gates retain the SDCC/IY C ABI used by the
; Spectrum and Next loaders: SP+2=overlay ID, SP+3=entry ID, result in HL.
; Runtime assembly uses the internal A/E entry points below.  Cached dispatch
; stores only the seven-byte descriptor; both paths map the bank for the call
; and restore the exact previous WIN1.
; ---------------------------------------------------------------------------
sprinter_overlay_exec:
    LD A,OVL_INVALID
    LD (SPRINTER_OVERLAY_CACHE_ID),A
    JR sprinter_overlay_c_args

sprinter_overlay_exec_cached:
sprinter_overlay_c_args:
    LD HL,2
    ADD HL,SP
    LD A,(HL)
    INC HL
    LD E,(HL)
    PUSH IX
    PUSH IY
    CALL sprinter_overlay_dispatch_cached_ae
    POP IY
    POP IX
    LD H,0
    RET

sprinter_overlay_dispatch_ae:
    LD B,A
    LD A,OVL_INVALID
    LD (SPRINTER_OVERLAY_CACHE_ID),A
    LD A,B

sprinter_overlay_dispatch_cached_ae:
    LD B,A
    LD A,(SPRINTER_DISK_BUSY)
    OR A
    JP NZ,sprinter_overlay_nested
    LD A,(SPRINTER_OVERLAY_BUSY)
    OR A
    JP NZ,sprinter_overlay_nested
    LD A,B
    LD (SPRINTER_OVERLAY_LOADED_ID),A
    LD A,E
    LD (SPRINTER_OVERLAY_ENTRY),A
    LD A,(SPRINTER_OVERLAY_LOADED_ID)
    LD B,A
    LD A,(SPRINTER_OVERLAY_CACHE_ID)
    CP B
    JR Z,sprinter_overlay_use_descriptor
    LD A,B
    JP sprinter_overlay_lookup
sprinter_overlay_lookup:
    CP SPRINTER_ATLAS_MAX_ID+1
    JP NC,sprinter_overlay_fail
    LD (SPRINTER_OVERLAY_LOADED_ID),A
    LD B,A
    LD HL,sprinter_overlay_atlas
    LD DE,SPRINTER_ATLAS_DESCRIPTOR_SIZE
sprinter_overlay_lookup_loop:
    LD A,B
    OR A
    JR Z,sprinter_overlay_lookup_found
    ADD HL,DE
    DEC B
    JR sprinter_overlay_lookup_loop
sprinter_overlay_lookup_found:
    LD A,(HL)
    OR A
    JP Z,sprinter_overlay_fail
    LD DE,SPRINTER_OVERLAY_CACHE_DESC
    LD BC,SPRINTER_ATLAS_DESCRIPTOR_SIZE
    LDIR
    LD A,(SPRINTER_OVERLAY_LOADED_ID)
    LD (SPRINTER_OVERLAY_CACHE_ID),A
    JR sprinter_overlay_descriptor_ready

sprinter_overlay_use_descriptor:
sprinter_overlay_descriptor_ready:
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+2)
    LD L,A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+3)
    LD H,A
    LD A,H
    CP 0x40
    JP C,sprinter_overlay_fail
    CP 0x80
    JP NC,sprinter_overlay_fail
    LD BC,(SPRINTER_OVERLAY_CACHE_DESC+4)
    LD A,B
    OR A
    JR Z,sprinter_overlay_length_low
    CP 8
    JR C,sprinter_overlay_length_low
    JP NZ,sprinter_overlay_fail
    LD A,C
    OR A
    JP NZ,sprinter_overlay_fail
sprinter_overlay_length_low:
    LD A,B
    OR C
    JP Z,sprinter_overlay_fail
    LD A,(SPRINTER_OVERLAY_ENTRY)
    LD B,A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+6)
    CP B
    JP Z,sprinter_overlay_fail
    JP C,sprinter_overlay_fail
    IN A,(PORT_WIN1)
    LD (SPRINTER_OVERLAY_PREV_PAGE),A
    LD A,1
    LD (SPRINTER_OVERLAY_BUSY),A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+1)
    LD E,A
    LD D,0
    LD HL,SPRINTER_PAGE_TABLE
    ADD HL,DE
    LD A,(HL)
    OUT (PORT_WIN1),A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+2)
    LD L,A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+3)
    LD H,A
    LD A,(HL)
    LD C,A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+6)
    CP C
    JR NZ,sprinter_overlay_restore_fail
    INC HL
    LD A,(SPRINTER_OVERLAY_ENTRY)
    ADD A,A
    LD E,A
    LD D,0
    ADD HL,DE
    LD E,(HL)
    INC HL
    LD D,(HL)
    LD (SPRINTER_FAR_TARGET),DE
    ; Entry must be at/after the table and strictly before base+length.
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+6)
    ADD A,A
    INC A
    LD C,A
    LD B,0
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+2)
    LD L,A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+3)
    LD H,A
    ADD HL,BC
    LD DE,(SPRINTER_FAR_TARGET)
    EX DE,HL
    OR A
    SBC HL,DE
    JR C,sprinter_overlay_restore_fail
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+2)
    LD L,A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+3)
    LD H,A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+4)
    LD C,A
    LD A,(SPRINTER_OVERLAY_CACHE_DESC+5)
    LD B,A
    ADD HL,BC
    LD DE,(SPRINTER_FAR_TARGET)
    OR A
    SBC HL,DE
    JR C,sprinter_overlay_restore_fail
    JR Z,sprinter_overlay_restore_fail
    ; Preserve the existing overlay-entry ABI as well: C fastcall entries get
    ; the fixed context in HL and native assembly entries get it in DE.  Like
    ; the Spectrum and Next dispatchers, every cold entry starts under DI;
    ; callees may re-enable interrupts and the return path always does so.
sprinter_overlay_entry_di:
    DI
    LD BC,sprinter_overlay_entry_return
    PUSH BC
    LD BC,(SPRINTER_FAR_TARGET)
    PUSH BC
    LD HL,SPRINTER_OVERLAY_CONTEXT
    LD DE,SPRINTER_OVERLAY_CONTEXT
    RET
sprinter_overlay_entry_return:
    LD A,L
    LD (SPRINTER_OVERLAY_RETURN),A
    LD A,(SPRINTER_OVERLAY_PREV_PAGE)
    OUT (PORT_WIN1),A
    XOR A
    LD (SPRINTER_OVERLAY_BUSY),A
    LD A,OVL_INVALID
    LD (SPRINTER_OVERLAY_LOADED_ID),A
    LD A,(SPRINTER_OVERLAY_RETURN)
    LD L,A
    EI
    RET

sprinter_overlay_restore_fail:
    LD A,(SPRINTER_OVERLAY_PREV_PAGE)
    OUT (PORT_WIN1),A
    XOR A
    LD (SPRINTER_OVERLAY_BUSY),A
sprinter_overlay_fail:
    LD A,OVL_INVALID
    LD (SPRINTER_OVERLAY_LOADED_ID),A
    XOR A
    LD L,A
    EI
    RET
sprinter_overlay_nested:
    LD A,1
    LD (SPRINTER_PLATFORM_ERROR),A
    LD A,OVL_INVALID
    LD (SPRINTER_OVERLAY_LOADED_ID),A
    XOR A
    LD L,A
    RET

sprinter_call_hl:
    JP (HL)

; ---------------------------------------------------------------------------
; Generated base-bank thunks enter here with HL=base target.  The caller's
; return address lives in an unmapped cold bank, so it is held in WIN2 until
; the exact cold page is restored.  All classic-ABI result registers survive.
; ---------------------------------------------------------------------------
sprinter_far_call:
    LD (SPRINTER_FAR_TARGET),HL
    POP HL
    LD (SPRINTER_FAR_RETURN),HL
    IN A,(PORT_WIN1)
    LD (SPRINTER_FAR_PREV_PAGE),A
    LD A,(SPRINTER_PAGE_TABLE)
    OUT (PORT_WIN1),A
    LD HL,(SPRINTER_FAR_TARGET)
    CALL sprinter_call_hl
    LD (SPRINTER_FAR_HL),HL
    LD (SPRINTER_FAR_DE),DE
    LD (SPRINTER_FAR_BC),BC
    LD (SPRINTER_FAR_IX),IX
    LD (SPRINTER_FAR_IY),IY
    PUSH AF
    POP HL
    LD (SPRINTER_FAR_AF),HL
    LD A,(SPRINTER_FAR_PREV_PAGE)
    OUT (PORT_WIN1),A
    LD HL,(SPRINTER_FAR_RETURN)
    PUSH HL
    LD IY,(SPRINTER_FAR_IY)
    LD IX,(SPRINTER_FAR_IX)
    LD BC,(SPRINTER_FAR_BC)
    LD DE,(SPRINTER_FAR_DE)
    LD HL,(SPRINTER_FAR_AF)
    PUSH HL
    POP AF
    LD HL,(SPRINTER_FAR_HL)
    RET

INCLUDE "sprinter_far_thunks.inc"

; ---------------------------------------------------------------------------
; Race-free frame wait and DSS keyboard translation.
; ---------------------------------------------------------------------------
; The video-status flag at #FFFE.5 is live only while CBL is running.  Keep
; CBL in its idle mode: it is neither a timer nor an interrupt source here.
; Starting from a silent, empty FIFO avoids inheriting audio from DSS tools.
sprinter_cbl_arm:
    LD BC,PORT_CBL_CTRL
    XOR A
    OUT (C),A
    INC C
    LD A,CBL_IDLE
    LD B,0
sprinter_cbl_flush:
    OUT (C),A
    DJNZ sprinter_cbl_flush
    DEC C
    OUT (C),A
    LD A,1
    LD (SPRINTER_CBL_ARMED),A
    RET

sprinter_cbl_disarm:
    LD A,(SPRINTER_CBL_ARMED)
    OR A
    RET Z
    LD BC,PORT_CBL_CTRL
    XOR A
    OUT (C),A
    LD (SPRINTER_CBL_ARMED),A
    RET

sprinter_frame_wait:
    LD A,(SPRINTER_DISK_BUSY)
    OR A
    JR NZ,sprinter_frame_nested
    DI
    LD A,(SPRINTER_FRAME_COUNTER)
    LD (SPRINTER_FRAME_BASELINE),A
    XOR A
    LD (SPRINTER_FRAME_WAKES),A
sprinter_frame_wait_loop:
    EI
    HALT
    DI
    LD A,(SPRINTER_FRAME_COUNTER)
    LD B,A
    LD A,(SPRINTER_FRAME_BASELINE)
    CP B
    JR NZ,sprinter_frame_ready
    LD A,(SPRINTER_FRAME_WAKES)
    INC A
    LD (SPRINTER_FRAME_WAKES),A
    JR NZ,sprinter_frame_wait_loop
    LD A,2
    LD (SPRINTER_PLATFORM_ERROR),A
    EI
    SCF
    RET
sprinter_frame_ready:
    LD A,B
    LD (SPRINTER_FRAME_BASELINE),A
    EI
    CALL _spectrum_input_frame_tick
    CALL _sprinter_render_present
    LD A,0xC0
    OUT (PORT_Y),A
    OR A
    RET
sprinter_frame_nested:
    LD A,3
    LD (SPRINTER_PLATFORM_ERROR),A
    SCF
    RET

sprinter_key_poll:
    IN A,(PORT_WIN1)
    PUSH AF
    IN A,(PORT_WIN3)
    PUSH AF
    LD C,DSS_TESTKEY
    RST 0x10
    JP Z,sprinter_key_none_saved
    LD C,DSS_SCANKEY
    RST 0x10
    LD (SPRINTER_KEY_ASCII),A
    LD A,B
    LD (SPRINTER_KEY_MODIFIERS),A
    LD A,D
    AND 0x7F
    LD (SPRINTER_KEY_SCAN),A
    POP AF
    OUT (PORT_WIN3),A
    POP AF
    OUT (PORT_WIN1),A
    ; DSS normally supplies Esc as ASCII #1B.  Some PS/2 paths (including
    ; Ctrl-modified Escape) supply only its positional code #01, however.
    ; Accept both forms before the generic ASCII/positional translation.
    LD A,(SPRINTER_KEY_MODIFIERS)
    BIT 5,A
    JR Z,sprinter_key_ascii
    LD A,(SPRINTER_KEY_ASCII)
    CP 0x1B
    JR Z,sprinter_key_ctrl_escape
    LD A,(SPRINTER_KEY_SCAN)
    CP 0x01
    JR Z,sprinter_key_ctrl_escape
sprinter_key_ascii:
    LD A,(SPRINTER_KEY_ASCII)
    OR A
    JR Z,sprinter_key_positional
    CP 0x1B
    JR Z,sprinter_key_escape
    CP 0x08
    JR Z,sprinter_key_return
    CP 0x0D
    JR Z,sprinter_key_return
    CP 0x7F
    JR Z,sprinter_key_backspace
    CP 0x20
    JR C,sprinter_key_none
    CP 0x7F
    JR NC,sprinter_key_none
sprinter_key_return:
    LD L,A
    RET
sprinter_key_backspace:
    LD L,0x08
    RET
sprinter_key_escape:
    LD A,(SPRINTER_KEY_MODIFIERS)
    BIT 5,A
    JR Z,sprinter_key_escape_plain
sprinter_key_ctrl_escape:
    XOR A
    LD (SPRINTER_DIAG_RESULT),A
    JP sprinter_cleanup
sprinter_key_escape_plain:
    LD L,0x8A
    RET
sprinter_key_positional:
    LD A,(SPRINTER_KEY_SCAN)
    CP 0x58
    JR Z,sprinter_key_up
    CP 0x52
    JR Z,sprinter_key_down
    CP 0x54
    JR Z,sprinter_key_left
    CP 0x56
    JR Z,sprinter_key_right
    CP 0x57
    JR Z,sprinter_key_home
    CP 0x51
    JR Z,sprinter_key_end
    CP 0x4F
    JR Z,sprinter_key_backspace
    CP 0x3B
    JR Z,sprinter_key_f1
sprinter_key_none:
    LD L,0
    RET

_sprinter_key_scan_raw:
    PUSH IX
    PUSH IY
    CALL sprinter_key_poll
    POP IY
    POP IX
    LD H,0
    RET
sprinter_key_up:
    LD L,0x81
    RET
sprinter_key_down:
    LD L,0x82
    RET
sprinter_key_left:
    LD L,0x83
    RET
sprinter_key_right:
    LD L,0x84
    RET
sprinter_key_home:
    LD L,0x88
    RET
sprinter_key_end:
    LD L,0x89
    RET
sprinter_key_f1:
    LD L,0x90
    RET
sprinter_key_none_saved:
    POP AF
    OUT (PORT_WIN3),A
    POP AF
    OUT (PORT_WIN1),A
    LD L,0
    RET

; ---------------------------------------------------------------------------
; Single resident DSS disk gate.  This is the only runtime location allowed
; to issue a disk RST.  It captures all results before restoring maps/IM2.
; ---------------------------------------------------------------------------
sprinter_disk_gate:
    PUSH IY
    LD (SPRINTER_DISK_IN_HL),HL
    LD (SPRINTER_DISK_IN_DE),DE
    LD (SPRINTER_DISK_IN_BC),BC
    LD (SPRINTER_DISK_IN_IX),IX
    PUSH AF
    POP HL
    LD (SPRINTER_DISK_IN_AF),HL
    LD A,(SPRINTER_DISK_BUSY)
    OR A
    JP NZ,sprinter_disk_reentry
    LD A,1
    LD (SPRINTER_DISK_BUSY),A
    IN A,(PORT_WIN1)
    LD (SPRINTER_DISK_WIN1),A
    IN A,(PORT_WIN3)
    LD (SPRINTER_DISK_WIN3),A
    DI
    IM 1
    EI
    LD IX,(SPRINTER_DISK_IN_IX)
    LD DE,(SPRINTER_DISK_IN_DE)
    LD BC,(SPRINTER_DISK_IN_BC)
    LD HL,(SPRINTER_DISK_IN_AF)
    PUSH HL
    POP AF
    LD HL,(SPRINTER_DISK_IN_HL)
sprinter_disk_gate_rst:
    RST 0x10
sprinter_disk_gate_rst_end:
    DI
    LD (SPRINTER_DISK_OUT_HL),HL
    LD (SPRINTER_DISK_OUT_DE),DE
    LD (SPRINTER_DISK_OUT_BC),BC
    LD (SPRINTER_DISK_OUT_IX),IX
    PUSH AF
    POP HL
    LD (SPRINTER_DISK_OUT_AF),HL
    ; Preserve the actual DSS error across a later successful Close call.
    LD A,L
    AND 1
    JR Z,sprinter_disk_result_saved
    LD A,H
    LD (SPRINTER_FILE_ERROR),A
sprinter_disk_result_saved:
    LD A,(SPRINTER_DISK_WIN1)
    OUT (PORT_WIN1),A
    LD A,(SPRINTER_DISK_WIN3)
    OUT (PORT_WIN3),A
    LD A,(SPRINTER_FRAME_COUNTER)
    LD (SPRINTER_FRAME_BASELINE),A
    XOR A
    LD (SPRINTER_FRAME_WAKES),A
    LD (SPRINTER_DISK_BUSY),A
    LD A,(SPRINTER_CBL_ARMED)
    OR A
    JR Z,sprinter_disk_restore_im1
    IM 2
    JR sprinter_disk_restore_interrupts
sprinter_disk_restore_im1:
    IM 1
sprinter_disk_restore_interrupts:
    EI
    LD IX,(SPRINTER_DISK_OUT_IX)
    LD BC,(SPRINTER_DISK_OUT_BC)
    LD DE,(SPRINTER_DISK_OUT_DE)
    LD HL,(SPRINTER_DISK_OUT_AF)
    PUSH HL
    POP AF
    LD HL,(SPRINTER_DISK_OUT_HL)
    POP IY
    RET
sprinter_disk_reentry:
    LD A,3
    LD (SPRINTER_PLATFORM_ERROR),A
    LD A,0xFF
    SCF
    POP IY
    RET

; ---------------------------------------------------------------------------
; esx-style file ABI over DSS.  Paths are bounded and normalized in WIN2;
; DSS handle N is exposed as N+1 because the existing C ABI reserves zero.
; ---------------------------------------------------------------------------
sprinter_copy_path:
    LD DE,SPRINTER_PATH_BUFFER
    LD B,255
sprinter_copy_path_loop:
    LD A,(HL)
    OR A
    JR Z,sprinter_copy_path_done
    CP '/'
    JR NZ,sprinter_copy_path_store
    LD A,'\\'
sprinter_copy_path_store:
    LD (DE),A
    INC HL
    INC DE
    DJNZ sprinter_copy_path_loop
    SCF
    RET
sprinter_copy_path_done:
    XOR A
    LD (DE),A
    LD HL,SPRINTER_PATH_BUFFER
    OR A
    RET

sprinter_esx_clear:
    XOR A
    LD (SPRINTER_ESX_HANDLE),A
    LD (SPRINTER_ESX_RESULT),A
    LD (SPRINTER_ESX_RESULT+1),A
    RET

sprinter_esx_fopen:
    CALL sprinter_esx_clear
    CALL sprinter_copy_path
    RET C
    LD A,1
    LD C,SPR_DSS_OPEN
    CALL sprinter_disk_gate
    RET C
    INC A
    LD (SPRINTER_ESX_HANDLE),A
    RET

sprinter_esx_fcreate:
    CALL sprinter_esx_clear
    CALL sprinter_copy_path
    RET C
    XOR A
    LD C,DSS_CREATE
    CALL sprinter_disk_gate
    RET C
    INC A
    LD (SPRINTER_ESX_HANDLE),A
    RET

sprinter_esx_fread:
    LD HL,0
    LD (SPRINTER_ESX_RESULT),HL
    LD A,(SPRINTER_ESX_HANDLE)
    OR A
    RET Z
    DEC A
    LD HL,(SPRINTER_ESX_BUF)
    LD DE,(SPRINTER_ESX_COUNT)
    LD C,DSS_READ
    CALL sprinter_disk_gate
    RET C
    LD (SPRINTER_ESX_RESULT),DE
    RET

sprinter_esx_fwrite:
    XOR A
    LD (SPRINTER_ESX_RESULT),A
    LD (SPRINTER_ESX_RESULT+1),A
    LD A,(SPRINTER_ESX_HANDLE)
    OR A
    RET Z
    DEC A
    LD HL,(SPRINTER_ESX_BUF)
    LD DE,(SPRINTER_ESX_COUNT)
    LD C,DSS_WRITE
    CALL sprinter_disk_gate
    RET C
    ; DSS Write has no byte-count result; success means the whole request.
    LD HL,(SPRINTER_ESX_COUNT)
    LD (SPRINTER_ESX_RESULT),HL
    RET

sprinter_esx_fclose:
    LD A,(SPRINTER_ITERATOR_ACTIVE)
    OR A
    JR Z,sprinter_esx_close_file
    XOR A
    LD (SPRINTER_ITERATOR_ACTIVE),A
    LD (SPRINTER_ITERATOR_PENDING),A
    LD (SPRINTER_ESX_HANDLE),A
    LD L,A
    RET
sprinter_esx_close_file:
    LD A,(SPRINTER_ESX_HANDLE)
    OR A
    JR Z,sprinter_esx_close_bad
    DEC A
    LD C,SPR_DSS_CLOSE
    CALL sprinter_disk_gate
    PUSH AF
    XOR A
    LD (SPRINTER_ESX_HANDLE),A
    POP AF
    JR C,sprinter_esx_close_bad
    LD L,0
    RET
sprinter_esx_close_bad:
    LD L,0xFF
    RET

sprinter_esx_funlink:
    XOR A
    LD (SPRINTER_ESX_RESULT),A
    LD (SPRINTER_ESX_RESULT+1),A
    CALL sprinter_copy_path
    RET C
    LD C,DSS_DELETE
    CALL sprinter_disk_gate
    RET C
    LD HL,1
    LD (SPRINTER_ESX_RESULT),HL
    RET

sprinter_esx_opendir:
    CALL sprinter_esx_clear
    LD A,(SPRINTER_ITERATOR_ACTIVE)
    OR A
    RET NZ
    CALL sprinter_copy_path
    RET C
    LD HL,SPRINTER_PATH_BUFFER
    LD B,249
sprinter_esx_dir_end:
    LD A,(HL)
    OR A
    JR Z,sprinter_esx_dir_append
    INC HL
    DJNZ sprinter_esx_dir_end
    SCF
    RET
sprinter_esx_dir_append:
    LD (HL),'\\'
    INC HL
    LD (HL),'*'
    INC HL
    LD (HL),'.'
    INC HL
    LD (HL),'S'
    INC HL
    LD (HL),'T'
    INC HL
    LD (HL),'J'
    INC HL
    LD (HL),0
    LD HL,SPRINTER_PATH_BUFFER
    LD DE,SPRINTER_FIND_BUFFER
    LD A,0x37
    LD B,1
    LD C,DSS_F_FIRST
    ; The cold FileUI module uses IX as its SDCC frame pointer.  libman needs
    ; IX as a DSS result, so preserve the FileUI caller around this C call.
    PUSH IX
    CALL sprinter_disk_gate
    POP IX
    RET C
    LD A,1
    LD (SPRINTER_ITERATOR_ACTIVE),A
    LD (SPRINTER_ITERATOR_PENDING),A
    LD (SPRINTER_ESX_HANDLE),A
    RET

sprinter_esx_readdir:
    XOR A
    LD (SPRINTER_ESX_RESULT),A
    LD (SPRINTER_ESX_RESULT+1),A
    LD A,(SPRINTER_ITERATOR_ACTIVE)
    OR A
    RET Z
sprinter_esx_readdir_next:
    LD A,(SPRINTER_ITERATOR_PENDING)
    OR A
    JR Z,sprinter_esx_readdir_fetch
    XOR A
    LD (SPRINTER_ITERATOR_PENDING),A
    JR sprinter_esx_readdir_filter
sprinter_esx_readdir_fetch:
    LD DE,SPRINTER_FIND_BUFFER
    LD C,DSS_F_NEXT
    PUSH IX
    CALL sprinter_disk_gate
    POP IX
    RET C
sprinter_esx_readdir_filter:
    LD A,(SPRINTER_FIND_BUFFER+32)
    AND 0x10
    JR NZ,sprinter_esx_readdir_next
    LD A,(SPRINTER_FIND_BUFFER+33)
    CP '.'
    JR Z,sprinter_esx_readdir_next
    CALL sprinter_adapt_dirent
    LD HL,1
    LD (SPRINTER_ESX_RESULT),HL
    RET

sprinter_adapt_dirent:
    LD HL,(SPRINTER_ESX_BUF)
    PUSH HL
    XOR A
    LD (HL),A
    LD D,H
    LD E,L
    INC DE
    LD BC,23
    LDIR
    POP DE
    LD A,(SPRINTER_FIND_BUFFER+32)
    LD (DE),A
    INC DE
    LD HL,SPRINTER_FIND_BUFFER+33
    LD B,13
sprinter_adapt_name:
    LD A,(HL)
    LD (DE),A
    INC HL
    INC DE
    OR A
    JR Z,sprinter_adapt_stamp
    DJNZ sprinter_adapt_name
    XOR A
    LD (DE),A
    INC DE
sprinter_adapt_stamp:
    LD HL,SPRINTER_FIND_BUFFER+22
    LD BC,4
    LDIR
    LD HL,SPRINTER_FIND_BUFFER+28
    LD BC,4
    LDIR
    RET

; Kept behind the same disk gate for complete production esx-style parity and
; for the static direct-RST policy check.
sprinter_esx_move_fp:
    LD C,DSS_MOVE_FP
    JP sprinter_disk_gate

; ---------------------------------------------------------------------------
; RTC/FAT timestamp and NCZS/FILEUI/SAVELOAD support.
; ---------------------------------------------------------------------------
sprinter_read_rtc:
    IN A,(PORT_WIN1)
    PUSH AF
    IN A,(PORT_WIN3)
    PUSH AF
    LD C,DSS_SYSTIME
    RST 0x10
    LD (SPRINTER_RTC_YEAR),IX
    LD A,E
    LD (SPRINTER_RTC_MONTH),A
    LD A,D
    LD (SPRINTER_RTC_DAY),A
    LD A,H
    LD (SPRINTER_RTC_HOUR),A
    LD A,L
    LD (SPRINTER_RTC_MINUTE),A
    LD A,B
    LD (SPRINTER_KEY_ASCII),A
    POP AF
    OUT (PORT_WIN3),A
    POP AF
    OUT (PORT_WIN1),A
    LD HL,(SPRINTER_RTC_YEAR)
    LD DE,2020
    OR A
    SBC HL,DE
    JR C,sprinter_rtc_bad
    LD A,H
    OR A
    JR NZ,sprinter_rtc_bad
    LD A,L
    CP 32
    JR NC,sprinter_rtc_bad
    LD DE,40
    ADD HL,DE
    LD B,9
sprinter_rtc_year_shift:
    ADD HL,HL
    DJNZ sprinter_rtc_year_shift
    LD A,(SPRINTER_RTC_MONTH)
    OR A
    JR Z,sprinter_rtc_bad
    CP 13
    JR NC,sprinter_rtc_bad
    LD E,A
    LD D,0
    SLA E
    RL D
    SLA E
    RL D
    SLA E
    RL D
    SLA E
    RL D
    SLA E
    RL D
    ADD HL,DE
    LD A,(SPRINTER_RTC_DAY)
    OR A
    JR Z,sprinter_rtc_bad
    CP 32
    JR NC,sprinter_rtc_bad
    LD E,A
    LD D,0
    ADD HL,DE
    LD (SPRINTER_FAT_DATE),HL
    LD A,(SPRINTER_RTC_HOUR)
    CP 24
    JR NC,sprinter_rtc_bad
    LD L,A
    LD H,0
    LD B,11
sprinter_rtc_hour_shift:
    ADD HL,HL
    DJNZ sprinter_rtc_hour_shift
    LD A,(SPRINTER_RTC_MINUTE)
    CP 60
    JR NC,sprinter_rtc_bad
    LD E,A
    LD D,0
    LD B,5
sprinter_rtc_min_shift:
    SLA E
    RL D
    DJNZ sprinter_rtc_min_shift
    ADD HL,DE
    LD A,(SPRINTER_KEY_ASCII)
    CP 60
    JR NC,sprinter_rtc_bad
    SRL A
    LD E,A
    LD D,0
    ADD HL,DE
    LD (SPRINTER_FAT_TIME),HL
    LD A,1
    LD (SPRINTER_CLOCK_READY),A
    OR A
    RET
sprinter_rtc_bad:
    SCF
    RET

; Existing clock/FAT APIs used by the production SAVELOAD overlay.
sprinter_fat_date:
    LD HL,(SPRINTER_FAT_DATE)
    RET
sprinter_fat_time:
    LD HL,(SPRINTER_FAT_TIME)
    RET
sprinter_clock_ready:
    LD A,(SPRINTER_CLOCK_READY)
    LD L,A
    LD H,0
    RET
sprinter_noop:
    RET

; Resolve files relative to the directory containing this EXE.
; PRELOAD captured AppInfo into SPRINTER_APP_DIR before replacing the PSP in
; WIN2.  Keep enough room for both product suffixes here.
sprinter_init_config_path:
    LD HL,SPRINTER_APP_DIR
    LD DE,SPRINTER_CONFIG_DIR
    LD B,230
    LD C,0
sprinter_app_dir_copy:
    LD A,(HL)
    OR A
    JR Z,sprinter_app_dir_done
    LD (DE),A
    LD C,A
    INC HL
    INC DE
    DJNZ sprinter_app_dir_copy
    JR sprinter_app_path_too_long
sprinter_app_dir_done:
    LD A,C
    CP '\\'
    JR Z,sprinter_config_suffix_start
    LD A,'\\'
    LD (DE),A
    INC DE
sprinter_config_suffix_start:
    LD HL,config_suffix
sprinter_config_suffix_copy:
    LD A,(HL)
    LD (DE),A
    INC HL
    INC DE
    OR A
    JR NZ,sprinter_config_suffix_copy
    RET
sprinter_app_path_too_long:
    LD A,0x10
    LD (SPRINTER_FILE_ERROR),A
    SCF
    RET

; ---------------------------------------------------------------------------
; Text helpers preserve the current WIN1/WIN3 mappings around DSS console I/O.
; ---------------------------------------------------------------------------
sprinter_puts:
    PUSH IX
    PUSH IY
    IN A,(PORT_WIN1)
    PUSH AF
    IN A,(PORT_WIN3)
    PUSH AF
    LD C,DSS_PCHARS
    RST 0x10
    POP AF
    OUT (PORT_WIN3),A
    POP AF
    OUT (PORT_WIN1),A
    POP IY
    POP IX
    RET

config_suffix:
    DEFB "SYS\\CONFIG",0
msg_stage2_fail:
    DEFB 0

; Pinned libman 1.3 remains resident in WIN2.  The generated adapter changes
; only OPEN/READ/MOVE_FP/CLOSE into calls through sprinter_disk_gate.
PUBLIC l_load
PUBLIC l_free
PUBLIC l_call
DEFC LIBMAN_MAX_LIBS = 1
DEFC LIBMAN_APP_DIR = SPRINTER_APP_DIR
DEFC LIBMAN_PATH_BUFFER = SPRINTER_PATH_BUFFER
DEFC LIBMAN_PATH_CAPACITY = 256
INCLUDE "libman.asm"

INCLUDE "sprinter_atlas.inc"

sprinter_runtime_end:
