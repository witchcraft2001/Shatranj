#!/usr/bin/env python3
"""Check NET table/placement and emit addresses for shipped-wrapper Z80 tests."""
import argparse
from pathlib import Path
from gen_sprinter_overlay_defs import parse_map

NAMES = ('host_listen', 'host_status', 'host_unlisten', 'host_rx_pause', 'host_rx_resume', 'ng_getinfo_ip')
ENTRIES = ('net_mqtt_connect_start_ovl', 'net_mqtt_activate_side_ovl',
           'net_preflight_ovl', 'net_mqtt_probe_seat_ovl', 'net_join_ui_ovl',
           'net_host_wait_ovl', 'net_prepare_ovl', 'net_hello_ovl',
           'net_host_close_ovl', 'net_network_ovl', 'net_hello_tick_ovl')
def check(blob, symbols):
    table_end = 1 + 2 * len(ENTRIES)
    assert len(blob) >= table_end, 'truncated NET entry table'
    assert len(blob) <= 12288, 'NET exceeds its slot'
    assert blob[0] == len(ENTRIES), 'NET table must be first, with 11 entries'
    for i, name in enumerate(ENTRIES):
        address = int.from_bytes(blob[1+2*i:3+2*i], 'little')
        assert 0xc000 + table_end <= address < 0xc000 + len(blob), f'NET entry {i} outside NET payload'
        assert address == symbols[name], f'NET entry {i} must call {name}'
    for name in NAMES:
        assert 0xc000 + table_end <= symbols[name] < 0xc000 + len(blob), f'{name} outside NET'
    assert 'net_drop' not in symbols, 'NET must defer cleanup until after dispatch'
    for name in ('ng_call', 'ng_c_store_result', 'ng_caps', 'ng_buf_ip'):
        assert 0x8000 <= symbols[name] < 0xc000, f'{name} must be stable WIN2'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--map', required=True)
    parser.add_argument('--bin', required=True)
    parser.add_argument('--defs')
    parser.add_argument('--cold-map')
    args = parser.parse_args()
    symbols = parse_map(Path(args.map))
    check(Path(args.bin).read_bytes(), symbols)
    if args.defs:
        text = ''.join(f'host_test_{n}: EQU ${symbols[n]:04X}\n' for n in NAMES)
        if args.cold_map:
            cold = parse_map(Path(args.cold_map))
            names = ('net_drop', 'net_dispatch', 'net_op_busy', 'menu_network', 'spectrum_net_send_text', 'netchesszx_transport', 'net_active', 'pending_local_ply', 'pending_local_move',
                     'pending_retry_timer', 'control_pending', 'control_retry_count',
                     'takeback_pending_ply', 'takeback_snapshot_ply', 'takeback_snapshot_local',
                     'restore_rx_mask', 'restore_chunk_have', 'restore_prompt_pending',
                     'resign_pending', 'resign_confirm', 'game_over',
                     'netchesszx_session_peer_ready_state', 'spectrum_overlay_exec_cached',
                     'net_status_idle', 'spectrum_gui_game_timer_stop',
                     'spectrum_gui_reset_chat', 'spectrum_gui_notify')
            text += ''.join(f'host_cold_{n}: EQU ${cold[n]:04X}\n' for n in names)
        Path(args.defs).write_text(text)
    print('[OK] NET entry table, WIN3 wrappers and stable WIN2 bridge')
if __name__ == '__main__':
    main()
