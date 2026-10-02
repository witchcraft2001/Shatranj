; Run the real exit_stand and console cleanup with DSS boundary doubles.
; Cover T40/T80 and graphical callers on both saved pages, regardless of
; the game's last flip. A stale page-0 override must fail this fixture.
        device noslot64k
        org 0
        jp start
        ds #10-$,0
        jp dss_stub
        ds #100-$,0
        include "harness.inc"

start:
        ld sp,#e800
        call t_begin
        ; ticks has no Sprinter I/O readback. Inspect the assembled exit
        ; instructions instead: it must not override DSS's selected page.
        ld hl,exit_stand
        ld b,exit_stand.hang-exit_stand
.check_page_writes:
        ld a,(hl)
        cp #d3                         ; OUT (n),A
        jr nz,.next_byte
        inc hl
        ld a,(hl)
        cp PORT_RGMOD
        ld a,2
        call t_expect_nz
        dec hl
.next_byte:
        inc hl
        djnz .check_page_writes
        ld hl,mode_cases
        ld (case_ptr),hl
        ld a,4
        ld (modes_left),a
.mode:
        ld hl,(case_ptr)
        ld a,(hl)
        ld (HDR_ADDR+HDR_SAVED_MODE_OFFSET),a
        inc hl
        ld a,(hl)
        ld (expected_width),a
        inc hl
        ld (case_ptr),hl
        xor a
        ld (saved_screen),a
.screen:
        ld a,(saved_screen)
        ld (HDR_ADDR+HDR_SAVED_SCREEN_OFFSET),a
        xor a
        ld (game_screen),a
.flip:
        ld a,(game_screen)
        out (PORT_RGMOD),a
        xor a
        ld (phase),a
        ld (clear_count),a
        ld (locate_count),a
        ld (exit_count),a
        ld a,#ff
        ld (console_attr),a
        ld a,#37
        ld (im2_saved_i),a
        ld a,#be
        ld i,a
        im 2
        ei
        call exit_stand
        ld a,(exit_count)
        cp 1
        ld a,1
        call t_expect_z
        ld a,i
        cp #37
        ld a,3
        call t_expect_z
        ld a,(expected_width)
        or a
        jr z,.graph
        ld a,(console_attr)
        cp #07
        ld a,4
        call t_expect_z
        ld a,(clear_count)
        cp 1
        ld a,5
        call t_expect_z
        ld a,(locate_count)
        cp 1
        ld a,6
        call t_expect_z
        jr .next
.graph:
        ld a,(clear_count)
        or a
        ld a,7
        call t_expect_z
        ld a,(locate_count)
        or a
        ld a,8
        call t_expect_z
.next:
        ld hl,game_screen
        inc (hl)
        ld a,(hl)
        cp 2
        jp c,.flip
        ld hl,saved_screen
        inc (hl)
        ld a,(hl)
        cp 2
        jp c,.screen
        ld hl,modes_left
        dec (hl)
        jp nz,.mode
        call t_end
        halt

ng_shutdown:
        ld a,i
        jp po,boundary_fail
        ld a,(phase)
        or a
        jp nz,boundary_fail
        ld a,1
        ld (phase),a
        ret

svmod_safe:
        ; Real DSS SetVMod ends by selecting B through SCREEN_SWITCH=#C9.
        ld (seen_mode),a
        ld a,b
        out (PORT_RGMOD),a
        call expect_di
        ld a,(seen_mode)
        ld hl,HDR_ADDR+HDR_SAVED_MODE_OFFSET
        cp (hl)
        ld a,9
        call t_expect_z
        ld a,(saved_screen)
        cp b
        ld a,10
        call t_expect_z
        ld a,(phase)
        cp 1
        ld a,11
        call t_expect_z
        ld a,2
        ld (phase),a
        ret

dss_stub:
        push af
        ld a,c
        cp DSS_EXIT
        jr z,.exit
        cp DSS_CLEAR
        jr z,.clear
        cp DSS_LOCATE
        jp z,.locate
        pop af
        jp boundary_fail
.clear:
        pop af
        cp ' '
        ld a,12
        call t_expect_z
        ld a,b
        cp #07
        ld a,13
        call t_expect_z
        ld a,h
        cp 32
        ld a,14
        call t_expect_z
        ld a,(expected_width)
        cp l
        ld a,15
        call t_expect_z
        ld a,d
        or e
        ld a,16
        call t_expect_z
        ld a,(phase)
        cp 2
        ld a,17
        call t_expect_z
        call expect_di
        ld a,3
        ld (phase),a
        ld a,b
        ld (console_attr),a
        ld hl,clear_count
        inc (hl)
        ; LOCATE must reload its parameters, even if CLEAR clobbers DE.
        ld de,#1234
        ret
.locate:
        pop af
        ld a,d
        or e
        ld a,18
        call t_expect_z
        ld a,(phase)
        cp 3
        ld a,19
        call t_expect_z
        call expect_di
        ld a,4
        ld (phase),a
        ld hl,locate_count
        inc (hl)
        ret
.exit:
        pop af
        ld a,b
        or a
        ld a,20
        call t_expect_z
        ld a,i
        call po,boundary_fail
        ld a,(expected_width)
        or a
        ld a,2
        jr z,.expect_phase
        ld a,4
.expect_phase:
        ld hl,phase
        cp (hl)
        ld a,22
        call t_expect_z
        ld hl,exit_count
        inc (hl)
        ; DSS Exit does not return. Drop the RST return address to let
        ; the fixture regain control at exit_stand's own caller.
        pop hl
        ret
expect_di:
        push af
        ld a,i
        call pe,boundary_fail
        pop af
        ret
boundary_fail:
        ld a,23
        jp t_fail

mode_cases: db DSS_VMOD_T40,40,DSS_VMOD_T80,80,DSS_VMOD_G320,0,DSS_VMOD_G640,0
case_ptr: dw 0
modes_left: db 0
saved_screen: db 0
game_screen: db 0
expected_width: db 0
seen_mode: db 0
phase: db 0
clear_count: db 0
locate_count: db 0
exit_count: db 0
console_attr: db 0

        assert $ < #4000
        ds #4000-$,0
HDR:    ds 256,0
        ds #8000-$,0
        include "im2_s1.asm"
        include "text640.asm"
        include "buffers.asm"
        include "console_exit.asm"
        assert $ < TEST_RESULT
        end start
