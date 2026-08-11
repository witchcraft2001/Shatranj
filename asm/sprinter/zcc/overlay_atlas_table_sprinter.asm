; Overlay atlas: id -> source offset within the asset page (WIN0-relative,
; i.e. slot*256), consumed by overlay_loader_sprinter.asm's ovl_exec_cached.
;
; Dense from 0 (SPECTRUM_OVL_RULES) through 14 (SPECTRUM_OVL_CONTROL,
; src/spectrum/overlay/overlay.h) -- ovl_atlas_table is indexed directly by
; id*2, so representing "only id 14 is real" needs every lower slot filled,
; not skipped. Ids 0-13 point at asset-page slot 0 (the font, never an
; overlay's own bytes): harmless placeholder content since nothing calls
; those ids yet (main.c only ever dispatches id 14), and unambiguously not
; a real overlay if anyone reads this table before porting one -- swap an
; id's entry from 0x0000 to its own slot the same day its real content
; lands in the assets page, no other change needed here or in
; overlay_loader_sprinter.asm.
;
; Id 14 (CONTROL) is real: src/spectrum/overlay/control_ovl.c, compiled and
; linked by the Makefile's $(SPRINTER_OVL_CONTROL_BIN) rule, embedded at
; asset-page slot 36 (tools/make_sprinter_assets_page.py's OVERLAY_SLOT) --
; the same slot the S3-successor proof payload (overlay_probe_sprinter.asm)
; held before CONTROL superseded it (port.md, S5 substep 2).

ovl_atlas_count EQU 15

ovl_atlas_table:
    defw 0x0000   ; id 0  (RULES)       -- not yet ported (needs render_core)
    defw 0x0000   ; id 1  (BOARD)       -- not yet ported (needs render_core)
    defw 0x0000   ; id 2  (GUI_LOG)     -- not yet ported (needs render_core)
    defw 0x0000   ; id 3  (NET_CONNECT) -- S7/S8 scope
    defw 0x0000   ; id 4  (MQTT_TX)     -- S7/S8 scope
    defw 0x0000   ; id 5  (DIRECT)      -- S7/S8 scope
    defw 0x0000   ; id 6  (MENU_CONFIG) -- S9 scope
    defw 0x0000   ; id 7  (STATUS)      -- not yet ported (needs render_core)
    defw 0x0000   ; id 8  (SETUP)       -- S9 scope
    defw 0x0000   ; id 9  (INPUT_EDIT)  -- not yet ported (needs render_core)
    defw 0x0000   ; id 10 (SAVELOAD)    -- S6 scope
    defw 0x0000   ; id 11 (RESTORE)     -- S6 scope
    defw 0x0000   ; id 12 (ABOUT)       -- S9 scope
    defw 0x0000   ; id 13 (FILEUI)      -- S6 scope
    defw 0x2400   ; id 14 (CONTROL)     -- real, asset-page slot 36 (36*256)
