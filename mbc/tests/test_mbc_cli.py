"""Focused public CLI checks; dry runs must never connect or send input."""
import json
import os
from pathlib import Path
import subprocess
import unittest

BINARY = os.environ.get("MBC_BINARY", str(Path(__file__).resolve().parents[2] / "target/mbc/macos-ble-control"))


def run(*args):
    return subprocess.run([BINARY, *args], capture_output=True, text=True, timeout=25)


class CLITests(unittest.TestCase):
    def test_help_exits_without_bluetooth_activity(self):
        result = run("--help")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for flag in ("--move", "--click", "--type", "--key", "--scroll", "--status"):
            self.assertIn(flag, result.stdout)
        self.assertNotIn("Connected", result.stdout)

    def plan(self, *args):
        result = run("--dry-run", *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)["commands"]

    def test_sequence_preserves_order_and_click_coordinate(self):
        self.assertEqual(self.plan("--move", "52,54", "--click", "--type", "Hello", "--key", "cmd+a"),
                         ["move 52 54", "click 52 54", "type Hello", "key cmd+a"])

    def test_click_target_and_signed_scroll(self):
        self.assertEqual(self.plan("--click", "0,100", "--scroll", "-3,2", "--status"),
                         ["click 0 100", "scroll -3 2", "status"])

    def test_late_invalid_argument_prevents_all_input(self):
        for args in [("--move", "101,0"), ("--move", "1.5,2"), ("--move", "1,2,3"),
                     ("--move", "NaN,2"), ("--scroll", "128"), ("--click", "-1,10"),
                     ("--type", "中文"), ("--key", "cmd+bogus"), ("--wat",),
                     ("--type", ""), ("--move",), ("--type", "\x1b")]:
            with self.subTest(args=args):
                result = run("--move", "50,50", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Connected", result.stdout)
                self.assertNotIn("SEND:", result.stdout)

    def test_whitespace_and_long_text_survive_firmware_line_protocol(self):
        self.assertEqual(self.plan("--type", " Hi \n\t "),
                         ["type  Hi", "key space", "key enter", "key tab", "key space"])
        commands = self.plan("--type", "a" * 40)
        self.assertEqual(commands, ["type " + "a" * 14, "type " + "a" * 14, "type " + "a" * 12])
        self.assertTrue(all(len(c.encode()) + 1 <= 20 for c in commands))

    def test_help_and_empty_invocation_are_local(self):
        result = run()
        self.assertEqual(result.returncode, 0)
        self.assertIn("--help", result.stdout)
        self.assertNotIn("Connected", result.stdout)

    def test_option_like_text_is_typed_literally(self):
        self.assertEqual(self.plan("--type", "--help", "--type", "-h"), ["type --help", "type -h"])


if __name__ == "__main__":
    unittest.main()
