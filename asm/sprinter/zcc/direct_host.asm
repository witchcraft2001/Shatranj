; WIN3 NET wrappers: the DLL maps WIN1; arguments/results stay in WIN2.
SECTION code_user
EXTERN ng_call, ng_c_store_result
PUBLIC _host_listen, _host_status, _host_unlisten
_host_listen:
    ex de,hl                       ; fastcall binary port
    xor a                          ; channel 0
    ld b,18                        ; UNET_FN_LISTEN
    call ng_call
    jp ng_c_store_result
_host_status:
    xor a
    ld b,9                         ; UNET_FN_STATUS
    call ng_call
    jp ng_c_store_result
_host_unlisten:
    xor a
    ld b,19                        ; UNET_FN_UNLISTEN
    call ng_call
    jp ng_c_store_result

PUBLIC _host_rx_resume, _host_rx_pause
_host_rx_resume:
    ld b,14                        ; UNET_FN_RXRESUME
    jr host_rx_flow
_host_rx_pause:
    ld b,13                        ; UNET_FN_RXPAUSE
host_rx_flow:
    xor a
    call ng_call
    jp ng_c_store_result

PUBLIC _ng_getinfo_ip
EXTERN _ng_buf_ip
_ng_getinfo_ip:
    ld a,1                         ; UNET_IF_IP
    ld de,_ng_buf_ip
    ld ix,16
    ld b,15
    jp ng_call
