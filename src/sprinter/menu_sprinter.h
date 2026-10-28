#ifndef SHATRANJ_SPRINTER_MENU_H
#define SHATRANJ_SPRINTER_MENU_H

/* MENU_CONFIG uses context byte 0 for the focus or theme index.
 * Calls return before any board redraw; entries must not dispatch overlays. */
#define SPRINTER_MENU_RENDER 0u
#define SPRINTER_MENU_INIT_PIECES 1u
#define SPRINTER_MENU_APPLY_THEME 2u
#define SPRINTER_MENU_NEXT_PIECES 3u

#endif
