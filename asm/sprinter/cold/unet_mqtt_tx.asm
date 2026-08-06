SECTION code_user

EXTERN _sprinter_mqtt_send_ovl
EXTERN _sprinter_mqtt_setup_ovl
EXTERN _sprinter_mqtt_time_ovl
EXTERN _sprinter_unet_mqtt_publish_presence_core

    DEFB 4
    DEFW _sprinter_mqtt_send_ovl
    DEFW _sprinter_mqtt_setup_ovl
    DEFW _sprinter_mqtt_time_ovl
    DEFW sprinter_mqtt_presence_entry

sprinter_mqtt_presence_entry:
    JP _sprinter_unet_mqtt_publish_presence_core
