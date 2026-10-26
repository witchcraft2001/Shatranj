; NET entry table. Entries 0..4 retain their existing numbers.
; Sprinter-only entries 5..10 own HOST waiting, preparation, HELLO/START,
; cleanup, NETWORK application setup and handshake retries.
; Keep this object first in the link: the dispatcher reads byte zero.

SECTION code_user

EXTERN _net_mqtt_connect_start_ovl
EXTERN _net_mqtt_activate_side_ovl
EXTERN _net_preflight_ovl
EXTERN _net_mqtt_probe_seat_ovl
EXTERN _net_join_ui_ovl

EXTERN _net_host_wait_ovl, _net_prepare_ovl, _net_hello_ovl, _net_host_close_ovl

EXTERN _net_network_ovl

EXTERN _net_hello_tick_ovl

    DEFB 11
    DW _net_mqtt_connect_start_ovl_entry   ; SPECTRUM_OVL_MQTT_CONNECT_START = 0
    DW _net_mqtt_activate_side_ovl_entry   ; SPECTRUM_OVL_MQTT_CONNECT_ACTIVATE = 1
    DW _net_preflight_ovl_entry            ; SPECTRUM_OVL_NET_PREFLIGHT = 2
    DW _net_mqtt_probe_seat_ovl_entry      ; SPECTRUM_OVL_MQTT_CONNECT_PROBE_SEAT = 3
    DW _net_join_ui_ovl_entry              ; SPECTRUM_OVL_NET_CONNECT_SCREEN = 4
    DW _net_host_wait_ovl
    DW _net_prepare_ovl
    DW _net_hello_ovl
    DW _net_host_close_ovl
    DW _net_network_ovl
    DW _net_hello_tick_ovl

DEFC _net_mqtt_connect_start_ovl_entry = _net_mqtt_connect_start_ovl
DEFC _net_mqtt_activate_side_ovl_entry = _net_mqtt_activate_side_ovl
DEFC _net_preflight_ovl_entry = _net_preflight_ovl
DEFC _net_mqtt_probe_seat_ovl_entry = _net_mqtt_probe_seat_ovl
DEFC _net_join_ui_ovl_entry = _net_join_ui_ovl
