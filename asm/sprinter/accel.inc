; Sprinter hardware accelerator opcodes (port.md section 3.3). ACC_SET_SIZE
; through ACC_OFF match sources/libs/common/accelerator.inc; ACC_COPY_V
; (absent from that donor) comes from the HW_NOTES.md opcode table (from
; ACCELER.TDF: LD A,A = vertical copy, 320-byte step) and acc_park_y is
; this port's own R3/R10 helper. These LD r,r pairs are decoded by the
; accelerator hardware itself when armed, not executed as ordinary
; register-to-register loads.
;
; ACC_SET_SIZE must be immediately followed by the *next* `LD A,n`: hardware
; samples that instruction's own immediate operand (0 encodes 256). The
; actual trigger is the following memory write (`LD (HL),A` for a fill,
; `LD A,(HL) / LD (DE),A` for a copy -- nothing may come between those two
; for a copy, since the source is latched by the read); every triggered
; sequence must end with ACC_OFF, and the whole thing runs under DI (R3).
; See asm/sprinter/video_s1.asm's accel_smoke for a worked example, itself
; adapted from sources/libs/gfx640/gfx640.asm's hfill_chunk/vfill_chunk/
; copy_direct (the only proven-on-hardware reference for this calling
; convention available to this port).

        IFNDEF SPRINTER_ACCEL_INC
        DEFINE SPRINTER_ACCEL_INC

        INCLUDE "dss.inc"

        MACRO ACC_SET_SIZE
        ld      d,d
        ENDM

        MACRO ACC_FILL_H
        ld      c,c
        ENDM

        MACRO ACC_FILL_V
        ld      e,e
        ENDM

        MACRO ACC_COPY_H
        ld      l,l
        ENDM

        MACRO ACC_COPY_V
        ld      a,a
        ENDM

        MACRO ACC_OFF
        ld      b,b
        ENDM

; End-of-sequence VRAM row park (R3/R10): every accelerator block and every
; palette/VRAM DI section ends with PORT_Y=#C0 before EI.
        MACRO acc_park_y
        ld      a,#C0
        out     (PORT_Y),a
        ENDM

        ENDIF
