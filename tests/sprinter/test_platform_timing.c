#include <assert.h>
#include <stdint.h>

#include "spectrum/platform/input.h"

static uint8_t frame_counter;
static uint8_t raw_key;
static unsigned raw_scans;

uint8_t sprinter_frame_counter_get(void)
{
    return frame_counter;
}

uint8_t sprinter_key_scan_raw(void)
{
    ++raw_scans;
    return raw_key;
}

int main(void)
{
    unsigned i;

    raw_key = 0x81u;
    spectrum_input_frame_tick();
    assert(spectrum_input_poll_event() == 0x81u);
    assert(raw_scans == 1u);

    for (i = 0u; i < 100u; ++i) {
        spectrum_input_frame_tick();
    }
    assert(raw_scans == 101u);
    assert(spectrum_input_poll_event() == 0u);

    /* Release is not a timer tick.  Even when the frame counter is unchanged,
       it must clear held/suppressed state so the same cursor key is accepted
       again instead of being discarded forever after a VBlank timeout. */
    raw_key = 0u;
    spectrum_input_frame_tick();
    raw_key = 0x81u;
    spectrum_input_frame_tick();
    assert(spectrum_input_poll_event() == 0x81u);

    /* A VBlank timeout must not make a newly completed DSS record invisible,
       while the held-key repeat above must still remain frame-paced. */
    raw_key = 0x82u;
    spectrum_input_frame_tick();
    assert(spectrum_input_poll_event() == 0x82u);
    raw_key = 0x81u;
    spectrum_input_frame_tick();
    assert(spectrum_input_poll_event() == 0x81u);

    for (i = 0u; i < 15u; ++i) {
        ++frame_counter;
        spectrum_input_frame_tick();
        assert(spectrum_input_poll_event() == 0u);
    }
    ++frame_counter;
    spectrum_input_frame_tick();
    assert(spectrum_input_poll_event() == 0x81u);

    frame_counter = 255u;
    spectrum_input_frame_tick();
    frame_counter = 0u;
    spectrum_input_frame_tick();
    assert(raw_scans == 123u);
    return 0;
}
