; Stage-1 SAVELOAD diagnostic bank.  It uses the production esx-style ABI,
; whose implementation is resident in WIN2 and routes every file call through
; the single DSS disk gate.

SECTION code_user

INCLUDE "sprinter_layout.inc"
INCLUDE "asm/sprinter/runtime_api.inc"

PUBLIC sprinter_saveload_save_entry
PUBLIC sprinter_saveload_load_entry
PUBLIC sprinter_saveload_erase_entry

    DEFB 3
    DEFW sprinter_saveload_load_entry
    DEFW sprinter_saveload_save_entry
    DEFW sprinter_saveload_erase_entry

; Return L=0 if the cold->WIN2->base far-call path is not intact.
saveload_probe_base:
    CALL SPR_API_FAR_BASE_PROBE
    LD A,H
    CP 0xBA
    JR NZ,saveload_probe_bad
    LD A,L
    CP 0xCE
    RET Z
saveload_probe_bad:
    XOR A
    LD L,A
    RET

sprinter_saveload_save_entry:
    CALL saveload_probe_base
    LD A,L
    OR A
    RET Z
    LD A,0x11
    LD (SPRINTER_FILE_STAGE),A
    LD HL,SPRINTER_GENERATED_PATH
    CALL SPR_API_ESX_FCREATE
    LD A,(SPRINTER_ESX_HANDLE)
    OR A
    JP Z,saveload_fail
    LD A,1
    LD (SPRINTER_FILE_CREATED),A
    LD HL,SPRINTER_SAVE_PAYLOAD
    LD (SPRINTER_ESX_BUF),HL
    LD HL,60
    LD (SPRINTER_ESX_COUNT),HL
    LD A,0x12
    LD (SPRINTER_FILE_STAGE),A
    CALL SPR_API_ESX_FWRITE
    LD HL,(SPRINTER_ESX_RESULT)
    LD DE,60
    OR A
    SBC HL,DE
    JR Z,saveload_save_close
    CALL SPR_API_ESX_FCLOSE
    JP saveload_fail
saveload_save_close:
    LD A,0x13
    LD (SPRINTER_FILE_STAGE),A
    CALL SPR_API_ESX_FCLOSE
    LD A,L
    OR A
    JP NZ,saveload_fail
    LD A,1
    LD L,A
    RET

sprinter_saveload_load_entry:
    CALL saveload_probe_base
    LD A,L
    OR A
    RET Z
    LD A,0x21
    LD (SPRINTER_FILE_STAGE),A
    LD HL,SPRINTER_GENERATED_PATH
    CALL SPR_API_ESX_FOPEN
    LD A,(SPRINTER_ESX_HANDLE)
    OR A
    JP Z,saveload_fail
    LD HL,SPRINTER_READBACK
    LD (SPRINTER_ESX_BUF),HL
    LD HL,60
    LD (SPRINTER_ESX_COUNT),HL
    LD A,0x22
    LD (SPRINTER_FILE_STAGE),A
    CALL SPR_API_ESX_FREAD
    LD HL,(SPRINTER_ESX_RESULT)
    LD DE,60
    OR A
    SBC HL,DE
    JR Z,saveload_load_close
    CALL SPR_API_ESX_FCLOSE
    JP saveload_fail
saveload_load_close:
    LD A,0x23
    LD (SPRINTER_FILE_STAGE),A
    CALL SPR_API_ESX_FCLOSE
    LD A,L
    OR A
    JP NZ,saveload_fail
    LD L,1
    RET

sprinter_saveload_erase_entry:
    LD A,0x31
    LD (SPRINTER_FILE_STAGE),A
    LD HL,SPRINTER_GENERATED_PATH
    CALL SPR_API_ESX_FUNLINK
    LD HL,(SPRINTER_ESX_RESULT)
    LD A,H
    OR L
    JP Z,saveload_fail
    XOR A
    LD (SPRINTER_FILE_CREATED),A
    INC A
    LD L,A
    RET

saveload_fail:
    XOR A
    LD L,A
    RET
