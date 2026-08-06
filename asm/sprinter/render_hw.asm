; Four-pixel Ikkle row writer for the stable fixed buffer zero.  HL points to:
; x(lo,hi), y, four-bit pattern, foreground, background, reserved.

SECTION code_compiler

PUBLIC _sprinter_render_row4

DEFC PORT_WIN3 = 0xE2
DEFC PORT_Y = 0x89

_sprinter_render_row4:
    DI
    IN A,(PORT_WIN3)
    PUSH AF
    LD A,0x50
    OUT (PORT_WIN3),A
    LD E,(HL)
    INC HL
    LD D,(HL)
    INC HL
    LD A,(HL)
    OUT (PORT_Y),A
    INC HL
    LD C,(HL)                    ; pattern
    INC HL
    LD B,(HL)                    ; foreground
    INC HL
    LD A,(HL)                    ; background
    PUSH AF
    LD HL,0xC000
    ADD HL,DE
    LD D,4
srr4_loop:
    BIT 3,C
    JR NZ,srr4_foreground
    POP AF
    PUSH AF
    JR srr4_store
srr4_foreground:
    LD A,B
srr4_store:
    LD (HL),A
    INC HL
    SLA C
    DEC D
    JR NZ,srr4_loop
    POP AF
    LD A,0xC0
    OUT (PORT_Y),A
    POP AF
    OUT (PORT_WIN3),A
    EI
    RET
