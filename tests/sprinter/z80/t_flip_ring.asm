; z80 unit test for asm/sprinter/buffers.asm's dirty-rect ring/sync
; machinery (S5-finish plan D11: buffer flip).
;
; z88dk-ticks' flat 64 KiB model has no accelerator and no real WIN3/
; PORT_Y windowing (t_fill_rect.asm's own comment applies here too), which
; is exactly what makes flip_sync's plain-LDIR row copy fully observable
; end to end here, unlike the accelerator-driven primitives: front_base
; (#C000) and back_base (#C140) are just two ordinary flat-RAM addresses,
; and PORT_Y/WIN3_PORT writes are harmless no-ops, so a sentinel byte
; written at front_base+x and copied by flip_sync really does show up at
; back_base+x in this model, not just conceptually on real hardware.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

start:
        ld      sp,#e800
        call    t_begin

        ; --- flip_log_rect / overflow -> dirty_all --------------------------
        call    flip_ring_reset
        ld      a,(flip_ring_count)
        or      a
        ld      a,1
        call    t_expect_z
        ld      a,(flip_dirty_all)
        or      a
        ld      a,2
        call    t_expect_z

        ld      b,3
.log3:
        ld      hl,10
        ld      (flip_arg_x),hl
        xor     a
        ld      (flip_arg_y),a
        ld      hl,2
        ld      (flip_arg_w),hl
        ld      a,1
        ld      (flip_arg_h),a
        call    flip_log_rect
        djnz    .log3
        ld      a,(flip_ring_count)
        cp      3
        ld      a,3
        call    t_expect_z
        ld      a,(flip_dirty_all)
        or      a
        ld      a,4
        call    t_expect_z

        ; 13 more -> ring exactly full (FLIP_RING_MAX=16), still no
        ; overflow.
        ld      b,13
.log13:
        call    flip_log_rect
        djnz    .log13
        ld      a,(flip_ring_count)
        cp      FLIP_RING_MAX
        ld      a,5
        call    t_expect_z
        ld      a,(flip_dirty_all)
        or      a
        ld      a,6
        call    t_expect_z

        ; The 17th entry overflows -> dirty_all set, count unchanged (the
        ; overflowing entry is coalesced into "everything", not dropped
        ; silently or appended past the ring's own storage).
        call    flip_log_rect
        ld      a,(flip_ring_count)
        cp      FLIP_RING_MAX
        ld      a,7
        call    t_expect_z
        ld      a,(flip_dirty_all)
        or      a
        ld      a,8
        call    t_expect_nz

        ; --- flip_sync via the ring: a real front->back byte copy -----------
        call    flip_ring_reset

        ld      hl,#c000+18             ; one byte before the span
        ld      (hl),#11
        ld      hl,#c000+20             ; front_base+20..+27: sentinel
        ld      de,#c000+21
        ld      bc,7
        ld      (hl),#7e
        ldir
        ld      hl,#c000+28             ; one byte after the span
        ld      (hl),#22

        ld      hl,#c140+18             ; matching back_base span, primed
        ld      (hl),#33                ; with different bytes throughout
        ld      de,#c140+19
        ld      bc,12
        ld      (hl),#00
        ldir

        ld      hl,20
        ld      (flip_arg_x),hl
        xor     a
        ld      (flip_arg_y),a
        ld      hl,8
        ld      (flip_arg_w),hl
        ld      a,1
        ld      (flip_arg_h),a
        call    flip_log_rect
        ld      a,(flip_ring_count)
        cp      1
        ld      a,9
        call    t_expect_z

        call    flip_sync

        ld      hl,#c140+20
        ld      b,8
.rectcheck:
        ld      a,(hl)
        cp      #7e
        ld      a,10
        call    t_expect_z
        inc     hl
        djnz    .rectcheck
        ld      a,(#c140+19)            ; untouched: still the priming byte
        cp      #00
        ld      a,11
        call    t_expect_z
        ld      a,(#c140+28)            ; untouched: still the priming byte
        cp      #00
        ld      a,12
        call    t_expect_z

        ld      a,(flip_ring_count)
        or      a
        ld      a,13
        call    t_expect_z              ; flip_sync reset the ring
        ld      a,(flip_dirty_all)
        or      a
        ld      a,14
        call    t_expect_z

        ; --- flip_sync via dirty_all: a whole-buffer copy --------------------
        ld      hl,#c000
        ld      (hl),#3c
        ld      hl,#c000+150
        ld      (hl),#3c
        ld      hl,#c000+319
        ld      (hl),#3c

        ld      hl,#c140
        ld      (hl),#00
        ld      hl,#c140+150
        ld      (hl),#00
        ld      hl,#c140+319
        ld      (hl),#00

        call    flip_mark_dirty_all
        ld      a,(flip_dirty_all)
        or      a
        ld      a,15
        call    t_expect_nz

        call    flip_sync

        ld      a,(#c140)
        cp      #3c
        ld      a,16
        call    t_expect_z
        ld      a,(#c140+150)
        cp      #3c
        ld      a,17
        call    t_expect_z
        ld      a,(#c140+319)
        cp      #3c
        ld      a,18
        call    t_expect_z

        ld      a,(flip_dirty_all)
        or      a
        ld      a,19
        call    t_expect_z              ; flip_sync reset dirty_all too
        ld      a,(flip_ring_count)
        or      a
        ld      a,20
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

        ; text640.asm is buffers.asm's own dependency (bench_init's
        ; text_font_page), not this test's.
        include "text640.asm"
        include "buffers.asm"
