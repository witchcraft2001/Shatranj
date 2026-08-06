; Stable resident WIN2 gate ABI shared by the base bank and cold modules.
; Keep this list append-only within a Sprinter stage: every entry is one JP.

DEFC SPR_API_OVERLAY_EXEC = 0x8200
DEFC SPR_API_OVERLAY_CACHED = 0x8203
DEFC SPR_API_ESX_FOPEN = 0x8206
DEFC SPR_API_ESX_FCREATE = 0x8209
DEFC SPR_API_ESX_FREAD = 0x820C
DEFC SPR_API_ESX_FWRITE = 0x820F
DEFC SPR_API_ESX_FCLOSE = 0x8212
DEFC SPR_API_ESX_FUNLINK = 0x8215
DEFC SPR_API_ESX_OPENDIR = 0x8218
DEFC SPR_API_ESX_READDIR = 0x821B
DEFC SPR_API_ESX_MOVE_FP = 0x821E
DEFC SPR_API_FAT_DATE = 0x8221
DEFC SPR_API_FAT_TIME = 0x8224
DEFC SPR_API_CLOCK_READY = 0x8227
DEFC SPR_API_FRAME_WAIT = 0x822A
DEFC SPR_API_KEY_POLL = 0x822D
DEFC SPR_API_INPUT_FRAME_TICK = 0x8230
DEFC SPR_API_INPUT_POLL_EVENT = 0x8233
DEFC SPR_API_INPUT_FLUSH = 0x8236
DEFC SPR_API_INPUT_SUPPRESS = 0x8239
DEFC SPR_API_INPUT_PARSE_MOVE = 0x823C
DEFC SPR_API_ASSETS_LOAD = 0x823F
DEFC SPR_API_ASSETS_FATAL = 0x8242
DEFC SPR_API_KEY_EDIT = 0x8245
DEFC SPR_API_THEME_APPLY = 0x8248
DEFC SPR_API_PIECE_SET_LOAD = 0x824B
DEFC SPR_API_RENDER_BOARD = 0x824E
DEFC SPR_API_RENDER_BOARD_AREA = 0x8251
DEFC SPR_API_RENDER_BOARD_COORDS = 0x8254
DEFC SPR_API_RENDER_BOARD_COORD_MARK = 0x8257
DEFC SPR_API_RENDER_STATUS = 0x825A
DEFC SPR_API_RENDER_STATUS_ERROR = 0x825D
DEFC SPR_API_RENDER_CLOCK = 0x8260
DEFC SPR_API_RENDER_GAME_TIMER_CLEAR = 0x8263
DEFC SPR_API_RENDER_GAME_TIMER_CHAR = 0x8266
DEFC SPR_API_RENDER_MENU_TIMER_CHAR = 0x8269
DEFC SPR_API_RENDER_TURN_LABEL = 0x826C
DEFC SPR_API_RENDER_NOTICE = 0x826F
DEFC SPR_API_RENDER_NOTICE_ERROR = 0x8272
DEFC SPR_API_RENDER_NOTICE_SUCCESS = 0x8275
DEFC SPR_API_RENDER_CONNECTION = 0x8278
DEFC SPR_API_RENDER_MENU = 0x827B
DEFC SPR_API_RENDER_SQUARE = 0x827E
DEFC SPR_API_RENDER_SQUARE_ATTR = 0x8281
DEFC SPR_API_RENDER_SQUARE_HINT = 0x8284
DEFC SPR_API_RENDER_SQUARE_MARK = 0x8287
DEFC SPR_API_RENDER_SQUARE_MARK_HINT = 0x828A
DEFC SPR_API_RENDER_MOVES = 0x828D
DEFC SPR_API_RENDER_MOVE_AT = 0x8290
DEFC SPR_API_RENDER_MOVES_SCROLL = 0x8293
DEFC SPR_API_RENDER_CHAT = 0x8296
DEFC SPR_API_RENDER_CHAT_AT = 0x8299
DEFC SPR_API_RENDER_CHAT_SCROLL = 0x829C
DEFC SPR_API_RENDER_INPUT = 0x829F
DEFC SPR_API_RENDER_INPUT_CELL = 0x82A2
DEFC SPR_API_RENDER_ABOUT = 0x82A5
DEFC SPR_API_RENDER_IKKLE = 0x82A8
DEFC SPR_API_RENDER_FILE_FRAME = 0x82AB
DEFC SPR_API_RENDER_FILE_SELECT = 0x82AE
DEFC SPR_API_INFO_SHOW_GAME = 0x82B1
DEFC SPR_API_INFO_SHOW_SETUP = 0x82B4
DEFC SPR_API_INFO_SHOW_GAME_SETUP = 0x82B7
DEFC SPR_API_INFO_SHOW_PREFLIGHT = 0x82BA
DEFC SPR_API_INFO_CLEAR_TAIL = 0x82BD
DEFC SPR_API_INFO_LINE = 0x82C0
DEFC SPR_API_HINTS_CLEAR = 0x82C3
DEFC SPR_API_HINTS_SHOW = 0x82C6
DEFC SPR_API_SETUP_STEP = 0x82C9
DEFC SPR_API_SETUP_EDIT_LINE = 0x82CC
DEFC SPR_API_SETUP_VISIBLE = 0x82CF
DEFC SPR_API_SETUP_RENDER = 0x82D2
DEFC SPR_API_SETUP_PAINT = 0x82D5
DEFC SPR_API_SETUP_ROWS = 0x82D8
DEFC SPR_API_RAW_KEY_SCAN = 0x82DB

PUBLIC _spectrum_overlay_exec, _spectrum_overlay_exec_cached
PUBLIC _esx_fopen, _esx_fcreate, _esx_fread, _esx_fwrite, _esx_fclose
PUBLIC _esx_funlink, _esx_opendir, _esx_readdir, _esx_move_fp
PUBLIC _spectrum_frame_wait
PUBLIC _spectrum_key_poll, _spectrum_input_frame_tick
PUBLIC _spectrum_input_poll_event, _spectrum_input_flush_until_release
PUBLIC _spectrum_input_suppress_until_release, _spectrum_input_parse_move
PUBLIC _spectrum_assets_load, _spectrum_assets_fatal, _spectrum_key_edit_pressed
PUBLIC _netchesszx_board_theme_apply, _netchesszx_piece_set_load
PUBLIC _spectrum_render_board, _spectrum_render_board_area
PUBLIC _spectrum_render_board_coords, _spectrum_render_board_coord_mark
PUBLIC _spectrum_render_status, _spectrum_render_status_error
PUBLIC _spectrum_render_clock, _spectrum_render_game_timer_clear
PUBLIC _spectrum_render_game_timer_char, _spectrum_render_menu_timer_char
PUBLIC _spectrum_render_turn_label, _spectrum_render_notice
PUBLIC _spectrum_render_notice_error, _spectrum_render_notice_success
PUBLIC _spectrum_render_connection, _spectrum_render_menu
PUBLIC _spectrum_render_square, _spectrum_render_square_attr
PUBLIC _spectrum_render_square_with_hint, _spectrum_render_square_mark
PUBLIC _spectrum_render_square_mark_with_hint, _spectrum_render_moves
PUBLIC _spectrum_render_move_at, _spectrum_render_moves_scroll
PUBLIC _spectrum_render_chat, _spectrum_render_chat_at
PUBLIC _spectrum_render_chat_scroll, _spectrum_render_input
PUBLIC _spectrum_render_input_cell, _spectrum_render_about
PUBLIC _spectrum_render_ikkle_at, _spectrum_render_fileui_frame
PUBLIC _spectrum_render_fileui_select, _spectrum_info_show_game
PUBLIC _spectrum_info_show_setup, _spectrum_info_show_game_setup
PUBLIC _spectrum_info_show_preflight, _spectrum_info_clear_tail
PUBLIC _spectrum_info_line, _netchesszx_setup_step_overlay
PUBLIC _netchesszx_setup_render_edit_line, _netchesszx_setup_compute_visible
PUBLIC _netchesszx_setup_render_overlay, _netchesszx_setup_paint_attrs
PUBLIC _netchesszx_setup_render_rows
PUBLIC _sprinter_key_scan_raw

DEFC _spectrum_overlay_exec = SPR_API_OVERLAY_EXEC
DEFC _spectrum_overlay_exec_cached = SPR_API_OVERLAY_CACHED
DEFC _esx_fopen = SPR_API_ESX_FOPEN
DEFC _esx_fcreate = SPR_API_ESX_FCREATE
DEFC _esx_fread = SPR_API_ESX_FREAD
DEFC _esx_fwrite = SPR_API_ESX_FWRITE
DEFC _esx_fclose = SPR_API_ESX_FCLOSE
DEFC _esx_funlink = SPR_API_ESX_FUNLINK
DEFC _esx_opendir = SPR_API_ESX_OPENDIR
DEFC _esx_readdir = SPR_API_ESX_READDIR
DEFC _esx_move_fp = SPR_API_ESX_MOVE_FP
DEFC _spectrum_frame_wait = SPR_API_FRAME_WAIT
DEFC _spectrum_key_poll = SPR_API_KEY_POLL
DEFC _spectrum_input_frame_tick = SPR_API_INPUT_FRAME_TICK
DEFC _spectrum_input_poll_event = SPR_API_INPUT_POLL_EVENT
DEFC _spectrum_input_flush_until_release = SPR_API_INPUT_FLUSH
DEFC _spectrum_input_suppress_until_release = SPR_API_INPUT_SUPPRESS
DEFC _spectrum_input_parse_move = SPR_API_INPUT_PARSE_MOVE
DEFC _spectrum_assets_load = SPR_API_ASSETS_LOAD
DEFC _spectrum_assets_fatal = SPR_API_ASSETS_FATAL
DEFC _spectrum_key_edit_pressed = SPR_API_KEY_EDIT
DEFC _netchesszx_board_theme_apply = SPR_API_THEME_APPLY
DEFC _netchesszx_piece_set_load = SPR_API_PIECE_SET_LOAD
DEFC _spectrum_render_board = SPR_API_RENDER_BOARD
DEFC _spectrum_render_board_area = SPR_API_RENDER_BOARD_AREA
DEFC _spectrum_render_board_coords = SPR_API_RENDER_BOARD_COORDS
DEFC _spectrum_render_board_coord_mark = SPR_API_RENDER_BOARD_COORD_MARK
DEFC _spectrum_render_status = SPR_API_RENDER_STATUS
DEFC _spectrum_render_status_error = SPR_API_RENDER_STATUS_ERROR
DEFC _spectrum_render_clock = SPR_API_RENDER_CLOCK
DEFC _spectrum_render_game_timer_clear = SPR_API_RENDER_GAME_TIMER_CLEAR
DEFC _spectrum_render_game_timer_char = SPR_API_RENDER_GAME_TIMER_CHAR
DEFC _spectrum_render_menu_timer_char = SPR_API_RENDER_MENU_TIMER_CHAR
DEFC _spectrum_render_turn_label = SPR_API_RENDER_TURN_LABEL
DEFC _spectrum_render_notice = SPR_API_RENDER_NOTICE
DEFC _spectrum_render_notice_error = SPR_API_RENDER_NOTICE_ERROR
DEFC _spectrum_render_notice_success = SPR_API_RENDER_NOTICE_SUCCESS
DEFC _spectrum_render_connection = SPR_API_RENDER_CONNECTION
DEFC _spectrum_render_menu = SPR_API_RENDER_MENU
DEFC _spectrum_render_square = SPR_API_RENDER_SQUARE
DEFC _spectrum_render_square_attr = SPR_API_RENDER_SQUARE_ATTR
DEFC _spectrum_render_square_with_hint = SPR_API_RENDER_SQUARE_HINT
DEFC _spectrum_render_square_mark = SPR_API_RENDER_SQUARE_MARK
DEFC _spectrum_render_square_mark_with_hint = SPR_API_RENDER_SQUARE_MARK_HINT
DEFC _spectrum_render_moves = SPR_API_RENDER_MOVES
DEFC _spectrum_render_move_at = SPR_API_RENDER_MOVE_AT
DEFC _spectrum_render_moves_scroll = SPR_API_RENDER_MOVES_SCROLL
DEFC _spectrum_render_chat = SPR_API_RENDER_CHAT
DEFC _spectrum_render_chat_at = SPR_API_RENDER_CHAT_AT
DEFC _spectrum_render_chat_scroll = SPR_API_RENDER_CHAT_SCROLL
DEFC _spectrum_render_input = SPR_API_RENDER_INPUT
DEFC _spectrum_render_input_cell = SPR_API_RENDER_INPUT_CELL
DEFC _spectrum_render_about = SPR_API_RENDER_ABOUT
DEFC _spectrum_render_ikkle_at = SPR_API_RENDER_IKKLE
DEFC _spectrum_render_fileui_frame = SPR_API_RENDER_FILE_FRAME
DEFC _spectrum_render_fileui_select = SPR_API_RENDER_FILE_SELECT
DEFC _spectrum_info_show_game = SPR_API_INFO_SHOW_GAME
DEFC _spectrum_info_show_setup = SPR_API_INFO_SHOW_SETUP
DEFC _spectrum_info_show_game_setup = SPR_API_INFO_SHOW_GAME_SETUP
DEFC _spectrum_info_show_preflight = SPR_API_INFO_SHOW_PREFLIGHT
DEFC _spectrum_info_clear_tail = SPR_API_INFO_CLEAR_TAIL
DEFC _spectrum_info_line = SPR_API_INFO_LINE
DEFC _netchesszx_setup_step_overlay = SPR_API_SETUP_STEP
DEFC _netchesszx_setup_render_edit_line = SPR_API_SETUP_EDIT_LINE
DEFC _netchesszx_setup_compute_visible = SPR_API_SETUP_VISIBLE
DEFC _netchesszx_setup_render_overlay = SPR_API_SETUP_RENDER
DEFC _netchesszx_setup_paint_attrs = SPR_API_SETUP_PAINT
DEFC _netchesszx_setup_render_rows = SPR_API_SETUP_ROWS
DEFC _sprinter_key_scan_raw = SPR_API_RAW_KEY_SCAN
