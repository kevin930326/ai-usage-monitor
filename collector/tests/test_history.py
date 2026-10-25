import io
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from datetime import date, datetime, timezone
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector import history, local_store, relay
from usage_collector.models import ProviderUsage, Window

T0 = 1_790_000_000  # 2026-09-21，整點以外的時間
HOUR = 3600
DAY = 86400
# 不能讀到這台電腦真的對話紀錄：呼叫 cli.main(--write-local) 的測試一律指到不存在的資料夾
NO_LOGS = {"claude": Path("/nonexistent/claude"), "codex": Path("/nonexistent/codex")}


def iso(ts: int) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def snapshot(ts: int, claude_used=10.0, codex_error=None, resets=T0 + 5 * HOUR) -> dict:
    return {
        "schema_version": 1,
        "updated_at": iso(ts),
        "providers": {
            "claude": {"plan": "Max", "error": None, "windows": [
                {"id": "five_hour", "label": "5 小時", "used_pct": claude_used, "resets_at": iso(resets), "hidden": False},
                {"id": "weekly", "label": "每週", "used_pct": 40.0, "resets_at": None, "hidden": False},
            ]},
            "codex": {"plan": "Plus", "error": codex_error, "windows": [] if codex_error else [
                {"id": "five_hour", "label": "5 小時", "used_pct": 3.0, "resets_at": iso(resets), "hidden": False},
            ]},
        },
    }


class HistoryTestCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "history.sqlite3"

    def tearDown(self):
        self.dir.cleanup()

    @contextmanager
    def db(self):
        # `with sqlite3.connect()` 只 commit 不關閉；Python 3.13 對沒關的連線發 ResourceWarning
        conn = sqlite3.connect(self.path)
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def count(self, table: str) -> int:
        with self.db() as c:
            return c.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]


class SchemaTest(HistoryTestCase):
    def test_creates_tables_and_meta(self):
        history.record(snapshot(T0), self.path, now=datetime.fromtimestamp(T0, timezone.utc))
        with self.db() as c:
            tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
            meta = dict(c.execute("SELECT key, value FROM meta"))
            mode = c.execute("PRAGMA journal_mode").fetchone()[0]
        self.assertTrue({"quota_samples", "collector_runs", "meta", "daily_tokens", "seen_ids"} <= tables)
        self.assertEqual(meta["schema_version"], str(history.SCHEMA_VERSION))
        self.assertEqual(meta["retention_days"], "365")
        self.assertEqual(meta["device_name"], "這台 Mac")
        self.assertRegex(meta["device_id"], r"^[0-9a-f-]{36}$")
        self.assertEqual(mode, "wal")

    def test_reopening_keeps_device_id_and_settings(self):
        history.record(snapshot(T0), self.path)
        with self.db() as c:
            device = history.meta(c, "device_id")
            c.execute("UPDATE meta SET value = '30' WHERE key = 'retention_days'")
        history.record(snapshot(T0 + 300), self.path)
        with self.db() as c:
            self.assertEqual(history.meta(c, "device_id"), device)
            self.assertEqual(history.meta(c, "retention_days"), "30")

    def test_migrates_from_empty_file_and_partial_meta(self):
        # 版本 0：只有 meta 表（例如舊的實驗版本），缺的鍵補上、已有的不覆蓋
        with self.db() as c:
            c.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
            c.execute("INSERT INTO meta VALUES ('retention_days', '7')")
        conn = history.connect(self.path)
        self.assertEqual(history.schema_version(conn), history.SCHEMA_VERSION)
        self.assertEqual(history.meta(conn, "retention_days"), "7")
        self.assertIsNotNone(history.meta(conn, "device_id"))
        conn.close()

    def test_prerelease_v2_without_record_days_is_repaired(self):
        # 開發中的版本 2 沒有 record_days：重新開啟時補建，並以這台 Mac 的每日資料回填
        conn = history.connect(self.path)
        device = history.meta(conn, "device_id")
        conn.execute("DROP TABLE record_days")
        rows = [(device, "2026-09-20", "claude", "m", 10, 20, 999, 30), (device, "2026-09-20", "claude", "n", 1, 0, 0, 1),
                (device, "2026-09-21", "codex", "m", 5, 0, 0, 5), ("other-mac", "2026-09-20", "claude", "m", 100, 0, 0, 0)]
        conn.executemany("INSERT INTO daily_tokens (device_id, day, provider, model, input_tokens, cache_write_tokens,"
                         " cache_read_tokens, output_tokens, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)", rows)
        conn.close()
        conn = history.connect(self.path)
        self.assertEqual(conn.execute("SELECT day, provider, tokens FROM record_days ORDER BY day").fetchall(),
                         [("2026-09-20", "claude", 62), ("2026-09-21", "codex", 10)])
        conn.close()
        # 已經有 record_days：不再回填（之後的掃描自己累加）
        with self.db() as c:
            c.execute("UPDATE record_days SET tokens = 1")
        history.connect(self.path).close()
        with self.db() as c:
            self.assertEqual({r[0] for r in c.execute("SELECT tokens FROM record_days")}, {1})

    def test_newer_schema_is_left_untouched(self):
        with self.db() as c:
            c.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
            c.execute("INSERT INTO meta VALUES ('schema_version', '99')")
        with self.assertRaises(history.HistoryError):
            history.connect(self.path)
        with self.db() as c:
            tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertEqual(tables, {"meta"})

    def test_newer_schema_keeps_journal_mode_and_bytes(self):
        with self.db() as c:
            c.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
            c.execute("INSERT INTO meta VALUES ('schema_version', '99')")
        before = self.path.read_bytes()
        with self.assertRaises(history.HistoryError):
            history.connect(self.path)
        self.assertEqual(self.path.read_bytes(), before)
        with self.db() as c:
            self.assertEqual(c.execute("PRAGMA journal_mode").fetchone()[0], "delete")

    def test_failed_migration_rolls_back(self):
        def broken(conn):
            history._v1(conn)
            raise RuntimeError("boom")
        with mock.patch.object(history, "MIGRATIONS", [broken]), self.assertRaises(RuntimeError):
            history.connect(self.path)
        with self.db() as c:
            tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertEqual(tables, set())

    @unittest.skipIf(sys.platform == "win32", "Windows 沒有 POSIX 權限位元")
    def test_files_are_private(self):
        history.record(snapshot(T0), self.path)
        for p in Path(self.dir.name).iterdir():
            self.assertEqual(p.stat().st_mode & 0o777, 0o600, p.name)

    @unittest.skipIf(sys.platform == "win32", "Windows 沒有 POSIX 權限位元")
    def test_existing_loose_permissions_are_tightened(self):
        history.record(snapshot(T0), self.path)
        os.chmod(self.path, 0o644)
        history.record(snapshot(T0 + 300), self.path)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)


    @unittest.skipIf(sys.platform == "win32", "Windows 沒有 POSIX 權限位元")
    def test_permissions_are_fixed_before_writing(self):
        history.record(snapshot(T0), self.path)
        os.chmod(self.path, 0o644)
        seen = []
        real_connect = history.connect
        def spy(path):
            seen.append(path.stat().st_mode & 0o777)
            return real_connect(path)
        with mock.patch.object(history, "connect", spy):
            history.record(snapshot(T0 + 300), self.path)
        self.assertEqual(seen, [0o600])

    @unittest.skipIf(sys.platform == "win32", "Windows 沒有 POSIX 權限位元")
    def test_unfixable_permissions_skip_the_write(self):
        history.record(snapshot(T0), self.path)
        os.chmod(self.path, 0o644)
        err = io.StringIO()
        with mock.patch.object(history.os, "chmod", side_effect=PermissionError), redirect_stderr(err):
            self.assertFalse(history.record_safely(snapshot(T0 + 300), self.path))
        os.chmod(self.path, 0o600)
        self.assertEqual(self.count("collector_runs"), 1)
        self.assertIn("0600", err.getvalue())


class WriteTest(HistoryTestCase):
    def test_one_run_and_one_sample_per_window_skipping_errors(self):
        n = history.record(snapshot(T0, codex_error="尚未登入"), self.path)
        self.assertEqual(n, 2)
        with self.db() as c:
            rows = c.execute("SELECT ts, provider, window_id, used_pct, resets_at FROM quota_samples"
                             " ORDER BY window_id").fetchall()
            runs = c.execute("SELECT ts, ok, runs FROM collector_runs").fetchall()
        self.assertEqual(rows, [(T0, "claude", "five_hour", 10.0, T0 + 5 * HOUR), (T0, "claude", "weekly", 40.0, None)])
        self.assertEqual(runs, [(T0, 1, 1)])

    def test_run_with_all_providers_failing_is_recorded_as_not_ok(self):
        snap = {"updated_at": iso(T0), "providers": {"claude": {"error": "x", "windows": []}}}
        history.record(snap, self.path)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT ok FROM collector_runs").fetchone()[0], 0)
        self.assertEqual(self.count("quota_samples"), 0)

    def test_only_numbers_and_ids_are_stored(self):
        snap = snapshot(T0)
        snap["providers"]["claude"]["plan"] = "SECRET-PLAN"
        snap["providers"]["claude"]["windows"][0]["label"] = "SECRET-LABEL"
        history.record(snap, self.path)
        self.assertNotIn(b"SECRET", self.path.read_bytes() + Path(f"{self.path}-wal").read_bytes()
                         if Path(f"{self.path}-wal").exists() else self.path.read_bytes())

    def test_reset_is_visible_from_samples(self):
        # 重置判斷由 App 從樣本推得：resets_at 改變或 used_pct 下降（ADR-0009 第 4 節）。
        # 收集器要原樣保存兩者，App 才能判斷
        history.record(snapshot(T0, claude_used=80, resets=T0 + 600), self.path)
        history.record(snapshot(T0 + 900, claude_used=2, resets=T0 + 600 + 5 * HOUR), self.path)
        with self.db() as c:
            rows = c.execute("SELECT used_pct, resets_at FROM quota_samples WHERE provider = 'claude'"
                             " AND window_id = 'five_hour' ORDER BY ts").fetchall()
        self.assertEqual(rows, [(80.0, T0 + 600), (2.0, T0 + 600 + 5 * HOUR)])


class CleanupTest(HistoryTestCase):
    def fill(self, start: int, end: int, step: int = 300):
        conn = history.connect(self.path)
        for ts in range(start, end, step):
            history.write_samples(conn, snapshot(ts))
        return conn

    def test_downsamples_older_than_35_days_to_hourly(self):
        now = T0 + 40 * DAY
        hour0 = (T0 // HOUR + 1) * HOUR  # 從整點開始，方便數
        conn = self.fill(hour0, hour0 + 3 * HOUR)            # 舊資料：3 小時 × 12 筆
        recent = now - 2 * HOUR
        for ts in range(recent, recent + HOUR, 300):          # 新資料：維持 5 分鐘
            history.write_samples(conn, snapshot(ts))
        history.cleanup(conn, now)
        old_samples = conn.execute("SELECT ts FROM quota_samples WHERE provider = 'claude' AND window_id = 'five_hour'"
                                   " AND ts < ? ORDER BY ts", (now - 35 * DAY,)).fetchall()
        self.assertEqual([r[0] for r in old_samples], [hour0 + 55 * 60, hour0 + HOUR + 55 * 60, hour0 + 2 * HOUR + 55 * 60])
        old_runs = conn.execute("SELECT ts, ok, runs FROM collector_runs WHERE ts < ? ORDER BY ts",
                                (now - 35 * DAY,)).fetchall()
        self.assertEqual(old_runs, [(hour0 + h * HOUR + 55 * 60, 12, 12) for h in range(3)])
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM collector_runs WHERE ts >= ?", (recent,)).fetchone()[0], 12)
        # 再跑一次結果不變
        history.cleanup(conn, now)
        self.assertEqual(conn.execute("SELECT SUM(runs) FROM collector_runs WHERE ts < ?", (now - 35 * DAY,)).fetchone()[0], 36)
        conn.close()

    def test_clock_jumping_ahead_does_not_wipe_history(self):
        """時鐘被設到兩年後（ADR-0014 LT-11）：一次清理只前進 2 天，保留期間（1 年）內的資料不會被刪光；
        改回正確時間後照常。"""
        conn = self.fill(T0 - 300 * DAY, T0, step=DAY)
        history.cleanup(conn, T0)
        before = conn.execute("SELECT COUNT(*) FROM quota_samples").fetchone()[0]
        history.cleanup(conn, T0 + 730 * DAY)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM quota_samples").fetchone()[0], before)
        self.assertEqual(history.meta(conn, "cleanup_clock"), str(T0 + 2 * DAY))
        history.cleanup(conn, T0 + DAY)  # 改回來：用現在的時間
        self.assertEqual(history.meta(conn, "cleanup_clock"), str(T0 + DAY))
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM quota_samples").fetchone()[0], before)
        conn.close()

    def test_clock_jumping_ahead_right_after_upgrading_does_not_wipe_history(self):
        """升級前的資料庫沒有 cleanup_clock：以 last_cleanup_day 當基準，第一次清理遇到時鐘超前兩年也不刪光（審查 C-02）。"""
        conn = self.fill(T0 - 300 * DAY, T0, step=DAY)
        history.cleanup(conn, T0)
        before = conn.execute("SELECT COUNT(*) FROM quota_samples").fetchone()[0]
        conn.execute("DELETE FROM meta WHERE key = 'cleanup_clock'")
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_cleanup_day', ?)", (history.local_day(T0),))
        history.cleanup(conn, T0 + 730 * DAY)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM quota_samples").fetchone()[0], before)
        self.assertLessEqual(int(history.meta(conn, "cleanup_clock")), T0 + 3 * DAY)
        history.cleanup(conn, T0 + DAY)  # 改回來
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM quota_samples").fetchone()[0], before)
        conn.close()

    def test_daily_cleanups_catch_up_after_a_long_pause(self):
        conn = self.fill(T0, T0 + HOUR)
        history.cleanup(conn, T0)
        later = T0 + 400 * DAY  # 收集器停了 400 天：每天的清理各前進 2 天，最後追上
        for day in range(400):
            history.cleanup(conn, later + day * DAY)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM quota_samples WHERE ts < ?", (T0 + HOUR,)).fetchone()[0], 0)
        self.assertEqual(history.meta(conn, "cleanup_clock"), str(later + 399 * DAY))
        conn.close()

    def test_downsampling_watermark_in_the_future_is_reset(self):
        now = T0 + 40 * DAY
        hour0 = (T0 // HOUR + 1) * HOUR
        conn = self.fill(hour0, hour0 + 2 * HOUR)
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('downsampled_before', ?)", (str(now + 3650 * DAY),))
        history.cleanup(conn, now)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM quota_samples WHERE provider = 'claude'"
                                      " AND window_id = 'five_hour'").fetchone()[0], 2)
        self.assertLessEqual(int(history.meta(conn, "downsampled_before")), now)
        conn.close()

    def test_retention_deletes_old_rows(self):
        now = T0 + 400 * DAY
        conn = self.fill(T0, T0 + HOUR)                       # 400 天前
        conn2_ts = now - 10 * DAY
        history.write_samples(conn, snapshot(conn2_ts))
        history.cleanup(conn, now)
        self.assertEqual([r[0] for r in conn.execute("SELECT DISTINCT ts FROM quota_samples")], [conn2_ts])
        self.assertEqual([r[0] for r in conn.execute("SELECT ts FROM collector_runs")], [conn2_ts])
        conn.close()

    def test_shorter_retention_from_meta(self):
        now = T0 + 20 * DAY
        conn = self.fill(T0, T0 + HOUR)
        conn.execute("UPDATE meta SET value = '7' WHERE key = 'retention_days'")
        history.cleanup(conn, now)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM quota_samples").fetchone()[0], 0)
        conn.close()

    def test_forever_keeps_everything_but_still_downsamples(self):
        now = T0 + 800 * DAY
        conn = self.fill(T0, T0 + HOUR // 2)
        conn.execute("UPDATE meta SET value = '0' WHERE key = 'retention_days'")
        history.cleanup(conn, now)
        self.assertGreater(conn.execute("SELECT COUNT(*) FROM collector_runs").fetchone()[0], 0)
        conn.close()

    def test_invalid_retention_falls_back_to_default(self):
        conn = history.connect(self.path)
        for bad in ("abc", "-5", ""):
            conn.execute("UPDATE meta SET value = ? WHERE key = 'retention_days'", (bad,))
            self.assertEqual(history.retention_days(conn), 365)
        conn.close()

    def test_cleanup_runs_once_per_local_day(self):
        conn = history.connect(self.path)
        with mock.patch.object(history, "cleanup") as cleanup:
            self.assertTrue(history.maybe_cleanup(conn, T0, date(2026, 9, 21)))
            self.assertFalse(history.maybe_cleanup(conn, T0 + 300, date(2026, 9, 21)))
            self.assertTrue(history.maybe_cleanup(conn, T0 + DAY, date(2026, 9, 22)))
        self.assertEqual(cleanup.call_count, 2)
        conn.close()


class VacuumTest(HistoryTestCase):
    """定期 VACUUM（ADR-0014 LT-14）：到期或可回收空間夠多才做，磁碟空間不夠時不做。"""

    def fill_and_delete(self, conn, rows=20000):
        conn.executemany("INSERT INTO seen_ids (provider, id, day, hour, model) VALUES ('claude', ?, '2026-01-01', 0, 'm')",
                         ((f"msg_{i:06d}_0123456789abcdef0123456789",) for i in range(rows)))
        conn.execute("DELETE FROM seen_ids")

    def size(self):
        return self.path.stat().st_size

    def test_vacuum_when_much_space_is_free(self):
        conn = history.connect(self.path)
        conn.execute("INSERT INTO meta (key, value) VALUES ('last_vacuum_at', ?)", (str(T0 - DAY),))
        self.fill_and_delete(conn)
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        before = self.size()
        with redirect_stderr(io.StringIO()) as err:
            self.assertTrue(history.maybe_vacuum(conn, T0))
        self.assertLess(self.size(), before / 2)
        self.assertEqual(conn.execute("PRAGMA freelist_count").fetchone()[0], 0)
        self.assertEqual(Path(f"{self.path}-wal").stat().st_size, 0)  # WAL 截斷
        self.assertIn("整理 history.sqlite3", err.getvalue())
        self.assertEqual(history.meta(conn, "last_vacuum_at"), str(T0))
        conn.close()

    def test_not_due_when_recent_and_little_to_reclaim(self):
        conn = history.connect(self.path)
        conn.execute("INSERT INTO meta (key, value) VALUES ('last_vacuum_at', ?)", (str(T0 - DAY),))
        self.assertFalse(history.maybe_vacuum(conn, T0))
        # 30 天到期；上次時間在未來（時鐘曾被設到未來）也算到期
        self.assertTrue(history.maybe_vacuum(conn, T0 + 31 * DAY))
        conn.execute("UPDATE meta SET value = ? WHERE key = 'last_vacuum_at'", (str(T0 + 400 * DAY),))
        self.assertTrue(history.maybe_vacuum(conn, T0 + 32 * DAY))
        conn.close()

    def test_skipped_when_the_disk_is_almost_full(self):
        conn = history.connect(self.path)
        self.fill_and_delete(conn)
        usage = mock.Mock(free=history.VACUUM_DISK_MARGIN)
        with mock.patch.object(history.shutil, "disk_usage", return_value=usage):
            self.assertFalse(history.maybe_vacuum(conn, T0))
        self.assertIsNone(history.meta(conn, "last_vacuum_at"))  # 隔天再試
        self.assertGreater(conn.execute("PRAGMA freelist_count").fetchone()[0], 0)
        conn.close()

    def test_daily_cleanup_vacuums_once_due(self):
        conn = history.connect(self.path)
        with mock.patch.object(history, "maybe_vacuum") as vacuum:
            history.maybe_cleanup(conn, T0, date(2026, 9, 21))
            history.maybe_cleanup(conn, T0 + 300, date(2026, 9, 21))
        self.assertEqual(vacuum.call_count, 1)
        conn.close()

    def test_vacuum_while_another_connection_reads(self):
        """App 開著讀取連線（WAL）：VACUUM 照常完成，讀取端之後讀到同樣的資料。"""
        conn = history.connect(self.path)
        conn.execute("INSERT INTO collector_runs (ts, ok, runs) VALUES (?, 1, 1)", (T0,))
        self.fill_and_delete(conn)
        reader = sqlite3.connect(self.path)
        try:
            self.assertEqual(reader.execute("SELECT COUNT(*) FROM collector_runs").fetchone()[0], 1)
            with redirect_stderr(io.StringIO()):
                self.assertTrue(history.maybe_vacuum(conn, T0))
            self.assertEqual(reader.execute("SELECT COUNT(*) FROM collector_runs").fetchone()[0], 1)
        finally:
            reader.close()
            conn.close()

    def test_wal_truncate_does_not_wait_for_an_open_read_transaction(self):
        """讀取端正開著交易：截斷 WAL 不等它（不會多等 busy_timeout 的 5 秒），之後 timeout 還原（審查 C-01）。"""
        conn = history.connect(self.path)
        self.fill_and_delete(conn)
        reader = sqlite3.connect(self.path, isolation_level=None)
        try:
            reader.execute("BEGIN")
            reader.execute("SELECT COUNT(*) FROM collector_runs").fetchone()
            start = time.monotonic()
            with redirect_stderr(io.StringIO()):
                self.assertTrue(history.maybe_vacuum(conn, T0))
            self.assertLess(time.monotonic() - start, 2)
            self.assertEqual(conn.execute("PRAGMA busy_timeout").fetchone()[0], 5000)
            reader.execute("COMMIT")
        finally:
            reader.close()
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self.assertEqual(os.path.getsize(str(self.path) + "-wal"), 0)  # 讀取結束後截斷得了
        conn.close()


    def test_failed_vacuum_is_retried_without_blaming_the_database(self):
        """VACUUM 等不到寫入鎖（或暫存空間不夠）：不丟例外、不記上次時間、日誌不說損毀（總檢查 F-03）。"""
        conn = history.connect(self.path)
        self.fill_and_delete(conn)
        conn.execute("PRAGMA busy_timeout = 0")
        writer = sqlite3.connect(self.path, isolation_level=None)
        try:
            writer.execute("BEGIN IMMEDIATE")
            with redirect_stderr(io.StringIO()) as err:
                self.assertFalse(history.maybe_vacuum(conn, T0))
            writer.execute("ROLLBACK")
        finally:
            writer.close()
        self.assertIn("整理 history.sqlite3 失敗（OperationalError），下次清理再試", err.getvalue())
        self.assertNotIn("損毀", err.getvalue())
        self.assertIsNone(history.meta(conn, "last_vacuum_at"))
        conn.close()

    def test_wal_shrinks_after_the_reader_closes(self):
        """VACUUM 時讀取端開著、WAL 截斷不了：讀取端關閉後，下一次一般寫入就把 WAL 縮回上限內，
        不會停在整個資料庫的大小等 30 天（總檢查 F-04）。"""
        with mock.patch.object(history, "WAL_SIZE_LIMIT", 65536):
            conn = history.connect(self.path)
        conn.executemany("INSERT INTO seen_ids (provider, id, day, hour, model) VALUES ('claude', ?, '2026-01-01', 0, 'm')",
                         ((f"msg_{i:06d}_0123456789abcdef0123456789",) for i in range(50000)))
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")  # 超過自動 checkpoint 的 1000 頁，VACUUM 後的 WAL 也是
        reader = sqlite3.connect(self.path, isolation_level=None)
        try:
            reader.execute("BEGIN")
            reader.execute("SELECT COUNT(*) FROM seen_ids").fetchone()
            with redirect_stderr(io.StringIO()):
                self.assertTrue(history.maybe_vacuum(conn, T0))
            self.assertGreater(os.path.getsize(f"{self.path}-wal"), 5 * 1024 * 1024)
            reader.execute("COMMIT")
        finally:
            reader.close()
        for ts in range(3):
            conn.execute("INSERT INTO collector_runs (ts, ok, runs) VALUES (?, 1, 1)", (T0 + ts,))
        self.assertLessEqual(os.path.getsize(f"{self.path}-wal"), 65536)
        conn.close()

class FailureIsolationTest(HistoryTestCase):
    """歷史寫不進去時，usage.json 與上傳照常，結束碼不變。"""

    def run_cli(self):
        usage_path = Path(self.dir.name) / "usage.json"
        providers = {"claude": mock.Mock(fetch=mock.Mock(return_value=ProviderUsage(
            plan="Max", windows=[Window("five_hour", "5 小時", 10, None)])))}
        err = io.StringIO()
        write = local_store.write_snapshot
        with mock.patch.dict(cli.PROVIDERS, providers, clear=True), \
             mock.patch.object(cli, "enabled_providers", return_value=["claude"]), \
             mock.patch.object(local_store, "LOCAL_SNAPSHOT_PATH", usage_path), \
             mock.patch.object(cli.local_store, "write_snapshot",
                               side_effect=lambda s: write(s, usage_path)), \
             mock.patch.object(relay, "upload") as upload, \
             mock.patch.object(history, "HISTORY_PATH", self.path), \
             mock.patch.object(cli.token_stats, "log_dirs", return_value=NO_LOGS), \
             mock.patch.object(cli.token_stats.system, "lower_priority"), \
             mock.patch.object(cli.service_status, "update_safely") as status, \
             redirect_stdout(io.StringIO()), redirect_stderr(err):
            code = cli.main(["--write-local", "--upload", "--quiet"])
        self.status_providers = [c.args[0] for c in status.call_args_list]
        return code, usage_path, upload, err.getvalue()

    def test_success_writes_history_after_usage_and_upload(self):
        code, usage_path, upload, err = self.run_cli()
        self.assertEqual(code, 0)
        self.assertTrue(usage_path.exists())
        upload.assert_called_once()
        self.assertEqual(self.count("collector_runs"), 1)
        self.assertEqual(err, "")
        self.assertEqual(self.status_providers, [["claude"]])

    def test_token_stats_run_after_history_and_failure_keeps_exit_code(self):
        order = []
        with mock.patch.object(history, "record_safely", side_effect=lambda s: order.append("history")), \
             mock.patch.object(cli.token_stats, "run", side_effect=RuntimeError("boom")) as run:
            run.side_effect = lambda *a, **k: (order.append("tokens"), (_ for _ in ()).throw(RuntimeError("x")))
            code, _, _, err = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(order, ["history", "tokens"])
        self.assertIn("略過 Token 統計：RuntimeError", err)

    def test_corrupt_database(self):
        self.path.write_bytes(b"this is not a sqlite database at all" * 200)
        code, usage_path, upload, err = self.run_cli()
        self.assertEqual(code, 0)
        self.assertTrue(usage_path.exists())
        upload.assert_called_once()
        self.assertIn("略過額度歷史（DatabaseError）", err)
        self.assertNotIn(self.dir.name, err)  # 不把路徑寫進日誌
        self.assertEqual(self.path.read_bytes()[:10], b"this is no")  # 不動損毀的檔案

    def test_locked_database(self):
        history.record(snapshot(T0), self.path)
        holder = sqlite3.connect(self.path, isolation_level=None)
        holder.execute("BEGIN EXCLUSIVE")
        try:
            with mock.patch.object(history, "BUSY_TIMEOUT_MS", 200):
                start = time.monotonic()
                code, usage_path, upload, err = self.run_cli()
                elapsed = time.monotonic() - start
        finally:
            holder.rollback()
            holder.close()
        self.assertEqual(code, 0)
        self.assertTrue(usage_path.exists())
        upload.assert_called_once()
        self.assertIn("OperationalError", err)
        self.assertLess(elapsed, 3)

    @unittest.skipIf(sys.platform == "win32", "Windows 沒有 POSIX 權限位元")
    def test_unwritable_folder(self):
        ro = Path(self.dir.name) / "ro"
        ro.mkdir()
        os.chmod(ro, 0o500)
        try:
            with mock.patch.object(history, "HISTORY_PATH", ro / "history.sqlite3"):
                err = io.StringIO()
                with redirect_stderr(err):
                    self.assertFalse(history.record_safely(snapshot(T0)))
        finally:
            os.chmod(ro, 0o700)
        self.assertIn("略過額度歷史", err.getvalue())

    def test_newer_schema_is_logged_not_raised(self):
        with self.db() as c:
            c.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
            c.execute("INSERT INTO meta VALUES ('schema_version', '99')")
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertFalse(history.record_safely(snapshot(T0), self.path))
        self.assertIn("比收集器新", err.getvalue())

    def test_unexpected_snapshot_shape(self):
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertFalse(history.record_safely({"providers": {}}, self.path))  # 缺 updated_at
        self.assertIn("KeyError", err.getvalue())

    def test_without_write_local_history_is_not_touched(self):
        with mock.patch.dict(cli.PROVIDERS, {}, clear=True), \
             mock.patch.object(cli, "enabled_providers", return_value=[]), \
             mock.patch.object(history, "HISTORY_PATH", self.path), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            cli.main(["--quiet"])
        self.assertFalse(self.path.exists())


class PerformanceTest(HistoryTestCase):
    def test_one_run_on_a_year_of_data_takes_under_a_second(self):
        # 一年的資料量（ADR-0009 第 5 節估計）：最近 35 天每 5 分鐘、之前每小時，4 個額度
        now = T0 + 365 * DAY
        conn = history.connect(self.path)
        rows, runs = [], []
        for ts in range(now - 365 * DAY, now - 35 * DAY, HOUR):
            runs.append((ts, 12, 12))
            rows += [(ts, p, w, 10.0, ts + HOUR) for p in ("claude", "codex") for w in ("five_hour", "weekly")]
        for ts in range(now - 35 * DAY, now, 300):
            runs.append((ts, 1, 1))
            rows += [(ts, p, w, 10.0, ts + HOUR) for p in ("claude", "codex") for w in ("five_hour", "weekly")]
        with conn:  # 同一個交易：autocommit 下每列一次 fsync，Windows 要好幾分鐘
            conn.execute("BEGIN")
            conn.executemany("INSERT INTO collector_runs VALUES (?, ?, ?)", runs)
            conn.executemany("INSERT INTO quota_samples VALUES (?, ?, ?, ?, ?)", rows)
        conn.close()
        start = time.monotonic()
        history.record(snapshot(now), self.path, now=datetime.fromtimestamp(now + DAY, timezone.utc))  # 含每日清理
        elapsed = time.monotonic() - start
        self.assertLess(elapsed, 1.0)


if __name__ == "__main__":
    unittest.main()
