import unittest

from tools.adapt_sprinter_libman import adapt


class SprinterLibmanAdapterTest(unittest.TestCase):
    def test_disk_rst_is_replaced(self):
        source = "\tld c,13h\n\tld hl,0c000h\n\trst 10h\n"
        output, count = adapt(source)
        self.assertEqual(count, 1)
        self.assertIn("call    sprinter_disk_gate", output)
        self.assertNotIn("rst 10h", output)

    def test_labeled_disk_load_is_replaced(self):
        source = "ll0:\tld c,13h\n\tld hl,0c000h\n\trst 10h\n"
        output, count = adapt(source)
        self.assertEqual(count, 1)
        self.assertIn("call    sprinter_disk_gate", output)
        self.assertNotIn("rst 10h", output)

    def test_memory_and_window_rsts_remain_native(self):
        source = "\tld bc,013dh\n\trst 10h\n"
        output, count = adapt(source)
        self.assertEqual(count, 0)
        self.assertNotIn("sprinter_disk_gate", output)
        self.assertIn("rst 10h", output)

    def test_libman_keeps_distinct_win3_decode_scratch(self):
        source = (
            " in a,(0e2h)\n"
            " ld bc,003bh\n"
            " ld hl,0c000h\n"
            " ld de,0c000h\n"
            " ld h,0c0h\n"
            " ld hl,0c004h\n"
        )
        output, count = adapt(source)
        self.assertEqual(count, 0)
        self.assertIn("in a,(0e2h)", output)
        self.assertIn("ld bc,003bh", output)
        self.assertIn("ld hl,0c000h", output)
        self.assertIn("ld de,0c000h", output)
        self.assertIn("ld h,0c0h", output)
        self.assertIn("ld hl,0c004h", output)

    def test_move_fp_uses_low_function_byte(self):
        output, count = adapt(" ld bc,0215h\n rst 10h\n")
        self.assertEqual(count, 1)
        self.assertIn("sprinter_disk_gate", output)


if __name__ == "__main__":
    unittest.main()
