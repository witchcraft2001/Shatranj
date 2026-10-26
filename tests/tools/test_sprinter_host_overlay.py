import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
from check_sprinter_host_overlay import check, NAMES, ENTRIES

class HostPlacementTest(unittest.TestCase):
    def setUp(self):
        self.blob = bytes([11]) + b''.join((0xc100+i).to_bytes(2, 'little') for i in range(11)) + bytes(300)
        self.symbols = dict.fromkeys(NAMES, 0xc100)
        self.symbols.update({name: 0xc100+i for i, name in enumerate(ENTRIES)})
        self.symbols.update(dict.fromkeys(('ng_call', 'ng_c_store_result', 'ng_caps', 'ng_buf_ip'), 0x9000))
    def test_valid(self):
        check(self.blob, self.symbols)
    def test_wrapper_object_before_entry_table(self):
        with self.assertRaisesRegex(AssertionError, 'table must be first'):
            check(bytes([0xeb]) + self.blob[1:], self.symbols)
    def test_entry_outside_net(self):
        with self.assertRaisesRegex(AssertionError, 'entry 0'):
            check(self.blob[:1] + b'\x00\xf0' + self.blob[3:], self.symbols)
    def test_wrapper_displaced_by_dll(self):
        self.symbols['host_listen'] = 0x7000
        with self.assertRaisesRegex(AssertionError, 'host_listen outside NET'):
            check(self.blob, self.symbols)
    def test_unstable_result_bridge(self):
        self.symbols['ng_c_store_result'] = 0xc100
        with self.assertRaisesRegex(AssertionError, 'stable WIN2'):
            check(self.blob, self.symbols)
    def test_truncated_table(self):
        with self.assertRaisesRegex(AssertionError, 'truncated'):
            check(self.blob[:22], self.symbols)
    def test_entry_number_changed(self):
        swapped = self.blob[:1] + self.blob[3:5] + self.blob[1:3] + self.blob[5:]
        with self.assertRaisesRegex(AssertionError, 'entry 0 must call'):
            check(swapped, self.symbols)
    def test_nested_cleanup_import(self):
        self.symbols['net_drop'] = 0x7000
        with self.assertRaisesRegex(AssertionError, 'defer cleanup'):
            check(self.blob, self.symbols)
if __name__ == '__main__':
    unittest.main()
