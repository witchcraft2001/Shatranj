; Network lifecycle and environment bridge in the free WIN2 tail.
; Keep UNETLD's internal uNet calls under the same reentry and canary
; discipline as ng_call. The library performs LOAD/NETSTART/UNLOAD itself.
ng_lifecycle_enter:
        ld      a,(ng_v_depth)
        or      a
        jp      nz,ng_trap_screen
        ld      a,1
        ld      (ng_v_depth),a
        call    canary_check
        ei
        ret
ng_lifecycle_exit:
        push    af
        call    canary_check
        xor     a
        ld      (ng_v_depth),a
        pop     af
        ret

; Compact state can be read by the NET screen before its first preflight.
; Initialize it before either editor seeding or any loader operation.
ng_init:
        ld      a,(ng_initialized)
        or      a
        ret     nz
        call    UNETLD.RESET
        ld      a,1
        ld      (ng_initialized),a
        ret

ng_up:
        call    ng_init
        ld      a,(UNETLD.FLAGS)
        and     UNETLD_F_NETINIT
        jr      z,.retry
        ld      a,(ng_up_reason)
        or      a
        ret     z                       ; already up
.retry:
        ; A failed attempt can leave an open handle. Clear it before SELECT.
        call    ng_lifecycle_enter
        call    UNETLD.UNLOAD
        call    ng_lifecycle_exit
        call    UNETLD.SELECT
        jr      c,.fail
        call    ng_lifecycle_enter
        ld      a,1                     ; DLL mapped into WIN1
        call    UNETLD.LOAD
        call    ng_lifecycle_exit
        jr      c,.fail
        ld      de,UNET_CAP_TCP
        call    UNETLD.REQUIRE
        jr      nc,.tcp_ok
        ld      a,NG_UP_ERR_CAPS
        jr      .fail
.tcp_ok:
        call    ng_lifecycle_enter
        call    UNETLD.NETSTART
        call    ng_lifecycle_exit
        jr      nc,.started
        cp      UNETLD_E_CALL
        jr      nz,.fail
        ld      a,NG_UP_ERR_NETSTART_CALL
        jr      .fail
.started:
        xor     a
        ld      (ng_up_reason),a
        ret
.fail:
        ld      (ng_up_reason),a
        scf
        ret


ng_c_env_get:
        call    ng_init
        ld      hl,(ng_c_env_name)
        ; DSS ENV_GET needs a full 256-byte buffer. UNETLD uses ENV_VALUE
        ; only during SELECT; editor defaults are seeded before preflight.
        ld      de,UNETLD.ENV_VALUE
        call    ng_env_try
        ld      a,0
        jr      c,.store
        ld      hl,UNETLD.ENV_VALUE
        ld      de,(ng_c_env_dest)
        ld      a,(ng_c_env_capacity)
        ld      c,a
        ld      b,0
        call    ng_copy_asciiz
        ld      a,1
.store:
        ld      (ng_c_env_found),a
        ret


ng_shutdown:
        ld      a,(ng_initialized)
        or      a
        ret     z
        ld      a,(UNETLD.FLAGS)
        ; A failed name/ABI check leaves a handle open, but must never
        ; dispatch a network operation into that unvalidated DLL.
        and     UNETLD_F_NETINIT
        jr      z,.unload
        xor     a                       ; channel 0
        ld      b,UNET_FN_CLOSE
        call    ng_call
.unload:
        call    ng_lifecycle_enter
        call    UNETLD.UNLOAD
        call    ng_lifecycle_exit
        xor     a
        ld      (ng_up_reason),a
        ret


ng_getinfo_ip:
        ld      a,UNET_IF_IP
        ld      de,ng_buf_ip
        ld      ix,NG_IP_CAPACITY
        ld      b,UNET_FN_GETINFO
        jp      ng_call


ng_env_try:
        ld      b,DSS_ENV_GET
        ld      c,DSS_ENVIRON
        rst     RST_DSS
        ret     c
        or      a
        jr      z,.not_found
        or      a
        ret
.not_found:
        scf
        ret


        INCLUDE "console_exit.asm"
