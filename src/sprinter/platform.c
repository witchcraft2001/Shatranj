#include <stdint.h>

#include "spectrum/config/session.h"
#include "spectrum/platform/input.h"
#include "spectrum/platform/platform.h"
#include "spectrum/ui/render.h"

/* These entry points live in the permanent WIN2 assembly runtime. */
extern uint8_t sprinter_key_scan_raw(void);
extern uint8_t sprinter_frame_counter_get(void);
extern void sprinter_clean_exit(uint8_t code) __z88dk_fastcall;
extern uint8_t sprinter_palette_restore(void);

static uint8_t key_event;
static uint8_t key_last;
static uint8_t key_suppress;
static uint8_t key_repeat_timer;
/* DSS reports a completed key record, not its physical up/down state.  A
   short Enter/Space press can therefore leave one queued repeat behind the
   first record.  In game play that repeat may be consumed after an arrow and
   accidentally confirm a destination square. */
static uint8_t select_debounce;
static uint8_t input_frame_seen;
static uint8_t input_last_frame;

#define SPRINTER_SELECT_DEBOUNCE_FRAMES 12u

static uint8_t is_select_key(uint8_t key)
{
    return key == 13u || key == 32u;
}

static uint8_t repeatable(uint8_t key)
{
    return key == 8u || (key >= 0x81u && key < 0x8au) ||
           (key >= 33u && key < 127u);
}

static uint8_t repeat_start(uint8_t key)
{
    if (key == 8u) {
        return 12u;
    }
    if (key >= 0x81u && key < 0x8au) {
        return 15u;
    }
    return 20u;
}

static uint8_t repeat_next(uint8_t key)
{
    if (key == 8u) {
        return 2u;
    }
    if (key == 0x81u || key == 0x82u) {
        return 5u;
    }
    return 3u;
}

uint8_t spectrum_assets_load(void)
{
    return 1u;
}

void spectrum_assets_fatal(void)
{
    sprinter_clean_exit(1u);
}

uint8_t spectrum_key_edit_pressed(void)
{
    return 0u;
}

void spectrum_input_frame_tick(void)
{
    uint8_t frame = sprinter_frame_counter_get();
    uint8_t frame_advanced;
    uint8_t key;

    frame_advanced = (uint8_t)(!input_frame_seen || frame != input_last_frame);
    if (frame_advanced) {
        input_last_frame = frame;
        input_frame_seen = 1u;
    }
    /* Consume DSS records even when VBlank acquisition timed out.  Repeat and
       debounce time still advance only on a real frame-counter edge below. */
    key = sprinter_key_scan_raw();

    if (frame_advanced && select_debounce != 0u) {
        --select_debounce;
    }

    if (key == 0u) {
        /* A release is input state, not elapsed time.  Clearing it only on a
           VBlank edge can permanently retain key_suppress/key_last after a
           video-sync timeout, making the next cursor press look like a hang. */
        key_last = 0u;
        key_repeat_timer = 0u;
        key_suppress = 0u;
        return;
    }
    if (key_suppress != 0u) {
        if (key == key_suppress) {
            return;
        }
        key_suppress = 0u;
    }
    if (key != key_last) {
        key_last = key;
        key_repeat_timer = repeat_start(key);
    } else {
        if (!frame_advanced) {
            return;
        }
        if (!repeatable(key)) {
            return;
        }
        if (key_repeat_timer != 0u) {
            --key_repeat_timer;
            return;
        }
        key_repeat_timer = repeat_next(key);
    }
    if (is_select_key(key)) {
        if (select_debounce != 0u) {
            return;
        }
        select_debounce = SPRINTER_SELECT_DEBOUNCE_FRAMES;
    }
    if (key == 0x8au || key == 0x90u || key_event == 0u) {
        key_event = key;
    }
}

uint8_t spectrum_input_poll_event(void)
{
    uint8_t key = key_event;
    key_event = 0u;
    return key;
}

uint8_t spectrum_key_poll(void)
{
    return spectrum_input_poll_event();
}

void spectrum_input_flush_until_release(void)
{
    key_event = 0u;
    select_debounce = 0u;
    input_last_frame = sprinter_frame_counter_get();
    input_frame_seen = 1u;
    key_suppress = sprinter_key_scan_raw();
    if (key_suppress == 0u) {
        key_last = 0u;
        key_repeat_timer = 0u;
    }
}

void spectrum_input_suppress_until_release(uint8_t key) __z88dk_fastcall
{
    key_event = 0u;
    input_last_frame = sprinter_frame_counter_get();
    input_frame_seen = 1u;
    if (is_select_key(key)) {
        select_debounce = SPRINTER_SELECT_DEBOUNCE_FRAMES;
    }
    key_suppress = key;
}

uint8_t spectrum_input_parse_move(const char *text, char *move)
{
    uint8_t length = 0u;
    uint8_t fc;
    uint8_t fr;
    uint8_t tc;
    uint8_t tr;
    char promotion = 0;

    while (text[length] != '\0' && length < 6u) {
        ++length;
    }
    if (length != 4u && length != 5u) {
        return 0u;
    }
    fc = (uint8_t)(text[0] - 'a');
    fr = (uint8_t)('8' - text[1]);
    tc = (uint8_t)(text[2] - 'a');
    tr = (uint8_t)('8' - text[3]);
    if (fc >= 8u || fr >= 8u || tc >= 8u || tr >= 8u ||
        (fc == tc && fr == tr)) {
        return 0u;
    }
    if (length == 5u) {
        promotion = text[4];
        if (promotion >= 'A' && promotion <= 'Z') {
            promotion = (char)(promotion + ('a' - 'A'));
        }
        if (promotion != 'q' && promotion != 'r' &&
            promotion != 'b' && promotion != 'n') {
            return 0u;
        }
    }
    move[0] = text[0];
    move[1] = text[1];
    move[2] = text[2];
    move[3] = text[3];
    move[4] = promotion;
    move[5] = '\0';
    return 1u;
}

void netchesszx_board_theme_apply(uint8_t theme)
{
    static const uint8_t light[5] = {0x38u, 0x39u, 0x3au, 0x3bu, 0x3cu};
    static const uint8_t dark[5] = {0x07u, 0x06u, 0x05u, 0x04u, 0x03u};
    if (theme >= 5u) {
        theme = 0u;
    }
    netchesszx_board_theme_index = theme;
    netchesszx_board_light_attr = light[theme];
    netchesszx_board_dark_attr = dark[theme];
    (void)sprinter_palette_restore();
}

uint8_t netchesszx_piece_set_load(uint8_t set) __z88dk_fastcall
{
    if (set >= NETCHESSZX_PIECE_SET_COUNT) {
        return 0u;
    }
    netchesszx_piece_set_index = set;
    (void)sprinter_palette_restore();
    return 1u;
}
