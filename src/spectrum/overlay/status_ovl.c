#include "spectrum/overlay/overlay_api.h"
#include "spectrum/config/session.h"
#include "spectrum/session/event.h"
#include "spectrum/transport/esp_at.h"
#ifdef NETCHESSZX_SPRINTER
#include "sprinter/cold_text.h"
#endif

#define STATUS_PHASE_CONNECTION_SETUP 0u
#define STATUS_PHASE_GAME_SETUP 1u
#define STATUS_PHASE_CONNECTING 2u
#define STATUS_PHASE_CONNECTED 3u
#define STATUS_PHASE_GAME 4u

static char status_line_ovl[SPECTRUM_OVL_STATUS_LINE_SIZE];

static char *status_append(char *p, const char *src, char *end)
{
    while (*src != '\0' && p < end) {
        *p++ = *src++;
    }
    *p = '\0';
    return p;
}

#ifdef NETCHESSZX_SPRINTER_STAGE2_ECHO
static void status_build_phase(uint8_t phase)
{
    const char *text = "LOCAL HOT-SEAT";

    if (phase == STATUS_PHASE_CONNECTION_SETUP) {
        text = "LOCAL SETUP";
    } else if (phase == STATUS_PHASE_GAME_SETUP) {
        text = "GAME SETUP";
    } else if (phase == STATUS_PHASE_CONNECTING) {
        text = "LOCAL LINK";
    } else if (phase == STATUS_PHASE_CONNECTED) {
        text = "LOCAL LINK READY";
    }
    status_line_ovl[0] = '\0';
    (void)status_append(status_line_ovl, text,
                        status_line_ovl + SPECTRUM_OVL_STATUS_LINE_TEXT_SIZE);
}
#else
static char *status_append_char(char *p, char c, char *end)
{
    if (p < end) {
        *p++ = c;
        *p = '\0';
    }
    return p;
}

static char *status_append_mqtt_room(char *p, char *end)
{
    p = status_append(p, "MQTT ROOM ", end);
    if (netchesszx_mqtt_code[0] != '\0') {
        return status_append(p, netchesszx_mqtt_code, end);
    }
    return status_append(p, "-", end);
}

static char *status_append_direct_port(char *p, char *end)
{
    p = status_append_char(p, ':', end);
    if ((uint16_t)(end - p) >= 5u) {
        p = spectrum_append_u16(p, netchesszx_direct_port);
    }
    return p;
}

static char *status_append_direct_host(char *p, char *end)
{
    p = status_append(p, "DIRECT HOST ", end);
    p = status_append(p, spectrum_esp_at_last_ip()[0] != '\0'
                         ? spectrum_esp_at_last_ip()
                         : "-",
                      end);
    return status_append_direct_port(p, end);
}

static char *status_append_direct_peer(char *p, char *end)
{
    p = status_append(p, "DIRECT PEER ", end);
    p = status_append(p, netchesszx_direct_host, end);
    return status_append_direct_port(p, end);
}

static char *status_append_role(char *p, char *end)
{
    return status_append(p, netchesszx_session_is_host() ? "(HOST)" :
                                                        "(GUEST)",
                         end);
}

static char *status_append_direct_play_ip(char *p, char *end)
{
    if (netchesszx_session_is_host()) {
        if (spectrum_esp_at_last_ip()[0] != '\0') {
            return status_append(p, spectrum_esp_at_last_ip(), end);
        }
        return status_append(p, "-", end);
    }
    if (netchesszx_direct_host[0] != '\0') {
        return status_append(p, netchesszx_direct_host, end);
    }
    return status_append(p, "-", end);
}

static void status_build_phase(uint8_t phase)
{
    char *p = status_line_ovl;
    char *end = status_line_ovl + SPECTRUM_OVL_STATUS_LINE_TEXT_SIZE;

    status_line_ovl[0] = '\0';
    if (phase == STATUS_PHASE_CONNECTION_SETUP) {
        (void)status_append(p, "CONNECTION SETUP", end);
    } else if (phase == STATUS_PHASE_GAME_SETUP) {
        (void)status_append(p, "GAME SETUP", end);
    } else if (phase == STATUS_PHASE_CONNECTING) {
        if (netchesszx_transport_is_mqtt()) {
            (void)status_append_mqtt_room(p, end);
        } else if (netchesszx_session_is_host()) {
            (void)status_append_direct_host(p, end);
        } else {
            (void)status_append_direct_peer(p, end);
        }
    } else if (phase == STATUS_PHASE_CONNECTED) {
        if (netchesszx_transport_is_mqtt()) {
            p = status_append_mqtt_room(p, end);
            (void)status_append(p, netchesszx_session_peer_ready() ?
                                       " READY" : " WAIT",
                                end);
        } else if (netchesszx_session_is_host()) {
            if (netchesszx_session_peer_ready()) {
                (void)status_append(p, "DIRECT HOST - PEER LINKED", end);
            } else {
                (void)status_append_direct_host(p, end);
            }
        } else {
            (void)status_append_direct_peer(p, end);
        }
    } else if (phase == STATUS_PHASE_GAME) {
        p = status_append(p, "PLAYING IN ", end);
        if (netchesszx_transport_is_mqtt()) {
            p = status_append(p, netchesszx_mqtt_host, end);
            p = status_append(p, " ROOM ", end);
            if (netchesszx_mqtt_code[0] != '\0') {
                p = status_append(p, netchesszx_mqtt_code, end);
            } else {
                p = status_append(p, "-", end);
            }
            p = status_append_char(p, ' ', end);
            (void)status_append_role(p, end);
        } else {
            p = status_append_direct_play_ip(p, end);
            p = status_append_char(p, ' ', end);
            (void)status_append_role(p, end);
        }
    }
}
#endif

uint8_t status_phase_ovl(uint8_t *ctx) __z88dk_fastcall
{
    status_build_phase(ctx[SPECTRUM_OVL_CTX_STATUS_PHASE]);
#ifdef NETCHESSZX_SPRINTER
    /* This buffer belongs to the cold WIN1 overlay.  The UI gate changes
       WIN1 to the resident UI bank before it reads the argument, therefore
       copy it to permanent WIN2 first. */
    spectrum_gui_set_status(sprinter_cold_text(status_line_ovl));
#else
    spectrum_gui_set_status(status_line_ovl);
#endif
    return 1u;
}
