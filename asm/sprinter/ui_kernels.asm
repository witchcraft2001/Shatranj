; UI-only copies of the three compact helpers used by the Sprinter UI bank.
; Keeping them local prevents a UI -> protocol resident-page call while the
; non-recursive UI gate is active.

SECTION code_user

PUBLIC _netchesszx_asm_move_parse_coords
PUBLIC _netchesszx_asm_put_timer_digit
PUBLIC _netchesszx_asm_timer_tick_one_second

_netchesszx_asm_move_parse_coords:
    LD A,(HL)
    SUB 'a'
    CP 8
    JR NC,ui_move_coords_invalid
    LD C,A
    INC HL
    LD A,'8'
    SUB (HL)
    CP 8
    JR NC,ui_move_coords_invalid
    RLCA
    RLCA
    RLCA
    ADD A,C
    LD C,A
    INC HL
    LD A,(HL)
    SUB 'a'
    CP 8
    JR NC,ui_move_coords_invalid
    LD B,A
    INC HL
    LD A,'8'
    SUB (HL)
    CP 8
    JR NC,ui_move_coords_invalid
    RLCA
    RLCA
    RLCA
    ADD A,B
    CP C
    JR Z,ui_move_coords_invalid
    LD H,A
    LD L,C
    RET
ui_move_coords_invalid:
    LD HL,0xFFFF
    RET

_netchesszx_asm_put_timer_digit:
    LD HL,2
    ADD HL,SP
    LD E,(HL)
    INC HL
    LD D,(HL)
    INC HL
    LD B,(HL)
    LD C,0
ui_timer_digit_loop:
    LD A,B
    CP 10
    JR C,ui_timer_digit_store
    SUB 10
    LD B,A
    INC C
    JR ui_timer_digit_loop
ui_timer_digit_store:
    LD A,C
    ADD A,'0'
    LD (DE),A
    INC DE
    LD A,B
    ADD A,'0'
    LD (DE),A
    RET

_netchesszx_asm_timer_tick_one_second:
    LD HL,2
    ADD HL,SP
    LD E,(HL)
    INC HL
    LD D,(HL)
    INC HL
    LD C,(HL)
    INC HL
    LD B,(HL)
    INC HL
    LD A,(HL)
    INC HL
    LD H,(HL)
    LD L,A
    LD A,(DE)
    CP 99
    JR NZ,ui_timer_inc_second
    LD A,(BC)
    CP 59
    JR NZ,ui_timer_inc_second
    LD A,(HL)
    CP 59
    RET Z
ui_timer_inc_second:
    INC (HL)
    LD A,(HL)
    CP 60
    RET C
    LD (HL),0
    LD A,(BC)
    INC A
    LD (BC),A
    CP 60
    RET C
    XOR A
    LD (BC),A
    LD A,(DE)
    INC A
    LD (DE),A
    RET
