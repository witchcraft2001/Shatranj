/* Compile the real menu reducer for both the Sprinter and ZX/Next variants. */
#include <assert.h>
#include "spectrum/ui/gui.c"
void spectrum_render_menu(uint8_t visible) { (void)visible; }
int main(void) {
    const uint8_t actions[] = {
        SPECTRUM_GUI_KEY_MENU_FILE, SPECTRUM_GUI_KEY_MENU_DISCC,
        SPECTRUM_GUI_KEY_MENU_REST, SPECTRUM_GUI_KEY_MENU_FLIP,
        SPECTRUM_GUI_KEY_MENU_THEME,
#ifdef NETCHESSZX_SPRINTER
        SPECTRUM_GUI_KEY_MENU_PIECES,
#endif
        SPECTRUM_GUI_KEY_MENU_ABOUT
    };
    unsigned int i, activation;
    assert(sizeof(actions) == MENU_OPTION_COUNT);
    for (i = 0; i < sizeof(actions); ++i) {
        unsigned int j;
        assert(actions[i] != SPECTRUM_GUI_KEY_MENU);
        for (j = i + 1; j < sizeof(actions); ++j) assert(actions[i] != actions[j]);
    }
    for (activation = 0; activation < 2; ++activation) {
        for (i = 0; i < sizeof(actions); ++i) {
            menu_focus = (uint8_t)i;
            menu_visible = 0;
            assert(spectrum_gui_handle_menu_key(SPECTRUM_GUI_KEY_MENU) == 0);
            assert(menu_visible);
            assert(spectrum_gui_handle_menu_key(activation ? 32 : 13) == actions[i]);
            assert(!menu_visible);
        }
    }
    menu_visible = 1;
    menu_focus = 0;
    spectrum_gui_handle_menu_key(GUI_KEY_LEFT);
    assert(menu_focus == MENU_OPTION_COUNT - 1);
    spectrum_gui_handle_menu_key(GUI_KEY_RIGHT);
    assert(menu_focus == 0);
    for (i = 1; i <= MENU_OPTION_COUNT; ++i) {
        spectrum_gui_handle_menu_key(GUI_KEY_RIGHT);
        assert(menu_focus == i % MENU_OPTION_COUNT);
    }
    return 0;
}
