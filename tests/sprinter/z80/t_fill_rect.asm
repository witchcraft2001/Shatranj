; z80 unit test for asm/sprinter/gfx_core.asm's gfx_fill_rect/gfx_hline/
; gfx_clear_buffer.
;
; z88dk-ticks' flat 64 KiB model has no Sprinter accelerator: ACC_* macros
; assemble to harmless register-to-register loads (LD D,D etc), and PORT_Y
; writes are ordinary no-op port I/O (t_draw_grid.asm's comment applies here
; too). So a "burst" trigger like ACC_FILL_V's LD (HL),E only ever executes
; as ONE literal single-byte write in this model -- the many rows a real
; accelerator would fan out from that one instruction never happen here.
; That collapses gfx_fill_rect/gfx_hline down to: one byte written per
; column (fill_rect) or per accelerator chunk (hline), at addresses that
; do NOT depend on y or h/w-beyond-chunking -- exactly what makes the
; written BYTES and their boundaries observable, while row placement stays
; unobservable (as in t_draw_grid). gfx_clear_buffer's column loop is a
; real CPU djnz over all 320 columns, so it verifies end-to-end.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

start:
        ld      sp,#e800
        call    t_begin

        ; --- gfx_fill_rect: sentinel a span, fill an 8-byte-wide column
        ; run at x_byte=10, and check exactly those 8 bytes changed.
        ld      hl,#c000
        ld      de,#c001
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      a,5                     ; color 5 -> packed byte #55
        ld      b,10                    ; x_byte
        ld      c,100                   ; y (irrelevant in the flat model)
        ld      d,8                     ; w_bytes
        ld      e,50                    ; h (irrelevant: burst size only)
        ld      hl,#c000                ; dest_base
        call    gfx_fill_rect

        ld      hl,#c00a                ; #c000+10: first filled byte
        ld      b,8
.frcheck:
        ld      a,(hl)
        cp      #55
        ld      a,1
        call    t_expect_z
        inc     hl
        djnz    .frcheck

        ld      a,(#c009)               ; byte just before the span
        cp      #a5
        ld      a,2
        call    t_expect_z
        ld      a,(#c012)               ; byte just after the span (#c00a+8)
        cp      #a5
        ld      a,3
        call    t_expect_z

        ; --- gfx_hline, short case (w <= 160): one accelerator chunk, one
        ; observable byte at the row start.
        ld      hl,#c100
        ld      de,#c101
        ld      bc,#00ff
        ld      (hl),#a5
        ldir

        ld      a,3                     ; color 3 -> packed byte #33
        ld      b,5                     ; x_byte
        ld      c,50                    ; y
        ld      d,50                    ; w_bytes (short: single chunk)
        ld      hl,#c100                ; dest_base
        call    gfx_hline

        ld      a,(#c105)               ; #c100+5: the chunk's trigger byte
        cp      #33
        ld      a,4
        call    t_expect_z
        ld      a,(#c104)
        cp      #a5
        ld      a,5
        call    t_expect_z
        ld      a,(#c106)
        cp      #a5
        ld      a,6
        call    t_expect_z

        ; --- gfx_hline, wide case (w > 160): split into a 160-byte chunk
        ; plus the remainder -- two observable trigger bytes, at the row
        ; start and at +160.
        ld      hl,#c140
        ld      de,#c141
        ld      bc,#00cf
        ld      (hl),#a5
        ldir

        ld      a,7                     ; color 7 -> packed byte #77
        ld      b,0                     ; x_byte
        ld      c,20                    ; y
        ld      d,200                   ; w_bytes (wide: 160 + 40)
        ld      hl,#c140                ; dest_base
        call    gfx_hline

        ld      a,(#c140)               ; first chunk's trigger byte
        cp      #77
        ld      a,7
        call    t_expect_z
        ld      a,(#c1e0)               ; #c140+160: second chunk's trigger byte
        cp      #77
        ld      a,8
        call    t_expect_z
        ld      a,(#c141)               ; untouched in the flat model
        cp      #a5
        ld      a,9
        call    t_expect_z

        ; --- gfx_clear_buffer: a real CPU djnz over 320 columns (no
        ; accelerator burst involved in the loop itself), so this proves
        ; end-to-end: every one of the 320 bytes gets the fill byte, and
        ; nothing past byte 320 is touched.
        ld      hl,#c200
        ld      de,#c201
        ld      bc,#0140
        ld      (hl),#a5
        ldir

        ld      a,9                     ; color 9 -> packed byte #99
        ld      hl,#c200
        call    gfx_clear_buffer

        ld      hl,#c200
        ld      b,0                     ; 256 iterations
.clr1:  ld      a,(hl)
        cp      #99
        ld      a,10
        call    t_expect_z
        inc     hl
        djnz    .clr1
        ld      b,64                    ; remaining 320-256 = 64 columns
.clr2:  ld      a,(hl)
        cp      #99
        ld      a,11
        call    t_expect_z
        inc     hl
        djnz    .clr2
        ld      a,(hl)                  ; byte 320: past the buffer
        cp      #a5
        ld      a,12
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

        include "gfx_core.asm"
        ; S5-finish plan D11 (buffer flip): gfx_fill_rect/gfx_hline/
        ; gfx_clear_buffer now call flip_log_rect/flip_mark_dirty_all
        ; (buffers.asm) after every paint -- needed to assemble standalone.
        ; text640.asm is buffers.asm's own dependency (bench_init's
        ; text_font_page), not this test's.
        include "text640.asm"
        include "buffers.asm"
