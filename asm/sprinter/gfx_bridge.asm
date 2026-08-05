SECTION code_user

INCLUDE "sprinter_layout.inc"

PUBLIC _gfx320_libman_call
PUBLIC _sprinter_gfx_load
PUBLIC _sprinter_gfx_unload

EXTERN l_load
EXTERN l_call
EXTERN l_free

; gfx_u8 gfx320_libman_call(handle, entry, regs *)
_gfx320_libman_call:
    LD HL,2
    ADD HL,SP
    LD A,(HL)
    LD (SPRINTER_GFX_REGS+0),A
    INC HL
    LD A,(HL)
    LD (SPRINTER_GFX_REGS+1),A
    INC HL
    LD E,(HL)
    INC HL
    LD D,(HL)
    LD (SPRINTER_GFX_REGS+2),DE
    PUSH IX
    PUSH IY
    EX DE,HL
    LD A,(HL)
    LD (SPRINTER_GFX_REGS+4),A
    INC HL
    LD E,(HL)
    INC HL
    LD D,(HL)
    LD (SPRINTER_GFX_REGS+5),DE
    INC HL
    LD E,(HL)
    INC HL
    LD D,(HL)
    LD (SPRINTER_GFX_REGS+7),DE
    INC HL
    LD E,(HL)
    INC HL
    LD D,(HL)
    LD (SPRINTER_GFX_REGS+9),DE

    LD A,(SPRINTER_GFX_REGS+0)
    LD L,A
    LD H,0
    LD A,(SPRINTER_GFX_REGS+1)
    LD B,A
    LD A,(SPRINTER_GFX_REGS+4)
    LD DE,(SPRINTER_GFX_REGS+5)
    LD IX,(SPRINTER_GFX_REGS+7)
    LD IY,(SPRINTER_GFX_REGS+9)
    CALL l_call
    PUSH AF
    LD (SPRINTER_GFX_REGS+5),DE
    LD (SPRINTER_GFX_REGS+7),IX
    LD (SPRINTER_GFX_REGS+9),IY
    POP HL
    LD A,L
    AND 1
    LD (SPRINTER_GFX_REGS+11),A
    LD A,H
    LD (SPRINTER_GFX_REGS+4),A

    LD HL,(SPRINTER_GFX_REGS+2)
    LD A,(SPRINTER_GFX_REGS+4)
    LD (HL),A
    INC HL
    LD DE,(SPRINTER_GFX_REGS+5)
    LD (HL),E
    INC HL
    LD (HL),D
    INC HL
    LD DE,(SPRINTER_GFX_REGS+7)
    LD (HL),E
    INC HL
    LD (HL),D
    INC HL
    LD DE,(SPRINTER_GFX_REGS+9)
    LD (HL),E
    INC HL
    LD (HL),D

    LD A,(SPRINTER_GFX_REGS+11)
    OR A
    JR Z,gfx_call_ok
    LD A,(SPRINTER_GFX_REGS+4)
    OR A
    JR NZ,gfx_call_error_ready
    LD A,0xFF
gfx_call_error_ready:
    LD L,A
    JR gfx_call_return
gfx_call_ok:
    LD L,0
gfx_call_return:
    LD H,0
    POP IY
    POP IX
    RET

; Fastcall filename in HL; return handle or FF.
_sprinter_gfx_load:
    ; Native libman uses both index registers while loading/relocating.  This
    ; bridge is a callee in the sdcc_iy ABI, so neither frame register may leak
    ; back clobbered into sprinter_gfx_start().
    PUSH IX
    PUSH IY
    LD A,1
    CALL l_load
    JR C,gfx_load_error
    POP IY
    POP IX
    RET
gfx_load_error:
    LD HL,0x00FF
    POP IY
    POP IX
    RET

; Fastcall handle in L.
_sprinter_gfx_unload:
    PUSH IX
    PUSH IY
    LD H,0
    CALL l_free
    POP IY
    POP IX
    RET
