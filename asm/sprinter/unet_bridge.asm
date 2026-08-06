SECTION code_user

INCLUDE "sprinter_layout.inc"

PUBLIC _sprinter_unet_load
PUBLIC _sprinter_unet_unload
PUBLIC _sprinter_unet_call
PUBLIC _sprinter_unet_getenv

EXTERN l_load
EXTERN l_info
EXTERN l_call
EXTERN l_free
EXTERN sprinter_dss_enter
EXTERN sprinter_dss_leave

DEFC PORT_WIN1 = 0xA2
DEFC PORT_WIN3 = 0xE2
DEFC DSS_ENVIRON = 0x46

; uint8_t sprinter_unet_load(const char *name, uint8_t *info)
_sprinter_unet_load:
    LD HL,2
    ADD HL,SP
    LD E,(HL)
    INC HL
    LD D,(HL)                     ; DE=name
    INC HL
    LD C,(HL)
    INC HL
    LD B,(HL)                     ; BC=info
    PUSH IX
    PUSH IY
    LD A,(SPRINTER_UNET_HANDLE)
    CP 0xFF
    JR NZ,sul_fail
    PUSH BC
    EX DE,HL
    LD A,1                        ; uNet DLLs are always loaded into WIN1
    CALL l_load
    POP DE
    JR C,sul_fail
    LD A,L
    LD (SPRINTER_UNET_HANDLE),A
    CALL l_info
    JR C,sul_unwind
    LD HL,1
    POP IY
    POP IX
    RET
sul_unwind:
    LD A,(SPRINTER_UNET_HANDLE)
    LD L,A
    LD H,0
    CALL l_free
    LD A,0xFF
    LD (SPRINTER_UNET_HANDLE),A
sul_fail:
    LD HL,0
    POP IY
    POP IX
    RET

_sprinter_unet_unload:
    PUSH IX
    PUSH IY
    LD A,(SPRINTER_UNET_HANDLE)
    CP 0xFF
    JR Z,suu_done
    LD L,A
    LD H,0
    CALL l_free
    LD A,0xFF
    LD (SPRINTER_UNET_HANDLE),A
suu_done:
    POP IY
    POP IX
    RET

; uint8_t sprinter_unet_call(uint8_t fn, shatranj_unet_regs_t *regs)
; Return L=1 for a successful libman dispatch.  The uNet status remains in
; regs[0] and is deliberately not derived from carry.
_sprinter_unet_call:
    LD HL,2
    ADD HL,SP
    LD A,(HL)
    LD (SPRINTER_UNET_FUNCTION),A
    INC HL
    LD E,(HL)
    INC HL
    LD D,(HL)
    LD (SPRINTER_UNET_REGS_PTR),DE
    PUSH IX
    PUSH IY
    ; l_call deliberately leaves its DLL window mapped to #FF when the
    ; export returns.  That is fine for traditional single-page programs,
    ; but not for Sprinter's protocol/cold WIN1 callers: their RET address
    ; would then be decoded from page #FF instead of the page that issued
    ; the call.  Keep the exact caller mapping on our WIN2 stack and restore
    ; it before this bridge returns.  Do not delegate this to the far gate:
    ; the first RET after l_call must already fetch from the original page.
    IN A,(PORT_WIN1)
    PUSH AF
    EX DE,HL
    LD A,(HL)
    LD (SPRINTER_UNET_STATUS),A
    INC HL
    LD E,(HL)
    INC HL
    LD D,(HL)
    INC HL
    LD C,(HL)
    INC HL
    LD B,(HL)
    PUSH BC
    POP IX
    INC HL
    LD C,(HL)
    INC HL
    LD B,(HL)
    PUSH BC
    POP IY
    LD A,(SPRINTER_UNET_HANDLE)
    CP 0xFF
    JR Z,suc_dispatch_fail
    LD L,A
    LD H,0
    LD A,(SPRINTER_UNET_FUNCTION)
    LD B,A
    LD A,(SPRINTER_UNET_STATUS)
    CALL l_call
    PUSH AF
    LD (SPRINTER_UNET_OUT_DE),DE
    LD (SPRINTER_UNET_OUT_IX),IX
    LD (SPRINTER_UNET_OUT_IY),IY
    POP HL
    LD A,L
    AND 1
    LD (SPRINTER_UNET_DISPATCH_ERROR),A
    LD A,H
    LD (SPRINTER_UNET_STATUS),A
    JR suc_store
suc_dispatch_fail:
    LD A,1
    LD (SPRINTER_UNET_DISPATCH_ERROR),A
suc_store:
    LD HL,(SPRINTER_UNET_REGS_PTR)
    LD A,(SPRINTER_UNET_STATUS)
    LD (HL),A
    INC HL
    LD DE,(SPRINTER_UNET_OUT_DE)
    LD (HL),E
    INC HL
    LD (HL),D
    INC HL
    LD DE,(SPRINTER_UNET_OUT_IX)
    LD (HL),E
    INC HL
    LD (HL),D
    INC HL
    LD DE,(SPRINTER_UNET_OUT_IY)
    LD (HL),E
    INC HL
    LD (HL),D
    LD A,(SPRINTER_UNET_DISPATCH_ERROR)
    OR A
    LD HL,0
    JR NZ,suc_return
    INC L
suc_return:
    POP AF
    OUT (PORT_WIN1),A
    POP IY
    POP IX
    RET

; Fastcall destination in HL.  Return L=1 only for a non-empty GETENV NET.
_sprinter_unet_getenv:
    PUSH IX
    PUSH IY
    LD (SPRINTER_UNET_REGS_PTR),HL
    IN A,(PORT_WIN1)
    PUSH AF
    IN A,(PORT_WIN3)
    PUSH AF
    EX DE,HL
    LD HL,sprinter_env_net
    LD B,1
    LD C,DSS_ENVIRON
    CALL sprinter_dss_enter
    RST 0x10
    PUSH AF
    CALL sprinter_dss_leave
    POP AF
    ; Environ reports presence in A.  Carry is not part of this API's result
    ; contract and may reflect an internal DSS path, so never reject a valid
    ; value by testing CF here.
    CP 0xFF
    JR NZ,suge_fail
    LD HL,(SPRINTER_UNET_REGS_PTR)
    LD A,(HL)
    OR A
    JR Z,suge_fail
    LD HL,1
    JR suge_restore
suge_fail:
    LD HL,0
suge_restore:
    POP AF
    OUT (PORT_WIN3),A
    POP AF
    OUT (PORT_WIN1),A
    POP IY
    POP IX
    RET

sprinter_env_net:
    DEFB "NET",0
