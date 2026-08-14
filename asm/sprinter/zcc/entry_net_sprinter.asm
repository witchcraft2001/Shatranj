; Overlay entry table for NET (SPECTRUM_OVL_NET_CONNECT = 3u, S8 step 8b),
; page 2 of the WIN3 overlay window (tools/make_sprinter_overlay_page.py's
; LAYOUT2). Five entries: the same four ZX/Next reserve for this id
; (overlay.h -- MQTT_CONNECT_START=0/ACTIVATE=1/NET_PREFLIGHT=2/
; MQTT_CONNECT_PROBE_SEAT=3, src/sprinter/net_mqtt_ui_sprinter.c, still
; skeleton bodies until S8 steps 8c/8d), plus a Sprinter-only fifth entry
; (SPECTRUM_OVL_NET_CONNECT_SCREEN=4u) for the DIRECT-join/config screen
; moved here from the WIN3 cold page (src/sprinter/net_ui_sprinter.c).
;
; All five are plain (void) C functions (no ctx read), same shape as
; entry_restore_sprinter.asm/entry_fileui_sprinter.asm and ZX's own
; entry_mqtt_connect.asm -- pure DEFC aliasing, no hand-written asm needed.

SECTION code_user

EXTERN _net_mqtt_connect_start_ovl
EXTERN _net_mqtt_activate_side_ovl
EXTERN _net_preflight_ovl
EXTERN _net_mqtt_probe_seat_ovl
EXTERN _net_join_ui_ovl

    DEFB 5
    DW _net_mqtt_connect_start_ovl_entry   ; SPECTRUM_OVL_MQTT_CONNECT_START = 0
    DW _net_mqtt_activate_side_ovl_entry   ; SPECTRUM_OVL_MQTT_CONNECT_ACTIVATE = 1
    DW _net_preflight_ovl_entry            ; SPECTRUM_OVL_NET_PREFLIGHT = 2
    DW _net_mqtt_probe_seat_ovl_entry      ; SPECTRUM_OVL_MQTT_CONNECT_PROBE_SEAT = 3
    DW _net_join_ui_ovl_entry              ; SPECTRUM_OVL_NET_CONNECT_SCREEN = 4

DEFC _net_mqtt_connect_start_ovl_entry = _net_mqtt_connect_start_ovl
DEFC _net_mqtt_activate_side_ovl_entry = _net_mqtt_activate_side_ovl
DEFC _net_preflight_ovl_entry = _net_preflight_ovl
DEFC _net_mqtt_probe_seat_ovl_entry = _net_mqtt_probe_seat_ovl
DEFC _net_join_ui_ovl_entry = _net_join_ui_ovl
