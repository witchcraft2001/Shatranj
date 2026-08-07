#ifndef SHATRANJ_SPRINTER_UNET_LINK_H
#define SHATRANJ_SPRINTER_UNET_LINK_H

#include <stdint.h>

#include "spectrum/transport/link.h"

uint8_t sprinter_unet_preflight_core(void);
uint8_t sprinter_unet_preflight_error(void);
uint8_t sprinter_unet_mqtt_start_core(void);
uint8_t sprinter_unet_mqtt_activate_core(void);
uint8_t sprinter_unet_mqtt_probe_core(void);
uint8_t sprinter_unet_mqtt_publish_setup_core(uint8_t mode);
uint8_t sprinter_unet_mqtt_publish_presence_core(void);
uint8_t sprinter_unet_mqtt_send_core(const char *text);
uint8_t sprinter_unet_direct_connect_core(void);
int16_t sprinter_unet_direct_read_core(char *payload, uint8_t payload_cap);
uint8_t sprinter_unet_direct_send_core(const char *text);

#endif
