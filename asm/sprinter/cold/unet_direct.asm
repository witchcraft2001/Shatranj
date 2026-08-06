SECTION code_user

EXTERN _sprinter_direct_listen_ovl
EXTERN _sprinter_unet_direct_connect_core
EXTERN _sprinter_direct_wait_ovl
EXTERN _sprinter_direct_read_ovl
EXTERN _sprinter_direct_send_ovl

    DEFB 5
    DEFW _sprinter_direct_listen_ovl
    DEFW sprinter_direct_connect_entry
    DEFW _sprinter_direct_wait_ovl
    DEFW _sprinter_direct_read_ovl
    DEFW _sprinter_direct_send_ovl

sprinter_direct_connect_entry:
    JP _sprinter_unet_direct_connect_core
