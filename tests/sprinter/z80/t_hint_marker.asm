; z80 unit test for the S9 dot-highlight bit-table convention shared by
; three independent asm sites: render_core.asm's render_hint_marker/
; render_hint_markers_all (asm/sprinter/zcc/render_core.asm) and
; rules_stub_sprinter.asm's own bit-setting inside _rules_hints_show_ovl
; (asm/sprinter/zcc/rules_stub_sprinter.asm). All three must agree that
; netchesszx_hinted_rows is MSB=col0 (bit 7 = file 'a', bit 0 = file 'h')
; and that a square index splits as row=idx>>3, col=idx&7 -- a mismatch
; between any two sites (e.g. one using LSB=col0) would silently paint
; hint dots on the wrong squares, or never light up the actual legal
; targets, with no build-time signal.
;
; This is NOT an integration test of render_core.asm itself: that file
; pulls in ~50 EXTERN symbols from the cold-page build (gfx_core.asm,
; text640.asm, buffers.asm, the generated cold_defs.asm/platform_defs.asm
; bridges, and fixed low-RAM addresses only meaningful inside the real
; WIN3 cold-page image) that this standalone harness has no way to
; provide -- see render_hint_marker's own header for why hints_show's
; MAME checklist, not a z80 unit test, is this feature's real judge.
; What CAN be closed here, and is: the bit-table/row-col-split ALGORITHM
; itself, copied verbatim from render_core.asm's own render_hint_marker
; (bit-table lookup) and render_hint_markers_all (rlca-based scan), and
; separately from rules_stub_sprinter.asm's own bit-setting shift. If a
; future edit to any of the three real sites drifts from this convention,
; this test does not catch THAT drift automatically (it is a copy, not an
; include) -- but it does pin the convention itself in one place a human
; can diff the real sites against, and it does prove the convention is
; internally consistent (the write side and the read side agree).

        device noslot64k
        org 0
        jp start
        include "harness.inc"

; --- copy of render_core.asm's BIT_TABLE8 (render_hint_marker) ------------
BIT_TABLE8:
        DB #80,#40,#20,#10,#08,#04,#02,#01

; L = square index (0-63) -- __z88dk_fastcall convention, same as the real
; render_hint_marker. Returns A=1 if the bit is set, A=0 otherwise, via
; the SAME table-lookup shape the real routine uses (col lookup, then row
; byte AND). Clobbers BC/DE/HL.
check_hint_bit:
        ld      a,l
        and     #3f
        ld      c,a
        and     7
        ld      (row_col_scratch+1),a    ; @col
        ld      a,c
        srl     a
        srl     a
        srl     a
        ld      (row_col_scratch),a      ; @row

        ld      c,a
        ld      b,0
        ld      hl,hinted_rows_fixture
        add     hl,bc
        ld      a,(hl)
        ld      c,a

        ld      hl,BIT_TABLE8
        ld      a,(row_col_scratch+1)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,c
        and     (hl)
        ret     z
        ld      a,1
        ret

row_col_scratch: DB 0,0

; --- copy of _rules_hints_show_ovl's own bit-set shift (rules_stub_
; sprinter.asm) -- MUST agree with BIT_TABLE8 above: both write/read the
; same netchesszx_hinted_rows convention, just via different code shapes
; (a table lookup here, an inline shift there in the real file). E=to
; (0-63). Sets the matching bit in hinted_rows_fixture. Clobbers AF/BC/DE/HL.
set_hint_bit_via_shift:
        ld      a,e
        srl     a
        srl     a
        srl     a                        ; A = row
        ld      c,a
        ld      b,0
        ld      hl,hinted_rows_fixture
        add     hl,bc

        ld      a,e
        and     7                        ; A = col (0-7)
        ld      b,a
        ld      a,#80
        or      a
        jr      z,.have_bit
.shift:
        or      a
        jr      z,.have_bit
        rrca
        djnz    .shift
.have_bit:
        or      (hl)
        ld      (hl),a
        ret

start:
        ld      sp,#e800
        call    t_begin

        ; --- Case 1: a1 (model index 0, row 0 col 0) is the MSB of row 0.
        ld      hl,hinted_rows_fixture
        ld      b,8
.clear1:
        ld      (hl),0
        inc     hl
        djnz    .clear1
        ld      a,#80                    ; row 0, col 0 set directly
        ld      (hinted_rows_fixture),a

        ld      l,0                      ; square index 0 (a8/model a1)
        call    check_hint_bit
        ld      b,a
        ld      a,1
        cp      b
        ld      a,1
        call    t_expect_z

        ; index 1 (col 1) must NOT read back set (proves col, not just
        ; "row 0 has any bit", is checked).
        ld      l,1
        call    check_hint_bit
        or      a
        ld      a,2
        call    t_expect_z

        ; --- Case 2: h1 (model index 7, row 0 col 7) is the LSB of row 0.
        ld      hl,hinted_rows_fixture
        ld      b,8
.clear2:
        ld      (hl),0
        inc     hl
        djnz    .clear2
        ld      a,#01                    ; row 0, col 7 set directly
        ld      (hinted_rows_fixture),a

        ld      l,7
        call    check_hint_bit
        ld      b,a
        ld      a,1
        cp      b
        ld      a,3
        call    t_expect_z

        ld      l,6                      ; col 6 must stay clear
        call    check_hint_bit
        or      a
        ld      a,4
        call    t_expect_z

        ; --- Case 3: row split. index 15 = row 1, col 7 (h2). Setting row
        ; 1's LSB must not disturb row 0.
        ld      hl,hinted_rows_fixture
        ld      b,8
.clear3:
        ld      (hl),0
        inc     hl
        djnz    .clear3
        ld      a,#01
        ld      (hinted_rows_fixture+1),a

        ld      l,15
        call    check_hint_bit
        ld      b,a
        ld      a,1
        cp      b
        ld      a,5
        call    t_expect_z

        ld      l,7                      ; row 0 col 7 (different row) unset
        call    check_hint_bit
        or      a
        ld      a,6
        call    t_expect_z

        ; --- Case 4: the write side (rules_stub_sprinter.asm's own inline
        ; shift) and the read side (render_core.asm's own table lookup)
        ; agree -- set every one of the 64 squares one at a time via the
        ; shift routine, immediately confirm the table-lookup routine
        ; reads back exactly that one bit, nothing else in either byte.
        ; agree_target (memory, not a register) is the outer loop counter
        ; throughout -- both check_hint_bit and set_hint_bit_via_shift
        ; clobber D/E internally, so a register-held outer counter would
        ; not survive either call.
        xor     a
        ld      (agree_target),a
.agree_loop:
        ld      hl,hinted_rows_fixture
        ld      b,8
.agree_clear:
        ld      (hl),0
        inc     hl
        djnz    .agree_clear

        ld      a,(agree_target)
        ld      e,a
        call    set_hint_bit_via_shift

        ld      a,(agree_target)
        ld      l,a
        call    check_hint_bit
        ld      b,a
        ld      a,1
        cp      b
        ld      a,7
        call    t_expect_z

        ; every OTHER square must read back clear (only the one bit set)
        ld      c,0
.agree_others:
        ld      a,c
        ld      b,a
        ld      a,(agree_target)
        cp      b
        jr      z,.agree_skip
        ld      a,c
        ld      l,a
        push    bc
        call    check_hint_bit
        or      a
        ld      a,8
        call    t_expect_z
        pop     bc
.agree_skip:
        inc     c
        ld      a,c
        cp      64
        jr      nz,.agree_others

        ld      a,(agree_target)
        inc     a
        ld      (agree_target),a
        cp      64
        jr      nz,.agree_loop

        ; --- Case 5: the ROW-SCAN address arithmetic of render_hint_
        ; markers_all. Copied from that routine the same way the other
        ; cases copy their originals. The first version zeroed D and then
        ; did "add hl,bc" while B still held the row counter, so it read
        ; the mask from base + row*256 + row instead of base + row: row 0
        ; looked fine and every other row read unrelated memory, which is
        ; what put a garbage block on the board in MAME. Nothing above
        ; catches it -- those cases all index the fixture directly, never
        ; through the scan's own pointer walk. Here each of the 8 rows is
        ; given a distinct mask and the scan must read back exactly that
        ; byte; with the old arithmetic rows 1-7 read from far outside the
        ; fixture, which the surrounding guard pages make non-matching.
        ld      hl,hinted_rows_fixture
        ld      b,8
        ld      c,1
.seed5:
        ld      (hl),c
        inc     hl
        inc     c
        djnz    .seed5

        ld      b,0
.scan5:
        push    bc
        call    scan_row_byte            ; A = mask byte the scan reads
        pop     bc
        ld      c,a
        ld      a,b
        inc     a                        ; expected: row+1 (the seed above)
        cp      c
        ld      a,9
        call    t_expect_z
        inc     b
        ld      a,b
        cp      8
        jr      nz,.scan5

        call    t_end
        halt

        assert  $ < TEST_RESULT

; --- copy of render_hint_markers_all's row-pointer walk (render_core.asm).
; B = row (0-7). Returns A = that row's mask byte. Clobbers BC/DE/HL.
scan_row_byte:
        ld      c,b
        ld      b,0
        ld      hl,hinted_rows_fixture
        add     hl,bc
        ld      b,c
        ld      a,(hl)
        ret

agree_target: DB 0
; Guard pages either side: the scan must never step outside the 8 real
; bytes. Filled with a value no seeded row uses (the seeds are 1..8), so a
; stray read lands on #EE and fails Case 5 loudly instead of coincidentally
; matching.
                 DS 64,#EE
hinted_rows_fixture: DS 8,0
                 DS 64,#EE
