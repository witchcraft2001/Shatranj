#!/usr/bin/env python3
"""Import always-mapped parameter addresses into the second rendering page."""
import argparse
from pathlib import Path
from gen_sprinter_platform_defs import parse_sym
from gen_sprinter_cold_defs import parse_map
from gen_sprinter_cold_thunks import SECOND_PAGE_ENTRIES
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--prefix',default='')
ap.add_argument('--sym',type=Path,required=True); ap.add_argument('--out',type=Path,required=True)
a=ap.parse_args(); s=parse_sym(a.sym)
names=('render_aux_call flip_ring_reset flip_dirty_all FLIP_RING_MAX flip_arg_x flip_arg_y flip_arg_w flip_arg_h flip_ring flip_ring_count '
       'tile_src_page tile_src_offset HDR_ADDR HDR_ASSET_PAGE0_OFFSET LOWRAM_PIECE_STATE_ADDR '
       'text_previous_color text_precoloured_enabled text_glyph_bias color_valid fg_pattern bg_pattern foreground_buffer background_buffer text_cache_enabled text_cache_pending text_cache_hit text_font_version text_font_page TEXT_STAGE text_start_col text_scan_col text_y text_dest_base gfx_capture_rows text_color gfx_draw_tile_offset flip_log_rect LOWRAM_CHESS_BOARD_ADDR board_background_done back_base tile_dest_base tile_x_byte tile_x_hi tile_y tile_width tile_stride tile_rows tile_alias flip_log_suspended BOARD_X BOARD_Y render_square_entry cell_piece cell_background text_attr_index text_char text_glyph_page text_glyph_offset').split()
s['render_square_entry']=parse_map(a.sym.parent/'resident_c.map')['render_square']
s['AUX_ENTRY_BOARD_FULL']=SECOND_PAGE_ENTRIES['render_board_full']
names.append('AUX_ENTRY_BOARD_FULL')
a.out.write_text('; Generated parameter bridge.\n'+''.join(f'{a.prefix}{n} EQU #{s[n]:04X}\n' for n in names))
