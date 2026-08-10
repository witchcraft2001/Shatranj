; ovl_s3.asm -- S3's overlay-mechanism probe (port.md section 3.10/S3, the
; last mechanic in §5's table). WIN1-half dispatch code (this file's
; eventual home per port.md's own S5 task text); the context buffer
; (ovl_ctx, resident_s1.asm) lives in WIN2 instead, alongside net_gate.
; asm/echo_s3.asm's own state -- keeping every piece of S3 cross-mechanism
; state in one half simplifies both reasoning and the section gate, even
; though the overlay slot itself (a fixed sub-region of this file's own
; WIN1 physical page, not a separately DSS-allocated page swapped in via a
; port like libman's DLL) never actually displaces WIN1 the way l_load
; does.
;
; Byte-for-byte ABI match with the ZX loader (asm/esxdos/overlay_loader.
; asm:54-60): packed args at SP+2 (ovl_id -- reserved, this probe drives
; exactly one overlay) / SP+3 (entry_id), context pointer in BOTH DE and
; HL (native ASM entries read DE; a future C fastcall entry would read
; HL), DI on entry, ovl_return: ei/ret.
;
; ovl_exec always re-copies the 2 KiB overlay from the asset page (slot
; 36, offset #2400) into OVL_SLOT via win0_map_di/LDIR/win0_restore (R1).
; ovl_exec_cached skips the copy if ovl_v_loaded_id already matches the
; requested id -- tests/sprinter/z80/t_ovl_dispatch.asm mutates the source
; between two dispatches and relies on exactly this asymmetry: ovl_exec
; must observe the mutation, ovl_exec_cached must not.

        IFNDEF SPRINTER_OVL_S3_INC
        DEFINE SPRINTER_OVL_S3_INC

        INCLUDE "dss.inc"
        INCLUDE "win0.inc"
        INCLUDE "fixed_layout.inc"
        INCLUDE "render_layout.inc"

OVL_DUMMY_ID    EQU 0
OVL_ASSET_SLOT  EQU 36
OVL_SOURCE_OFFSET EQU OVL_ASSET_SLOT*256       ; #2400

OVL_ERR_BAD_ENTRY EQU #FF

OVL_STATUS_X EQU PANEL_X
OVL_STATUS_Y EQU STATUS_Y+16

; SP+2=ovl_id (reserved), SP+3=entry_id. Unconditionally invalidates the
; cache marker first, so the shared logic below always re-copies.
ovl_exec:
        ld      a,#FF                   ; not a valid id -- forces a copy
        ld      (ovl_v_loaded_id),a

; SP+2=ovl_id, SP+3=entry_id. Copies only if ovl_v_loaded_id != ovl_id.
; Out (bad entry_id only): A=OVL_ERR_BAD_ENTRY, CF=1, ovl_ctx untouched,
; dispatch never happens. Otherwise runs the entry (DI on entry, EI on
; return via ovl_return) and returns whatever it left in the registers,
; CF=0.
ovl_exec_cached:
        ld      hl,2
        add     hl,sp
        ld      a,(hl)
        ld      (ovl_v_requested_id),a
        inc     hl
        ld      a,(hl)
        ld      (ovl_v_requested_entry),a

        ld      hl,ovl_v_loaded_id
        ld      a,(ovl_v_requested_id)
        cp      (hl)
        jr      z,.dispatch             ; already resident: skip the copy

        ld      a,(bench_asset_page)
        cp      #FF
        jr      z,ovl_dispatch_fail

        win0_map_di
        ld      hl,OVL_SOURCE_OFFSET
        ld      de,OVL_SLOT_ADDR
        ld      bc,OVL_SLOT_SIZE
        ldir
        win0_restore

        ld      a,(ovl_v_requested_id)
        ld      (ovl_v_loaded_id),a

.dispatch:
        ld      a,(ovl_v_requested_entry)
        ld      hl,OVL_SLOT_ADDR        ; entry count byte
        cp      (hl)
        jr      nc,ovl_dispatch_fail    ; entry_id >= count

        add     a,a                     ; *2: word-sized table entries
        ld      e,a
        ld      d,0
        ld      hl,OVL_SLOT_ADDR+1
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)                  ; de = entry target address

        ld      bc,ovl_return
        push    bc
        push    de                      ; entry target, to be RET'd into
        ld      de,ovl_ctx
        ld      hl,ovl_ctx
        di
        ret

ovl_return:
        ei
        ret

ovl_dispatch_fail:
        ld      a,OVL_ERR_BAD_ENTRY
        scf
        ret

; ---------------------------------------------------------------------------
; Hotkey 'O': drives the dummy overlay's entry 0 (self-check) then entry 1
; (checksum), and draws the checksum (or #FFFF on any failure) at
; (OVL_STATUS_X, OVL_STATUS_Y) -- one row below net_gate.asm's own NET
; status line. Own DI/WIN3 bracket and glyph_dest_base save/restore
; (net_gate.asm's net_up_probe pattern).
; ---------------------------------------------------------------------------

ovl_probe:
        ld      hl,ovl_ctx
        ld      (hl),7
        inc     hl
        ld      (hl),3

        ld      l,OVL_DUMMY_ID
        ld      h,0                     ; entry 0
        push    hl
        call    ovl_exec_cached
        pop     hl
        jr      c,.fail

        ld      l,OVL_DUMMY_ID
        ld      h,1                     ; entry 1
        push    hl
        call    ovl_exec_cached
        pop     hl
        jr      c,.fail

        ld      de,(ovl_ctx+6)
        jp      ovl_draw_status

.fail:
        ld      de,#FFFF
        jp      ovl_draw_status

; DE=value to show as hex16. Clobbers AF, BC, DE, HL, IX.
ovl_draw_status:
        push    de
        call    resolve_buffers
        ld      hl,(front_base)
        ld      (glyph_dest_base),hl
        di
        in      a,(WIN3_PORT)
        ld      (.saved_win3),a
        ld      a,VRAM_ALIAS_OPAQUE
        out     (WIN3_PORT),a
        ld      ix,OVL_STATUS_X
        ld      c,OVL_STATUS_Y
        pop     de
        call    draw_hex16
        ld      a,#C0
        out     (PORT_Y),a
        ld      a,(.saved_win3)
        out     (WIN3_PORT),a
        ei
        jp      restore_glyph_base
.saved_win3: DB 0

; ---------------------------------------------------------------------------
; State (WIN1-half: the overlay mechanism never displaces WIN1 the way
; libman's DLL load does, so this cache bookkeeping does not need WIN2).
; ---------------------------------------------------------------------------
ovl_v_loaded_id:      DB #FF
ovl_v_requested_id:   DB 0
ovl_v_requested_entry: DB 0

        ENDIF
