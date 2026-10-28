import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from usage_collector import history, level

REMOTE = "33333333-3333-4333-8333-333333333333"


class LevelDaysTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.path = self.dir / "history.sqlite3"
        self.conn = history.connect(self.path)
        self.addCleanup(lambda: self.conn.close())
        self.local = history.meta(self.conn, "device_id")

    def record(self, day, provider, tokens):
        self.conn.execute("INSERT OR REPLACE INTO record_days (day, provider, tokens) VALUES (?, ?, ?)", (day, provider, tokens))

    def daily(self, device, day, model, input_tokens, cache_write=0, cache_read=0, output=0):
        self.conn.execute(
            """INSERT OR REPLACE INTO daily_tokens (device_id, day, provider, model, input_tokens, cache_write_tokens,
               cache_read_tokens, output_tokens, updated_at) VALUES (?, ?, 'claude', ?, ?, ?, ?, ?, 0)""",
            (device, day, model, input_tokens, cache_write, cache_read, output))

    def days(self):
        return dict(self.conn.execute("SELECT day, tokens FROM level_days ORDER BY day").fetchall())

    def test_merges_this_computer_and_others_without_counting_local_rows_twice(self):
        self.record("2026-10-28", "claude", 100)
        self.record("2026-10-28", "codex", 50)
        # 本機的每日資料和 record_days 是同一份：不重複計算
        self.daily(self.local, "2026-10-28", "m", 100)
        # 其他電腦：主數字 = input + cache_write + output，不含 cache_read
        self.daily(REMOTE, "2026-10-28", "m", 10, cache_write=5, cache_read=1000, output=7)
        self.daily(REMOTE, "2026-10-27", "m", 3)
        self.daily(REMOTE, "2026-10-26", "m", 0)
        level.update(self.conn)
        self.assertEqual({"2026-10-27": 3, "2026-10-28": 172}, self.days())

    def test_never_decreases(self):
        self.record("2026-10-28", "claude", 100)
        self.daily(REMOTE, "2026-10-28", "m", 50)
        self.daily(REMOTE, "2026-10-01", "m", 9)
        level.update(self.conn)
        # 保留期間清掉、其他電腦的列被取代、Codex 重算變小
        self.conn.execute("DELETE FROM daily_tokens")
        self.record("2026-10-28", "claude", 40)
        level.update(self.conn)
        self.assertEqual({"2026-10-01": 9, "2026-10-28": 150}, self.days())
        # 變大時跟著變大
        self.record("2026-10-28", "claude", 400)
        level.update(self.conn)
        self.assertEqual(400, self.days()["2026-10-28"])

    @unittest.skipIf(sys.platform == "win32", "POSIX 權限")
    def test_loose_permissions_are_tightened_or_nothing_is_written(self):
        self.record("2026-10-28", "claude", 100)
        self.conn.close()
        os.chmod(self.path, 0o644)
        level.update_safely(self.path)
        self.assertEqual(0o600, self.path.stat().st_mode & 0o777)
        self.conn = history.connect(self.path)
        self.assertEqual({"2026-10-28": 100}, self.days())
        # 收不了：不寫，日誌不含路徑
        self.conn.execute("DELETE FROM level_days")
        self.conn.close()
        os.chmod(self.path, 0o644)
        with mock.patch("usage_collector.history.os.chmod", side_effect=OSError("/Users/me")), \
                mock.patch("usage_collector.level.log") as log:
            level.update_safely(self.path)
        self.assertNotIn("/Users", log.call_args.args[0])
        os.chmod(self.path, 0o600)
        self.conn = history.connect(self.path)
        self.assertEqual({}, self.days())

    def test_table_exists_after_connect_and_never_raises(self):
        self.assertEqual({}, self.days())
        with mock.patch("usage_collector.level.update", side_effect=RuntimeError("boom /Users/me")), \
                mock.patch("usage_collector.level.log") as log:
            level.update_safely(self.path)
        self.assertEqual("略過等級資料：RuntimeError", log.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
