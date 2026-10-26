"""history.sqlite3 的損毀復原與每週備份（ADR-0014 D-1）。"""
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from datetime import datetime
from pathlib import Path
from unittest import mock

from usage_collector import history, history_care

from .test_history import DAY, T0, snapshot


def corrupt_pages(path: Path) -> None:
    """標頭完好、內容頁被寫壞（SQLite 打得開，quick_check 回報錯誤）"""
    data = bytearray(path.read_bytes())
    page = 4096
    for start in range(2 * page, len(data) - page, page):
        data[start + 8:start + 200] = b"\xff" * 192
    path.write_bytes(bytes(data))


class CareTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.path = self.dir / "history.sqlite3"
        self.err = io.StringIO()
        patch = mock.patch.object(history, "HISTORY_PATH", self.path)
        patch.start()
        self.addCleanup(patch.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def record(self, n=1, now=T0):
        results = []
        with redirect_stderr(self.err), mock.patch.object(history.time, "time", return_value=now):
            for _ in range(n):
                results.append(history.record_safely(snapshot(now)))
        return results

    def count(self, table, path=None):
        conn = sqlite3.connect(path or self.path)
        try:
            return conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        finally:
            conn.close()

    def kept(self):
        return sorted(p.name for p in self.dir.glob("history.corrupt-*"))


class CheckTest(CareTestCase):
    def test_healthy_database_is_ok(self):
        history.record(snapshot(T0), self.path)
        self.assertEqual(history_care.check(self.path), "ok")

    def test_not_a_database_and_damaged_pages_are_corrupt(self):
        self.path.write_bytes(b"this is not a sqlite database at all" * 200)
        self.assertEqual(history_care.check(self.path), "corrupt")
        self.path.unlink()
        conn = history.connect(self.path)
        conn.execute("CREATE TABLE filler (x TEXT)")
        conn.executemany("INSERT INTO filler VALUES (?)", [("x" * 500,)] * 400)
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        conn.close()
        corrupt_pages(self.path)
        self.assertEqual(history_care.check(self.path), "corrupt")

    def test_locked_or_missing_is_not_evidence(self):
        self.assertEqual(history_care.check(self.path), "unknown")  # 不存在：也不會建立
        self.assertFalse(self.path.exists())
        history.record(snapshot(T0), self.path)
        with mock.patch.object(history_care.sqlite3, "connect",
                               side_effect=sqlite3.OperationalError("database is locked")):
            self.assertEqual(history_care.check(self.path), "unknown")


class RecoveryTest(CareTestCase):
    def test_corrupt_file_is_kept_and_replaced_after_an_hour_of_failures(self):
        self.path.write_bytes(b"this is not a sqlite database at all" * 200)
        self.assertEqual(self.record(history_care.RECOVER_AFTER - 1), [False] * (history_care.RECOVER_AFTER - 1))
        self.assertEqual(self.kept(), [])
        # 第 12 輪：quick_check 也失敗 → 改名保留，這一輪就寫進新檔
        self.assertEqual(self.record(), [True])
        stamp = datetime.fromtimestamp(T0).strftime("%Y%m%d-%H%M%S")
        self.assertEqual(self.kept(), [f"history.corrupt-{stamp}.sqlite3"])
        self.assertEqual(self.count("collector_runs"), 1)
        self.assertFalse((self.dir / history_care.FAILURES_FILE).exists())
        self.assertEqual(json.loads((self.dir / history_care.RECOVERED_FILE).read_text()),
                         {"at": T0, "kept_as": f"history.corrupt-{stamp}.sqlite3"})
        self.assertIn("改名保留為 history.corrupt-", self.err.getvalue())
        self.assertNotIn(self.tmp.name, self.err.getvalue())  # 只記檔名，不記路徑

    def test_wal_and_shm_go_with_the_kept_file(self):
        for suffix in ("", "-wal", "-shm"):
            Path(f"{self.path}{suffix}").write_bytes(suffix.encode() or b"db")
        name = history_care.quarantine(self.path, T0)
        self.assertEqual(self.kept(), [name, f"{name}-shm", f"{name}-wal"])
        self.assertEqual((self.dir / f"{name}-wal").read_bytes(), b"-wal")
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), self.kept())

    def test_a_wal_that_cannot_move_is_deleted(self):
        for suffix in ("", "-wal"):
            Path(f"{self.path}{suffix}").write_bytes(b"x")
        real = os.replace

        def replace(src, dst):
            if str(src).endswith("-wal"):
                raise PermissionError
            return real(src, dst)
        with mock.patch.object(history_care.os, "replace", side_effect=replace):
            history_care.quarantine(self.path, T0)
        self.assertFalse(Path(f"{self.path}-wal").exists())  # 留在原位會被套用到新檔上

    def test_a_locked_but_healthy_database_is_never_renamed(self):
        history.record(snapshot(T0), self.path)
        with mock.patch.object(history, "record", side_effect=sqlite3.OperationalError("database is locked")):
            self.assertEqual(set(self.record(history_care.RECOVER_AFTER * 2)), {False})
        self.assertEqual(self.kept(), [])
        self.assertEqual(json.loads((self.dir / history_care.FAILURES_FILE).read_text())["count"],
                         history_care.RECOVER_AFTER * 2)

    def test_a_success_resets_the_count(self):
        history.record(snapshot(T0), self.path)
        with mock.patch.object(history, "record", side_effect=sqlite3.DatabaseError("boom")), \
             mock.patch.object(history_care, "check", return_value="corrupt"):
            self.record(history_care.RECOVER_AFTER - 1)
        self.record()  # 成功：歸零
        self.assertFalse((self.dir / history_care.FAILURES_FILE).exists())
        with mock.patch.object(history, "record", side_effect=sqlite3.DatabaseError("boom")), \
             mock.patch.object(history_care, "check", return_value="corrupt") as check:
            self.record(history_care.RECOVER_AFTER - 1)
        check.assert_not_called()
        self.assertEqual(self.kept(), [])

    def test_keeps_at_most_two_corrupt_copies(self):
        for i in range(3):
            self.path.write_bytes(b"garbage" * 1000)
            Path(f"{self.path}-shm").write_bytes(b"shm")
            self.record(history_care.RECOVER_AFTER, now=T0 + i * DAY)
            self.path.unlink()
            for side in ("-wal", "-shm"):
                Path(f"{self.path}{side}").unlink(missing_ok=True)
        days = [datetime.fromtimestamp(T0 + i * DAY).strftime("%Y%m%d") for i in (1, 2)]
        self.assertEqual([n[16:24] for n in self.kept()], [days[0], days[0], days[1], days[1]])

    def test_rename_failure_is_logged_and_retried_later(self):
        self.path.write_bytes(b"garbage" * 1000)
        real = os.replace

        def replace(src, dst):
            if Path(src) == self.path:
                raise PermissionError
            return real(src, dst)
        with mock.patch.object(history_care.os, "replace", side_effect=replace):
            self.record(history_care.RECOVER_AFTER)
        self.assertTrue(self.path.exists())
        self.assertIn("無法改名（PermissionError）", self.err.getvalue())
        self.record(history_care.RECOVER_AFTER)  # 下一個 12 輪再試
        self.assertEqual(len(self.kept()), 1)

    def test_tokens_only_counts_failures_through_tidy(self):
        self.path.write_bytes(b"garbage" * 1000)
        with redirect_stderr(self.err):
            for _ in range(history_care.RECOVER_AFTER):
                self.assertFalse(history.tidy_safely())
        self.assertEqual(len(self.kept()), 1)
        self.assertFalse(self.path.exists())  # Token 統計下一輪建立新檔

    def test_notice_lasts_seven_days(self):
        (self.dir / history_care.RECOVERED_FILE).write_text(json.dumps({"at": T0, "kept_as": "history.corrupt-x.sqlite3"}))
        self.assertEqual(history_care.notice(self.dir, T0 + 6 * DAY),
                         {"history_reset_at": "2026-09-21T14:13:20Z", "history_kept_as": "history.corrupt-x.sqlite3"})
        self.assertIsNone(history_care.notice(self.dir, T0 + 7 * DAY))
        self.assertIsNone(history_care.notice(self.dir, T0 - DAY))
        (self.dir / history_care.RECOVERED_FILE).write_text("{broken")
        self.assertIsNone(history_care.notice(self.dir, T0))


class BackupTest(CareTestCase):
    def cleanup(self, now):
        conn = history.connect(self.path)
        try:
            with redirect_stderr(self.err):
                history.maybe_cleanup(conn, now, datetime.fromtimestamp(now).date())
        finally:
            conn.close()

    def backups(self):
        return sorted(p.name for p in (self.dir / "backups").iterdir())

    def test_weekly_backup_keeps_the_latest_two(self):
        history.record(snapshot(T0), self.path, now=datetime.fromtimestamp(T0).astimezone())
        day = lambda ts: datetime.fromtimestamp(ts).strftime("%Y%m%d")  # noqa: E731
        self.assertEqual(self.backups(), [f"history-{day(T0)}.sqlite3"])
        self.cleanup(T0 + 3 * DAY)  # 不到 7 天
        self.assertEqual(self.backups(), [f"history-{day(T0)}.sqlite3"])
        for n in (7, 14):
            self.cleanup(T0 + n * DAY)
        self.assertEqual(self.backups(), [f"history-{day(T0 + 7 * DAY)}.sqlite3", f"history-{day(T0 + 14 * DAY)}.sqlite3"])
        copy = self.dir / "backups" / self.backups()[-1]
        self.assertEqual(self.count("collector_runs", copy), 1)
        conn = sqlite3.connect(copy)
        try:
            self.assertEqual(conn.execute("PRAGMA journal_mode").fetchone()[0], "delete")  # 單一檔案
        finally:
            conn.close()
        self.assertFalse(Path(f"{copy}-wal").exists())

    def test_leftovers_from_a_killed_backup_are_removed(self):
        (self.dir / "backups").mkdir()
        (self.dir / "backups" / ".history-20260101.tmp").write_bytes(b"x")
        (self.dir / "backups" / ".history-20260101.tmp-journal").write_bytes(b"x")
        history.record(snapshot(T0), self.path)
        self.assertEqual(len(self.backups()), 1)
        self.assertTrue(self.backups()[0].startswith("history-"))

    def test_failure_is_only_logged_and_retried(self):
        (self.dir / "backups").write_text("a file where the folder should be")
        self.assertEqual(self.record(), [True])  # 收集照常
        self.assertIn("每週備份 history.sqlite3 失敗（FileExistsError）", self.err.getvalue())
        conn = history.connect(self.path)
        try:
            self.assertIsNone(history.meta(conn, "last_backup_at"))
        finally:
            conn.close()
        (self.dir / "backups").unlink()
        self.cleanup(T0 + DAY)  # 隔天再試
        self.assertEqual(len(self.backups()), 1)

    def test_skipped_when_the_disk_would_run_low(self):
        with mock.patch.object(history_care.disk, "free_bytes", return_value=history_care.disk.LOW_DISK_BYTES + 1000):
            self.assertEqual(self.record(), [True])
        self.assertEqual(self.backups(), [])
        self.assertIn("略過每週備份", self.err.getvalue())

    def test_a_backup_that_fails_quick_check_is_not_kept(self):
        history.record(snapshot(T0), self.path)
        with mock.patch.object(history_care, "_intact", return_value=False):
            self.cleanup(T0 + 8 * DAY)
        self.assertEqual(len(self.backups()), 1)  # 只有第一次的
        self.assertIn("沒有通過 quick_check", self.err.getvalue())

    def test_clock_in_the_future_is_due(self):
        history.record(snapshot(T0), self.path)
        conn = history.connect(self.path)
        conn.execute("UPDATE meta SET value = ? WHERE key = 'last_backup_at'", (str(T0 + 100 * DAY),))
        conn.close()
        self.cleanup(T0 + DAY)
        self.assertEqual(len(self.backups()), 2)

    @unittest.skipIf(sys.platform == "win32", "Windows 沒有 POSIX 權限位元")
    def test_backup_files_are_private(self):
        old = os.umask(0o022)
        try:
            history.record(snapshot(T0), self.path)
        finally:
            os.umask(old)
        folder = self.dir / "backups"
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        for p in folder.iterdir():
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)


class LocalStatusTest(CareTestCase):
    def test_notice_goes_into_local_status(self):
        from .test_disk import CollectorTest
        (self.dir / history_care.RECOVERED_FILE).write_text(json.dumps({"at": T0, "kept_as": "history.corrupt-x.sqlite3"}))
        case = CollectorTest()
        case.dir = self.dir
        with mock.patch("usage_collector.__main__.time.time", return_value=T0 + DAY), \
             mock.patch.object(history_care.disk, "free_bytes", return_value=10**12):
            code, upload, *_ = case.run_cli("--write-local", "--upload")
        self.assertEqual(code, 0)
        local = json.loads(case.usage.read_text(encoding="utf-8"))["local_status"]
        self.assertEqual(local, {"history_reset_at": "2026-09-21T14:13:20Z", "history_kept_as": "history.corrupt-x.sqlite3"})
        self.assertNotIn("local_status", upload.call_args.args[0])


if __name__ == "__main__":
    unittest.main()

