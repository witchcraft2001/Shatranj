SECTION code_user

EXTERN _sprinter_net_preflight_ovl
EXTERN _sprinter_unet_mqtt_start_core
EXTERN _sprinter_unet_mqtt_activate_core
EXTERN _sprinter_unet_mqtt_probe_core

    DEFB 4
    DEFW sprinter_mqtt_start_entry
    DEFW sprinter_mqtt_activate_entry
    DEFW _sprinter_net_preflight_ovl
    DEFW sprinter_mqtt_probe_entry

sprinter_mqtt_start_entry:
    JP _sprinter_unet_mqtt_start_core
sprinter_mqtt_activate_entry:
    JP _sprinter_unet_mqtt_activate_core
sprinter_mqtt_probe_entry:
    JP _sprinter_unet_mqtt_probe_core
