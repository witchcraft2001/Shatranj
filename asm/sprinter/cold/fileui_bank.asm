; Stage-1 FILEUI diagnostic bank.  It consumes the same short-dirent layout as
; src/spectrum/overlay/fileui_ovl.c and owns the one active iterator.

SECTION code_user

INCLUDE "sprinter_layout.inc"
INCLUDE "asm/sprinter/runtime_api.inc"

PUBLIC sprinter_fileui_free_entry
PUBLIC sprinter_fileui_find_entry

    DEFB 2
    DEFW sprinter_fileui_free_entry
    DEFW sprinter_fileui_find_entry

sprinter_fileui_free_entry:
    LD A,0x01
    LD (SPRINTER_FILE_STAGE),A
    CALL fileui_probe_base
    LD A,L
    OR A
    RET Z
    XOR A
    LD (SPRINTER_FILEUI_USED_MASK),A
    LD (SPRINTER_FILEUI_USED_MASK+1),A
    LD HL,SPRINTER_CONFIG_DIR
    CALL SPR_API_ESX_OPENDIR
    LD A,(SPRINTER_ESX_HANDLE)
    OR A
    JR Z,fileui_choose_slot
fileui_scan_loop:
    LD HL,SPRINTER_DIRENT_BUFFER
    LD (SPRINTER_ESX_BUF),HL
    CALL SPR_API_ESX_READDIR
    LD HL,(SPRINTER_ESX_RESULT)
    LD A,H
    OR L
    JR Z,fileui_scan_done
    CALL fileui_mark_slot
    JR fileui_scan_loop
fileui_scan_done:
    CALL SPR_API_ESX_FCLOSE
fileui_choose_slot:
    LD HL,(SPRINTER_FILEUI_USED_MASK)
    LD DE,1
    LD B,1
fileui_slot_loop:
    LD A,L
    AND E
    LD C,A
    LD A,H
    AND D
    OR C
    JR Z,fileui_slot_found
    SLA E
    RL D
    INC B
    LD A,B
    CP 11
    JR NZ,fileui_slot_loop
    XOR A
    LD L,A
    RET
fileui_slot_found:
    LD A,B
    LD (SPRINTER_FILEUI_SLOT),A
    LD L,1
    RET

; Mark a valid NNYMDHMM.STJ entry in the ten-bit used mask.
fileui_mark_slot:
    LD A,(SPRINTER_DIRENT_BUFFER)
    AND 0x10
    RET NZ
    LD HL,SPRINTER_DIRENT_BUFFER+1
    LD A,(HL)
    CP '0'
    JR C,fileui_mark_no
    CP '2'
    JR NC,fileui_mark_no
    SUB '0'
    LD B,A
    INC HL
    LD A,(HL)
    CP '0'
    JR C,fileui_mark_no
    CP ':'
    JR NC,fileui_mark_no
    SUB '0'
    LD C,A
    LD A,B
    OR A
    JR Z,fileui_mark_ones
    LD A,C
    ADD A,10
    JR fileui_mark_number
fileui_mark_ones:
    LD A,C
fileui_mark_number:
    OR A
    JR Z,fileui_mark_no
    CP 11
    JR NC,fileui_mark_no
    LD B,A
    LD DE,1
fileui_mark_shift:
    DEC B
    JR Z,fileui_mark_store
    SLA E
    RL D
    JR fileui_mark_shift
fileui_mark_store:
    LD HL,(SPRINTER_FILEUI_USED_MASK)
    LD A,L
    OR E
    LD L,A
    LD A,H
    OR D
    LD H,A
    LD (SPRINTER_FILEUI_USED_MASK),HL
fileui_mark_no:
    RET

; Confirm that FILEUI discovers the exact generated 8.3 name after SAVELOAD.
sprinter_fileui_find_entry:
    LD A,0x02
    LD (SPRINTER_FILE_STAGE),A
    LD HL,SPRINTER_CONFIG_DIR
    CALL SPR_API_ESX_OPENDIR
    LD A,(SPRINTER_ESX_HANDLE)
    OR A
    JR Z,fileui_find_fail
fileui_find_loop:
    LD HL,SPRINTER_DIRENT_BUFFER
    LD (SPRINTER_ESX_BUF),HL
    CALL SPR_API_ESX_READDIR
    LD HL,(SPRINTER_ESX_RESULT)
    LD A,H
    OR L
    JR Z,fileui_find_close_fail
    LD HL,SPRINTER_DIRENT_BUFFER+1
    LD DE,SPRINTER_GENERATED_NAME
    LD B,8
fileui_name_cmp:
    LD A,(DE)
    CP (HL)
    JR NZ,fileui_find_loop
    INC DE
    INC HL
    DJNZ fileui_name_cmp
    LD A,(HL)
    CP '.'
    JR NZ,fileui_find_loop
    INC HL
    LD A,(HL)
    CP 'S'
    JR NZ,fileui_find_loop
    INC HL
    LD A,(HL)
    CP 'T'
    JR NZ,fileui_find_loop
    INC HL
    LD A,(HL)
    CP 'J'
    JR NZ,fileui_find_loop
    ; The adapted short dirent carries time/date immediately after the
    ; generated 12-character 8.3 name and its NUL.  Date and minute must
    ; match the RTC-derived common FAT stamp; seconds may tick during I/O.
    LD HL,(SPRINTER_DIRENT_BUFFER+16)
    LD DE,(SPRINTER_FAT_DATE)
    OR A
    SBC HL,DE
    JR NZ,fileui_find_close_fail
    LD HL,(SPRINTER_DIRENT_BUFFER+14)
    LD DE,(SPRINTER_FAT_TIME)
    LD A,H
    CP D
    JR NZ,fileui_find_close_fail
    LD A,L
    XOR E
    AND 0xE0
    JR NZ,fileui_find_close_fail
    CALL SPR_API_ESX_FCLOSE
    LD L,1
    RET
fileui_find_close_fail:
    CALL SPR_API_ESX_FCLOSE
fileui_find_fail:
    XOR A
    LD L,A
    RET

fileui_probe_base:
    CALL SPR_API_FAR_BASE_PROBE
    LD A,H
    CP 0xBA
    JR NZ,fileui_probe_bad
    LD A,L
    CP 0xCE
    RET Z
fileui_probe_bad:
    XOR A
    LD L,A
    RET
