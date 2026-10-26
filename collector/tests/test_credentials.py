"""貼上密鑰時的格式檢查（BACKLOG 第 10 節）：當場提示貼錯，不必等上傳被拒兩次才知道。"""
from __future__ import annotations

import io
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

from usage_collector import credentials

DEVICE = "aumd_" + "A1b2-C3d4_" * 4 + "xyz"
READ = "RL4aesydLJXpCzwcEsNc7WDCww9cZEf6RVTmmGY5G2I="  # openssl rand -base64 32
READ_URL = "Zm9vYmFyYmF6cXV4cXV1eGNvcmdlZ3JhdWx0Z2FycGx5"  # setup-relay.sh 的 base64url


class NormalizeTests(unittest.TestCase):
    def test_device_key_is_trimmed(self):
        self.assertEqual(len(DEVICE), credentials.DEVICE_KEY_LENGTH)
        for raw in (DEVICE, f"  {DEVICE}\r\n", f"\t{DEVICE}\n", f"　{DEVICE}　"):
            self.assertEqual(credentials.normalize(credentials.DEVICE_KEY, raw), DEVICE)

    def test_device_key_errors(self):
        cases = {
            "": "沒有輸入密鑰",
            "   \r\n": "沒有輸入密鑰",
            DEVICE[:-1]: "應為 48 個字元，貼上的是 47 個",
            DEVICE + "x": "應為 48 個字元，貼上的是 49 個",
            READ: "應以 aumd_ 開頭",
            "aumd_" + "!" * 43: "不該出現的字元",
            DEVICE[:20] + " " + DEVICE[21:]: "不該出現的字元",
        }
        for raw, message in cases.items():
            with self.subTest(raw=raw), self.assertRaises(credentials.KeyFormatError) as ctx:
                credentials.normalize(credentials.DEVICE_KEY, raw)
            self.assertIn(message, str(ctx.exception))
            if raw.strip():
                self.assertNotIn(raw.strip(), str(ctx.exception))  # 提示不含密鑰本身

    def test_read_key_accepts_both_generators(self):
        for raw in (READ, READ_URL, f" {READ}\r\n"):
            self.assertEqual(credentials.normalize(credentials.READ_KEY, raw), raw.strip())

    def test_read_key_errors(self):
        cases = {
            DEVICE: "這是裝置的寫入密鑰",
            "short": "太短",
            READ[:10] + " " + READ[10:]: "中間有空白",
            READ + '"': "不該出現的字元",
            READ + ";rm": "不該出現的字元",
        }
        for raw, message in cases.items():
            with self.subTest(raw=raw), self.assertRaises(credentials.KeyFormatError) as ctx:
                credentials.normalize(credentials.READ_KEY, raw)
            self.assertIn(message, str(ctx.exception))


class MainTests(unittest.TestCase):
    def test_check_prints_the_trimmed_key(self):
        out = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO(f"  {DEVICE}\r\n")), redirect_stdout(out):
            self.assertEqual(credentials.main(["check", credentials.DEVICE_KEY]), 0)
        self.assertEqual(out.getvalue(), DEVICE + "\n")

    def test_check_fails_with_a_hint(self):
        err = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO("aumd_short\n")), redirect_stderr(err), redirect_stdout(io.StringIO()):
            self.assertEqual(credentials.main(["check", credentials.DEVICE_KEY]), 1)
        self.assertIn("應為 48 個字元", err.getvalue())

    def test_store_prompts_again_until_the_format_is_right(self):
        err = io.StringIO()
        with mock.patch.object(credentials, "_prompt", side_effect=[DEVICE[:-2], DEVICE]), \
                mock.patch.object(credentials, "store") as store, redirect_stderr(err), redirect_stdout(io.StringIO()):
            self.assertEqual(credentials.main(["store", credentials.DEVICE_KEY]), 0)
        store.assert_called_once_with(credentials.DEVICE_KEY, DEVICE)
        self.assertIn("請重新貼上", err.getvalue())

    def test_store_gives_up_after_three_tries(self):
        err = io.StringIO()
        with mock.patch.object(credentials, "_prompt", side_effect=["a", "b", "c"]), \
                mock.patch.object(credentials, "store") as store, redirect_stderr(err):
            self.assertEqual(credentials.main(["store", credentials.READ_KEY]), 1)
        store.assert_not_called()
        self.assertEqual(err.getvalue().count("請重新貼上"), 2)

    def test_has_reports_without_printing_the_key(self):
        out = io.StringIO()
        with mock.patch.object(credentials, "read", side_effect=[DEVICE, None]), redirect_stdout(out):
            self.assertEqual(credentials.main(["has", credentials.DEVICE_KEY]), 0)
            self.assertEqual(credentials.main(["has", credentials.READ_KEY]), 1)
        self.assertEqual(out.getvalue(), "")

    def test_store_read_key(self):
        with mock.patch.object(credentials, "_prompt", return_value=READ + "\n"), \
                mock.patch.object(credentials, "store") as store, redirect_stdout(io.StringIO()):
            self.assertEqual(credentials.main(["store", credentials.READ_KEY]), 0)
        store.assert_called_once_with(credentials.READ_KEY, READ)

    def test_store_reads_a_line_when_stdin_is_not_a_console(self):
        with mock.patch("sys.stdin", io.StringIO(f"{DEVICE}\r\n")), \
                mock.patch.object(credentials, "store") as store, redirect_stdout(io.StringIO()):
            self.assertEqual(credentials.main(["store", credentials.DEVICE_KEY]), 0)
        store.assert_called_once_with(credentials.DEVICE_KEY, DEVICE)


@unittest.skipUnless(sys.platform == "win32", "Windows 認證管理員")
class WindowsCredentialManagerTests(unittest.TestCase):
    """實際寫入、讀回、刪除（測試用的名稱，不碰 AIUsageMonitor/device-key 等真的項目）"""

    def test_round_trip(self):
        with mock.patch.object(credentials, "target", side_effect=lambda n: f"AIUsageMonitorTest/{n}"):
            credentials.delete(credentials.READ_KEY)
            self.assertIsNone(credentials.read(credentials.READ_KEY))
            credentials.store(credentials.READ_KEY, READ)
            self.assertEqual(credentials.read(credentials.READ_KEY), READ)
            credentials.delete(credentials.READ_KEY)
            self.assertIsNone(credentials.read(credentials.READ_KEY))


if __name__ == "__main__":
    unittest.main()
