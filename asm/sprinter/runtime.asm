; Shatranj Sprinter Stage-1 permanent WIN2 runtime.
;
; WIN0 remains DSS.  WIN1 is the permanent base bank except while a cold bank
; is executing.  This page owns IM2, dispatch/far-call gates, all mutable state
; and every buffer passed to DSS.  WIN3 is never executable or persistent.

SECTION code_user

INCLUDE "sprinter_layout.inc"

DEFC PORT_WIN1 = 0xA2
DEFC PORT_WIN2 = 0xC2
DEFC PORT_WIN3 = 0xE2
DEFC PORT_Y = 0x89
DEFC PORT_RGMOD = 0xC9
DEFC PORT_CBL_CTRL = 0x004E
DEFC CBL_IDLE = 0x80

DEFC DSS_CREATE = 0x0A
DEFC DSS_DELETE = 0x0E
DEFC DSS_OPEN = 0x11
DEFC DSS_CLOSE = 0x12
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
PUBLIC _spectrum_net_background_drain
PUBLIC _spectrum_render_ikkle_at
PUBLIC _spectrum_render_fileui_frame
PUBLIC _spectrum_render_fileui_select
PUBLIC _spectrum_frame_wait
PUBLIC _spectrum_key_poll

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
DEFC _spectrum_net_runtime_fat_date = 0x8224
DEFC _spectrum_net_runtime_fat_time = 0x8227
DEFC _spectrum_net_background_drain = 0x822A
DEFC _spectrum_render_ikkle_at = 0x822D
DEFC _spectrum_render_fileui_frame = 0x8230
DEFC _spectrum_render_fileui_select = 0x8233
DEFC _spectrum_net_runtime_clock_ready = 0x8236
DEFC _spectrum_frame_wait = 0x8239
DEFC _spectrum_key_poll = 0x823C

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
    JP sprinter_far_base_probe
    JP sprinter_puts
    JP sprinter_fat_date
    JP sprinter_fat_time
    JP sprinter_noop
    JP sprinter_noop
    JP sprinter_noop
    JP sprinter_noop
    JP sprinter_clock_ready
    JP sprinter_frame_wait
    JP sprinter_key_poll_c

    DEFS 0x0240-$,0

sprinter_runtime_start:
    DI
    LD SP,SPRINTER_STACK_TOP
    LD HL,SPRINTER_OVERLAY_CONTEXT
    XOR A
    LD (HL),A
    LD DE,SPRINTER_OVERLAY_CONTEXT+1
    LD BC,0x01A8
    LDIR
    LD A,OVL_INVALID
    LD (SPRINTER_OVERLAY_LOADED_ID),A
    LD (SPRINTER_OVERLAY_CACHE_ID),A
    CALL sprinter_copy_save_payload
    CALL sprinter_cbl_arm

    LD A,0x80
    LD I,A
    IM 2
    EI

    LD HL,msg_banner
    CALL sprinter_puts
    CALL sprinter_validate_base
    JR C,sprinter_fail_bank
    LD HL,msg_base_ok
    CALL sprinter_puts
    CALL sprinter_frame_wait
    JR C,sprinter_fail_frame
    CALL sprinter_frame_wait
    JR C,sprinter_fail_frame
    LD HL,msg_frame_ok
    CALL sprinter_puts
    CALL sprinter_read_rtc
    JR C,sprinter_fail_rtc
    LD HL,msg_rtc_ok
    CALL sprinter_puts
    CALL sprinter_run_file_diagnostic
    JR C,sprinter_fail_file
    CALL sprinter_validate_base
    JR C,sprinter_fail_bank
    LD HL,msg_tests_ok
    CALL sprinter_puts
    ; Do not let the key used to launch the program, or a stale Esc from DSS,
    ; terminate keyboard echo before the user can inspect the results.
    CALL sprinter_key_clear

sprinter_keyboard_loop:
    CALL sprinter_frame_wait
    JR C,sprinter_fail_frame
    CALL sprinter_key_poll
    LD A,L
    OR A
    JR Z,sprinter_keyboard_loop
    CP 0x8A
    JR Z,sprinter_pass
    LD (SPRINTER_KEY_MAPPED),A
    LD HL,msg_key
    CALL sprinter_puts
    LD A,(SPRINTER_KEY_MAPPED)
    CALL sprinter_put_hex8
    LD HL,msg_crlf
    CALL sprinter_puts
    JR sprinter_keyboard_loop

sprinter_pass:
    XOR A
    LD (SPRINTER_DIAG_RESULT),A
    LD HL,msg_pass
    CALL sprinter_puts
    LD HL,msg_exit_wait
    CALL sprinter_puts
    CALL sprinter_wait_ack
    JP sprinter_cleanup
sprinter_fail_bank:
    LD A,1
    JR sprinter_set_failure
sprinter_fail_frame:
    LD A,2
    JR sprinter_set_failure
sprinter_fail_file:
    LD A,3
    JR sprinter_set_failure
sprinter_fail_rtc:
    LD A,4
sprinter_set_failure:
    LD (SPRINTER_DIAG_RESULT),A
    ; Report and acknowledge while the current DSS console is still visible.
    ; SetVMod in final cleanup clears both screens on real hardware.
    LD HL,msg_fail
    CALL sprinter_puts
    LD A,(SPRINTER_DIAG_RESULT)
    CALL sprinter_put_hex8
    LD HL,msg_crlf
    CALL sprinter_puts
    LD HL,msg_exit_wait
    CALL sprinter_puts
    CALL sprinter_wait_ack

sprinter_cleanup:
    ; Erase only the file this process successfully created.
    LD A,(SPRINTER_FILE_CREATED)
    OR A
    JR Z,sprinter_cleanup_map
    LD A,OVL_SAVELOAD
    LD E,2
    CALL sprinter_overlay_dispatch_cached_ae
    LD A,L
    OR A
    JR NZ,sprinter_cleanup_map
    LD A,5
    LD (SPRINTER_DIAG_RESULT),A
sprinter_cleanup_map:
    IN A,(PORT_WIN1)
    LD HL,SPRINTER_PAGE_TABLE
    CP (HL)
    JR Z,sprinter_cleanup_video
    LD A,5
    LD (SPRINTER_DIAG_RESULT),A

sprinter_cleanup_video:
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
sprinter_exit:
    LD A,(SPRINTER_DIAG_RESULT)
    LD B,A
    LD C,DSS_EXIT
    RST 0x10
    DI
    HALT

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
    OR A
    RET
sprinter_frame_nested:
    LD A,3
    LD (SPRINTER_PLATFORM_ERROR),A
    SCF
    RET

sprinter_key_clear:
    LD B,DSS_SCANKEY
    JR sprinter_key_control

sprinter_wait_ack:
    LD B,DSS_WAITKEY

sprinter_key_control:
    IN A,(PORT_WIN1)
    PUSH AF
    IN A,(PORT_WIN3)
    PUSH AF
    LD C,DSS_K_CLEAR
    RST 0x10
    POP AF
    OUT (PORT_WIN3),A
    POP AF
    OUT (PORT_WIN1),A
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
    LD A,D
    AND 0x7F
    LD (SPRINTER_KEY_SCAN),A
    POP AF
    OUT (PORT_WIN3),A
    POP AF
    OUT (PORT_WIN1),A
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

sprinter_key_poll_c:
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
    PUSH IX
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
    JR NZ,sprinter_disk_reentry
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
    IM 2
    EI
    LD IX,(SPRINTER_DISK_OUT_IX)
    LD BC,(SPRINTER_DISK_OUT_BC)
    LD DE,(SPRINTER_DISK_OUT_DE)
    LD HL,(SPRINTER_DISK_OUT_AF)
    PUSH HL
    POP AF
    LD HL,(SPRINTER_DISK_OUT_HL)
    POP IY
    POP IX
    RET
sprinter_disk_reentry:
    LD A,3
    LD (SPRINTER_PLATFORM_ERROR),A
    LD A,0xFF
    SCF
    POP IY
    POP IX
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
    LD C,DSS_OPEN
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
    XOR A
    LD (SPRINTER_ESX_RESULT),A
    LD (SPRINTER_ESX_RESULT+1),A
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
    LD C,DSS_CLOSE
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
    CALL sprinter_disk_gate
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
    CALL sprinter_disk_gate
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

; Unused by the diagnostic, but kept behind the same gate for the complete
; Stage-1 disk-call set and for the static direct-RST policy check.
sprinter_esx_move_fp:
    LD C,DSS_MOVE_FP
    JP sprinter_disk_gate

; ---------------------------------------------------------------------------
; RTC/FAT timestamp and NCZS/FILEUI/SAVELOAD diagnostic.
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

sprinter_build_generated_path:
    LD A,(SPRINTER_FILEUI_SLOT)
    CP 10
    JR Z,sprinter_slot_ten
    LD HL,SPRINTER_GENERATED_NAME
    LD (HL),'0'
    INC HL
    ADD A,'0'
    LD (HL),A
    JR sprinter_slot_stamp
sprinter_slot_ten:
    LD HL,SPRINTER_GENERATED_NAME
    LD (HL),'1'
    INC HL
    LD (HL),'0'
sprinter_slot_stamp:
    INC HL
    LD DE,(SPRINTER_RTC_YEAR)
    LD BC,2020
    EX DE,HL
    OR A
    SBC HL,BC
    LD A,L
    EX DE,HL
    CALL sprinter_b32_char
    LD (HL),A
    INC HL
    LD A,(SPRINTER_RTC_MONTH)
    CALL sprinter_b32_char
    LD (HL),A
    INC HL
    LD A,(SPRINTER_RTC_DAY)
    CALL sprinter_b32_char
    LD (HL),A
    INC HL
    LD A,(SPRINTER_RTC_HOUR)
    CALL sprinter_b32_char
    LD (HL),A
    INC HL
    LD A,(SPRINTER_RTC_MINUTE)
    LD B,'0'
sprinter_minute_tens:
    CP 10
    JR C,sprinter_minute_done
    SUB 10
    INC B
    JR sprinter_minute_tens
sprinter_minute_done:
    LD (HL),B
    INC HL
    ADD A,'0'
    LD (HL),A
    INC HL
    LD (HL),0
    LD HL,SPRINTER_CONFIG_DIR
    LD DE,SPRINTER_GENERATED_PATH
    LD B,241
sprinter_path_prefix_copy:
    LD A,(HL)
    OR A
    JR Z,sprinter_path_prefix_done
    LD (DE),A
    INC HL
    INC DE
    DJNZ sprinter_path_prefix_copy
    LD A,0x10
    LD (SPRINTER_FILE_ERROR),A
    SCF
    RET
sprinter_path_prefix_done:
    LD A,'\\'
    LD (DE),A
    INC DE
sprinter_path_name_copy_start:
    LD HL,SPRINTER_GENERATED_NAME
    LD B,8
sprinter_path_name_copy:
    LD A,(HL)
    LD (DE),A
    INC HL
    INC DE
    DJNZ sprinter_path_name_copy
    LD A,'.'
    LD (DE),A
    INC DE
    LD A,'S'
    LD (DE),A
    INC DE
    LD A,'T'
    LD (DE),A
    INC DE
    LD A,'J'
    LD (DE),A
    INC DE
    XOR A
    LD (DE),A
    OR A
    RET

sprinter_b32_char:
    CP 10
    JR C,sprinter_b32_digit
    ADD A,'A'-10
    RET
sprinter_b32_digit:
    ADD A,'0'
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

sprinter_run_file_diagnostic:
    XOR A
    LD (SPRINTER_FILE_STAGE),A
    LD (SPRINTER_FILE_ERROR),A
    CALL sprinter_init_config_path
    JP C,sprinter_file_fail
    LD A,OVL_FILEUI
    LD E,0
    CALL sprinter_overlay_dispatch_cached_ae
    LD A,L
    OR A
    JP Z,sprinter_file_fail
    LD HL,msg_fileui_scan
    CALL sprinter_puts
    CALL sprinter_read_rtc
    JP C,sprinter_file_fail
    CALL sprinter_build_generated_path
    JP C,sprinter_file_fail
    LD HL,msg_saveload_path
    CALL sprinter_puts
    LD HL,SPRINTER_GENERATED_PATH
    CALL sprinter_puts
    LD HL,msg_crlf
    CALL sprinter_puts
    LD A,OVL_SAVELOAD
    LD E,1
    CALL sprinter_overlay_dispatch_cached_ae
    LD A,L
    OR A
    JP Z,sprinter_file_fail
    LD HL,msg_saveload_write
    CALL sprinter_puts
    LD A,OVL_FILEUI
    LD E,1
    CALL sprinter_overlay_dispatch_cached_ae
    LD A,L
    OR A
    JP Z,sprinter_file_fail
    LD HL,msg_fileui_find
    CALL sprinter_puts
    LD A,OVL_SAVELOAD
    LD E,0
    CALL sprinter_overlay_dispatch_cached_ae
    LD A,L
    OR A
    JP Z,sprinter_file_fail
    LD HL,SPRINTER_SAVE_PAYLOAD
    LD DE,SPRINTER_READBACK
    LD B,60
sprinter_file_compare:
    LD A,(DE)
    CP (HL)
    JP NZ,sprinter_file_fail
    INC HL
    INC DE
    DJNZ sprinter_file_compare
    LD HL,msg_saveload_read
    CALL sprinter_puts
    LD A,OVL_SAVELOAD
    LD E,2
    CALL sprinter_overlay_dispatch_cached_ae
    LD A,L
    OR A
    JP Z,sprinter_file_fail
    LD HL,msg_saveload_erase
    CALL sprinter_puts
    OR A
    RET
sprinter_file_fail:
    LD HL,msg_file_detail
    CALL sprinter_puts
    LD A,(SPRINTER_FILE_STAGE)
    CALL sprinter_put_hex8
    LD HL,msg_file_dss
    CALL sprinter_puts
    LD A,(SPRINTER_FILE_ERROR)
    CALL sprinter_put_hex8
    LD HL,msg_crlf
    CALL sprinter_puts
    SCF
    RET

sprinter_copy_save_payload:
    LD HL,save_payload_text
    LD DE,SPRINTER_SAVE_PAYLOAD
    LD BC,60
    LDIR
    RET

; Resolve all Stage-1 files relative to the directory containing this EXE.
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

sprinter_validate_base:
    IN A,(PORT_WIN1)
    LD HL,SPRINTER_PAGE_TABLE
    CP (HL)
    JR NZ,sprinter_base_bad
    LD HL,(0x4030)
    LD DE,0x5348
    OR A
    SBC HL,DE
    JR NZ,sprinter_base_bad
    CALL sprinter_far_base_probe
    LD A,H
    CP 0xBA
    JR NZ,sprinter_base_bad
    LD A,L
    CP 0xCE
    RET Z
sprinter_base_bad:
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

sprinter_putchar:
    PUSH IX
    PUSH IY
    PUSH AF
    IN A,(PORT_WIN1)
    PUSH AF
    IN A,(PORT_WIN3)
    PUSH AF
    POP DE
    POP BC
    POP AF
    PUSH BC
    PUSH DE
    LD C,DSS_PUTCHAR
    RST 0x10
    POP AF
    OUT (PORT_WIN3),A
    POP AF
    OUT (PORT_WIN1),A
    POP IY
    POP IX
    RET

sprinter_put_hex8:
    PUSH AF
    RRCA
    RRCA
    RRCA
    RRCA
    CALL sprinter_put_hex_nibble
    POP AF
sprinter_put_hex_nibble:
    AND 0x0F
    ADD A,'0'
    CP '9'+1
    JR C,sprinter_put_hex_emit
    ADD A,'A'-'9'-1
sprinter_put_hex_emit:
    JP sprinter_putchar

; IM1-only variant used after final cleanup; no mapping needs to survive.
sprinter_put_hex8_im1:
    PUSH AF
    RRCA
    RRCA
    RRCA
    RRCA
    CALL sprinter_put_hex_nibble_im1
    POP AF
sprinter_put_hex_nibble_im1:
    AND 0x0F
    ADD A,'0'
    CP '9'+1
    JR C,sprinter_put_hex_emit_im1
    ADD A,'A'-'9'-1
sprinter_put_hex_emit_im1:
    LD C,DSS_PUTCHAR
    RST 0x10
    RET

config_suffix:
    DEFB "SYS\\CONFIG",0
save_payload_text:
    DEFB "uazam4iIiIgAAAAAAAAAAAAAAAAAAAAAEREREUI1YyR8_wAAAQEAAAAAOwGm"
msg_banner:
    DEFB "Shatranj Sprinter stage 1",13,10
    DEFB "PRELOAD monoblock; network disabled",13,10,0
msg_base_ok:
    DEFB "Base bank: OK",13,10,0
msg_frame_ok:
    DEFB "IM2/frame source: OK",13,10,0
msg_rtc_ok:
    DEFB "RTC/FAT timestamp: OK",13,10,0
msg_tests_ok:
    DEFB "Banks, IM2, RTC, SAVELOAD and FILEUI: OK",13,10
    DEFB "Keyboard echo active; Esc exits",13,10,0
msg_fileui_scan:
    DEFB "FILEUI scan: OK",13,10,0
msg_saveload_path:
    DEFB "SAVELOAD path: ",0
msg_saveload_write:
    DEFB "SAVELOAD write: OK",13,10,0
msg_fileui_find:
    DEFB "FILEUI find/FAT stamp: OK",13,10,0
msg_saveload_read:
    DEFB "SAVELOAD read/compare: OK",13,10,0
msg_saveload_erase:
    DEFB "SAVELOAD erase: OK",13,10,0
msg_file_detail:
    DEFB "File failure stage=",0
msg_file_dss:
    DEFB " DSS=",0
msg_key:
    DEFB "key=",0
msg_pass:
    DEFB "PASS",13,10,0
msg_fail:
    DEFB "FAIL exit=",0
msg_exit_wait:
    DEFB "Press any key to return to DSS",13,10,0
msg_crlf:
    DEFB 13,10,0

INCLUDE "sprinter_atlas.inc"

sprinter_runtime_end:
