"""Build-time classification for Sprinter UI operations that may stall RX."""

SLOW_UI_EXPORTS = frozenset({
    "_netchesszx_board_theme_apply",
    "_netchesszx_piece_set_load",
    "_spectrum_fileui_open_render",
    "_spectrum_fileui_rerender",
    "_spectrum_fileui_send_key",
    "_spectrum_gui_animate_board_pieces",
    "_spectrum_gui_apply_move",
    "_spectrum_gui_draw_board",
    "_spectrum_gui_hide_board_pieces",
    "_spectrum_gui_prepare_move",
    "_spectrum_gui_redraw_board_squares",
    "_spectrum_gui_redraw_board_view",
    "_spectrum_gui_reset_logs",
    "_spectrum_gui_reset_moves",
    "_spectrum_gui_restore_board_area",
    "_spectrum_gui_restore_side_panels",
    "_spectrum_gui_show_about",
    "_spectrum_gui_show_fileui",
    "_spectrum_gui_toggle_board_view",
    "_spectrum_info_clear_tail",
    "_spectrum_info_show_game",
    "_spectrum_info_show_game_setup",
    "_spectrum_info_show_preflight",
    "_spectrum_info_show_setup",
    "_spectrum_render_about",
    "_spectrum_render_board",
    "_spectrum_render_board_area",
    "_spectrum_render_chat",
    "_spectrum_render_chat_scroll",
    "_spectrum_render_fileui_frame",
    "_spectrum_render_menu",
    "_spectrum_render_moves",
    "_spectrum_render_moves_scroll",
    "_spectrum_saveload_run",
    "_sprinter_render_present",
})


def slow_ui_flags(symbol: str) -> int:
    return 1 if symbol in SLOW_UI_EXPORTS else 0
