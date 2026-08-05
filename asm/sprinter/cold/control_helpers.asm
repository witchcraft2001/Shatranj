; Cold-local protocol constants and stack-reading helpers.  These cannot point
; into the unmapped base page, and stack-sensitive helpers cannot use a far
; thunk because the thunk deliberately replaces the cold return address.

SECTION code_user

PUBLIC _NETCHESS_PROTO_ACK_PREFIX
PUBLIC _NETCHESS_PROTO_NACK_PREFIX
PUBLIC _NETCHESS_PROTO_MOVE_PREFIX
PUBLIC _NETCHESS_PROTO_CHAT_PREFIX
PUBLIC _NETCHESS_PROTO_DRAW
PUBLIC _NETCHESS_PROTO_CANCEL_DRAW
PUBLIC _NETCHESS_PROTO_CANCEL_RESET
PUBLIC _NETCHESS_PROTO_ACK_RESIGN
PUBLIC _NETCHESS_PROTO_GAME_START
PUBLIC _NETCHESS_PROTO_NACK_RESET
PUBLIC _NETCHESS_PROTO_BYE
PUBLIC _NETCHESS_PROTO_TAKEBACK_PREFIX
PUBLIC _netchess_after_prefix
PUBLIC _netchess_mqtt_session_parse_u16_token

_NETCHESS_PROTO_ACK_PREFIX:       DEFB "ACK ",0
_NETCHESS_PROTO_NACK_PREFIX:      DEFB "NACK ",0
_NETCHESS_PROTO_MOVE_PREFIX:      DEFB "MOVE ",0
_NETCHESS_PROTO_CHAT_PREFIX:      DEFB "CHAT ",0
_NETCHESS_PROTO_DRAW:             DEFB "DRAW",0
_NETCHESS_PROTO_CANCEL_DRAW:      DEFB "CANCEL DRAW",0
_NETCHESS_PROTO_CANCEL_RESET:     DEFB "CANCEL RESET",0
_NETCHESS_PROTO_ACK_RESIGN:       DEFB "ACK RESIGN",0
_NETCHESS_PROTO_GAME_START:       DEFB "GAME START",0
_NETCHESS_PROTO_NACK_RESET:       DEFB "NACK RESET",0
_NETCHESS_PROTO_BYE:              DEFB "BYE",0
_NETCHESS_PROTO_TAKEBACK_PREFIX:  DEFB "TAKEBACK ",0

_netchess_after_prefix:
    ld hl,2
    add hl,sp
    ld c,(hl)
    inc hl
    ld b,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    ex de,hl
control_prefix_loop:
    ld a,(hl)
    or a
    jr z,control_prefix_match
    ld e,a
    ld a,(bc)
    cp e
    jr nz,control_prefix_fail
    inc hl
    inc bc
    jr control_prefix_loop
control_prefix_match:
    ld l,c
    ld h,b
    ret
control_prefix_fail:
    ld hl,0
    ret

_netchess_mqtt_session_parse_u16_token:
    ld hl,2
    add hl,sp
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld c,(hl)
    inc hl
    ld b,(hl)
    push bc
    ld hl,0
    ld b,0
control_u16_loop:
    ld a,(de)
    sub '0'
    cp 10
    jr nc,control_u16_done
    ld c,a
    ld a,h
    cp 0x19
    jr c,control_u16_safe
    jr nz,control_u16_fail
    ld a,l
    cp 0x99
    jr c,control_u16_safe
    jr nz,control_u16_fail
    ld a,c
    cp 6
    jr nc,control_u16_fail
control_u16_safe:
    push de
    ld d,h
    ld e,l
    add hl,hl
    add hl,hl
    add hl,de
    add hl,hl
    ld e,c
    ld d,0
    add hl,de
    pop de
    inc de
    inc b
    jr control_u16_loop
control_u16_done:
    ld a,b
    or a
    jr z,control_u16_fail
    pop bc
    ld a,l
    ld (bc),a
    inc bc
    ld a,h
    ld (bc),a
    ex de,hl
    ret
control_u16_fail:
    pop bc
    ld hl,0
    ret
