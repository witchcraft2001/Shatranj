; R1: WIN0 carries the DSS system page and may only be temporarily replaced
; under DI, for the whole duration of the replacement, restored before EI.
; win0_map_di/win0_restore are the ONLY places allowed to write WIN0_PORT
; (checked by tools/check_sprinter_win0.py) -- no DSS RST call may appear
; between them, and they do not nest. Call only from an EI context.
;
; Convention: caller loads A with the target page before invoking
; win0_map_di (matches the ACC_* macro style of "set A/HL, then invoke the
; op" used throughout this codebase).

        IFNDEF SPRINTER_WIN0_INC
        DEFINE SPRINTER_WIN0_INC

        INCLUDE "dss.inc"

; A = target page. Clobbers AF (A ends up holding the target page again).
        MACRO win0_map_di
        di
        push    af
        in      a,(WIN0_PORT)
        ld      (win0_saved_page),a
        pop     af
        out     (WIN0_PORT),a
        ENDM

; Restores WIN0 and re-enables interrupts. Clobbers AF.
        MACRO win0_restore
        ld      a,(win0_saved_page)
        out     (WIN0_PORT),a
        ei
        ENDM

win0_saved_page: DB 0

        ENDIF
