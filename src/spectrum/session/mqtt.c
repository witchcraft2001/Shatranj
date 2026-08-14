#include "spectrum/session/mqtt.h"

#include "spectrum/config/session.h"

uint8_t netchesszx_session_mqtt_side_relation(const char *payload, char verb)
{
    char side;
    uint16_t session_id;
    uint8_t has_session_id;
    uint8_t relation;

    if (!netchess_mqtt_session_parse_side(payload,
                                          verb,
                                          &side,
                                          &session_id,
                                          &has_session_id)) {
        return 0u;
    }
    relation = side == netchesszx_local_side_char()
        ? NETCHESSZX_SESSION_MQTT_SIDE_LOCAL
        : NETCHESSZX_SESSION_MQTT_SIDE_REMOTE;
    if (has_session_id && session_id == netchesszx_mqtt_session_id) {
        relation |= NETCHESSZX_SESSION_MQTT_SIDE_CURRENT;
    }
    return relation;
}

uint8_t netchesszx_session_mqtt_payload_is_foreign_host(const char *payload)
{
    uint8_t host_color;
    uint16_t session_id;

    /* Single-line macro call, deliberately: z88dk's sccz80 (Sprinter's
       compiler, S8 step 8c's first real build of this file there) mis-
       tokenizes a macro invocation whose arguments span multiple physical
       lines -- corrupts not just this call but the token immediately
       after it, confirmed with a minimal repro outside this codebase.
       SDCC (ZX/Next) is unaffected either way; this is a pure formatting
       change, safe for both. */
    return (uint8_t)(netchesszx_session_mqtt_parse_host_payload(payload, &host_color, &session_id) &&
                     session_id != netchesszx_mqtt_session_id);
}

uint8_t netchesszx_session_mqtt_payload_marks_peer_ready(const char *payload,
                                                         uint8_t is_host)
{
    uint16_t session_id;

    /* Single-line macro call -- see the sccz80 multi-line note above. */
    if (!is_host ||
        !netchesszx_session_mqtt_parse_join_payload(payload, &session_id) ||
        session_id != netchesszx_mqtt_session_id) {
        return 0u;
    }
    return 1u;
}

uint8_t netchesszx_session_mqtt_apply_host_color(const char *payload,
                                                 uint8_t game_active,
                                                 uint8_t *color_changed,
                                                 uint8_t *new_live_session)
{
    uint8_t old_local;
    uint8_t host_color;
    uint16_t session_id;
    uint8_t was_ready;

    *color_changed = 0u;
    *new_live_session = 0u;
    /* Single-line macro call -- see the sccz80 multi-line note above. */
    if (!netchesszx_session_mqtt_parse_host_payload(payload, &host_color, &session_id)) {
        return 0u;
    }
    if (netchesszx_mqtt_session_id != 0u &&
        session_id != netchesszx_mqtt_session_id) {
        if (game_active) {
            return 0u;
        }
        *new_live_session = 1u;
    }
    netchesszx_mqtt_session_id = session_id;
    old_local = netchesszx_local_color;
    was_ready = *new_live_session ? 0u : netchesszx_host_color_ready;
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_MQTT,
                                 host_color);
    *color_changed = (uint8_t)(old_local != netchesszx_local_color);
    return was_ready ? 1u : 2u;
}
