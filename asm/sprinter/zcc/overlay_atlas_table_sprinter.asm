; Overlay atlas, consumed by overlay_loader_sprinter.asm's ovl_exec_cached.
;
; Dense from 0 (SPECTRUM_OVL_RULES) through 14 (SPECTRUM_OVL_CONTROL,
; src/spectrum/overlay/overlay.h) -- both tables are indexed directly by id,
; so representing "only some ids are real" needs every lower slot filled,
; not skipped.
;
; TWO DISPATCH MODES (plan D2 vs D7-bis), selected per id by
; ovl_atlas_mode_table below. This is the whole reason there are two tables:
;
;   mode 0 -- COPY. ovl_atlas_table[id] is a WIN0-relative source offset
;     (slot*256) inside the main assets page; the loader LDIRs
;     OVL_SLOT_SIZE bytes from there into OVL_SLOT_ADDR and dispatches out
;     of the slot. This is S5 substep 2's original mechanism (plan D2),
;     MAME-proven for CONTROL (id 14), and unchanged here.
;
;   mode 1 -- MAP (plan D7-bis). ovl_atlas_table[id] is an ABSOLUTE address
;     inside the WIN3 window (#C000-#FFFF) where that overlay's entry table
;     was linked; the loader maps ovl_win3_page into WIN3 with a single OUT
;     and dispatches in place, no copy at all. Adopted for RULES/BOARD
;     because the 2 KiB copy slot cannot hold a compiled C overlay of real
;     size: BOARD links to 2772 bytes (measured, S5 substep 3b), and the
;     three remaining D7 overlays (GUI_LOG/STATUS/INPUT_EDIT) are C too.
;     Mode 1 raises the per-overlay ceiling from 2 KiB to 4 KiB (four
;     overlays per WIN3 page) and drops the copy cost (~4 ms of LDIR per
;     switch, D7-ter) to one OUT.
;
; Mode 1 is safe for exactly the overlays that never touch WIN3 themselves,
; which is what RULES/BOARD are: pure computation over resident WIN1/WIN2
; memory (the board buffers at LOWRAM_CHESS_BOARD/LOWRAM_RULES_BOARD, the
; overlay context, board.c's own globals) with no text_print/gfx_*/DSS/
; libman call and no string literals of their own. The two hazards plan
; D7-bis calls out -- overlay-owned string pointers handed to text640.asm
; (whose contract already forbids WIN0/WIN3 sources) and DSS/uNet taking
; WIN3 for themselves -- simply do not arise for these two. An overlay that
; DOES need either must stay mode 0 until those are solved.
;
; WIN3 window layout for mode-1 overlays (S6 plan step 2,
; tools/make_sprinter_overlay_page.py packs the page image to match --
; variable-size slots now, not a uniform 4 KiB one; that tool's own LAYOUT
; table is the source of truth, these EQUs mirror it and
; test_sprinter_overlay_page.py's test_atlas_table_agrees_with_this_packing
; pins the two together):
;     #C000  RULES     (id 0)   2048 bytes -- linked size 1628 bytes
;     #C800  BOARD     (id 1)   3072 bytes -- linked size 2772 bytes
;     #D400  SAVELOAD  (id 10)  2560 bytes -- S6, not yet linked (zero)
;     #DE00  RESTORE   (id 11)  3072 bytes -- S6, not yet linked (zero)
;     #EA00  FILEUI    (id 13)  5120 bytes -- S6, not yet linked (zero)
;     #FE00  reserved           512 bytes
; GUI_LOG (id 2) and STATUS (id 7) stay mode 0 (unported, no WIN3 slot of
; their own -- both resolved a different way, see this table's own id
; comments below).
;
; S8 step 8b: NET (id 3) is the first overlay on a SECOND WIN3 page
; (tools/make_sprinter_overlay_page.py's LAYOUT2), because page 1's own
; 3929 bytes of slack are fragmented across five slots and carving NET's
; ~2816 bytes out of it would zero every remaining margin (measured
; 2026-08-14 recon). This is the point the loader's own header called out:
; ovl_win3_page stops being the single global every mode-1 id reads and
; becomes ovl_atlas_page_table below -- one cell ADDRESS per id, so ids on
; page 1 keep reading ovl_win3_page and NET/INPUT_EDIT read ovl_win3_page2
; instead, with no change to any other id's behaviour.
;
; S9 chat pass: INPUT_EDIT (id 9) lands on the same page 2, in what used to
; be RESERVE2's own slot (tools/make_sprinter_overlay_page.py's LAYOUT2) --
; the only unfragmented room left, see that tool's own header.
;     #C000  NET         (id 3, page 2)   8192 bytes
;     #E000  INPUT_EDIT  (id 9, page 2)   4096 bytes
;     #F000  reserved    (page 2)         4096 bytes
;
; Id 14 (CONTROL) stays mode 0: src/spectrum/overlay/control_ovl.c, embedded
; at assets-page slot 36 (tools/make_sprinter_assets_page.py's OVERLAY_SLOT),
; 1082 bytes, comfortably inside the 2 KiB slot and already confirmed
; end-to-end in MAME -- no reason to move it onto a mechanism whose first
; hardware run is this pass.
;
; Ids with no real content yet are mode 0 pointing at assets-page slot 0
; (the font, never an overlay's own bytes): harmless placeholder content
; since nothing dispatches those ids, and unambiguously not a real overlay
; if anyone reads this table.

ovl_atlas_count EQU 15

OVL_MODE_COPY EQU 0
OVL_MODE_WIN3 EQU 1

; Per-overlay WIN3 link addresses (S6 plan step 2): must match
; tools/make_sprinter_overlay_page.py's LAYOUT table and the -r link
; addresses in the Makefile's overlay-bin rules -- that tool's own
; --print-org NAME is what those rules actually read, these EQUs are the
; asm-side mirror test_atlas_table_agrees_with_this_packing pins against.
OVL_WIN3_RULES_ORG    EQU 0xC000
OVL_WIN3_BOARD_ORG    EQU 0xC800
OVL_WIN3_SAVELOAD_ORG EQU 0xD400
OVL_WIN3_RESTORE_ORG  EQU 0xDE00
OVL_WIN3_FILEUI_ORG   EQU 0xEA00
OVL_WIN3_NET_ORG      EQU 0xC000  ; page 2's own first slot, restarts at WIN3_BASE
OVL_WIN3_INPUT_EDIT_ORG EQU 0xE000 ; page 2's second slot (S9 chat pass)
OVL_WIN3_ABOUT_ORG    EQU 0xF000 ; page 2's third slot (S9 About pass)

ovl_atlas_table:
    defw OVL_WIN3_RULES_ORG       ; id 0  (RULES)
    defw OVL_WIN3_BOARD_ORG       ; id 1  (BOARD)
    defw 0x0000   ; id 2  (GUI_LOG)     -- not ported (native resident C)
    defw OVL_WIN3_NET_ORG         ; id 3  (NET_CONNECT) -- S8 step 8b, page 2
    defw 0x0000   ; id 4  (MQTT_TX)     -- S7/S8 scope
    defw 0x0000   ; id 5  (DIRECT)      -- S7/S8 scope
    defw 0x0000   ; id 6  (MENU_CONFIG) -- S9 scope
    defw 0x0000   ; id 7  (STATUS)      -- not ported (native resident C)
    defw 0x0000   ; id 8  (SETUP)       -- S9 scope
    defw OVL_WIN3_INPUT_EDIT_ORG  ; id 9  (INPUT_EDIT)  -- S9 chat pass, page 2
    defw OVL_WIN3_SAVELOAD_ORG    ; id 10 (SAVELOAD)    -- S6, not yet linked
    defw OVL_WIN3_RESTORE_ORG     ; id 11 (RESTORE)     -- S6, not yet linked
    defw OVL_WIN3_ABOUT_ORG       ; id 12 (ABOUT)       -- S9 About pass, page 2
    defw OVL_WIN3_FILEUI_ORG      ; id 13 (FILEUI)      -- S6, not yet linked
    defw 0x2400   ; id 14 (CONTROL)     -- real, assets-page slot 36 (36*256)

; Dispatch mode, one byte per id, same indexing as ovl_atlas_table but not
; doubled (indexed by id, not id*2). SAVELOAD/RESTORE/FILEUI are already
; mode 1 here (S6 plan step 2) even though their slots are still zero-filled
; placeholders until step 3/4 links real content into them -- consistent
; with mode 1 requiring no copy step regardless of what is mapped in, and
; nothing dispatches ids 10/11/13 yet.
ovl_atlas_mode_table:
    defb OVL_MODE_WIN3   ; id 0  (RULES)
    defb OVL_MODE_WIN3   ; id 1  (BOARD)
    defb OVL_MODE_COPY   ; id 2  (GUI_LOG)     -- placeholder
    defb OVL_MODE_WIN3   ; id 3  (NET_CONNECT) -- S8 step 8b, page 2
    defb OVL_MODE_COPY   ; id 4  (MQTT_TX)     -- placeholder
    defb OVL_MODE_COPY   ; id 5  (DIRECT)      -- placeholder
    defb OVL_MODE_COPY   ; id 6  (MENU_CONFIG) -- placeholder
    defb OVL_MODE_COPY   ; id 7  (STATUS)      -- placeholder
    defb OVL_MODE_COPY   ; id 8  (SETUP)       -- placeholder
    defb OVL_MODE_WIN3   ; id 9  (INPUT_EDIT)  -- S9 chat pass, page 2
    defb OVL_MODE_WIN3   ; id 10 (SAVELOAD)    -- S6, slot not yet linked
    defb OVL_MODE_WIN3   ; id 11 (RESTORE)     -- S6, slot not yet linked
    defb OVL_MODE_WIN3   ; id 12 (ABOUT)       -- S9 About pass, page 2
    defb OVL_MODE_WIN3   ; id 13 (FILEUI)      -- S6, slot not yet linked
    defb OVL_MODE_COPY   ; id 14 (CONTROL)     -- real, unchanged

; Per-id WIN3 PAGE CELL address (S8 step 8b): which byte the loader's
; ovl_map_win3 reads the physical page number from, one word per id, same
; dense indexing as the two tables above. Every mode-1 id on page 1 points
; at ovl_win3_page (unchanged behaviour); NET (id 3) is the first id to
; point at ovl_win3_page2 instead. Mode-0 ids are never read through this
; table (ovl_map_win3 is only reached when ovl_atlas_mode_table says WIN3),
; so their entries are harmless filler, not a real page cell reference.
ovl_atlas_page_table:
    defw ovl_win3_page    ; id 0  (RULES)
    defw ovl_win3_page    ; id 1  (BOARD)
    defw ovl_win3_page    ; id 2  (GUI_LOG)     -- unused (mode 0)
    defw ovl_win3_page2   ; id 3  (NET_CONNECT) -- page 2
    defw ovl_win3_page    ; id 4  (MQTT_TX)     -- unused (mode 0)
    defw ovl_win3_page    ; id 5  (DIRECT)      -- unused (mode 0)
    defw ovl_win3_page    ; id 6  (MENU_CONFIG) -- unused (mode 0)
    defw ovl_win3_page    ; id 7  (STATUS)      -- unused (mode 0)
    defw ovl_win3_page    ; id 8  (SETUP)       -- unused (mode 0)
    defw ovl_win3_page2   ; id 9  (INPUT_EDIT)  -- page 2 (S9 chat pass)
    defw ovl_win3_page    ; id 10 (SAVELOAD)
    defw ovl_win3_page    ; id 11 (RESTORE)
    defw ovl_win3_page2   ; id 12 (ABOUT)       -- page 2 (S9 About pass)
    defw ovl_win3_page    ; id 13 (FILEUI)
    defw ovl_win3_page    ; id 14 (CONTROL)     -- unused (mode 0)
