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
             mock.patch.object(cli.token_stats.os, "nice"), \
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
        conn.executemany("INSERT INTO collector_runs VALUES (?, ?, ?)", runs)
        conn.executemany("INSERT INTO quota_samples VALUES (?, ?, ?, ?, ?)", rows)
        conn.close()
        start = time.monotonic()
        history.record(snapshot(now), self.path, now=datetime.fromtimestamp(now + DAY, timezone.utc))  # 含每日清理
        elapsed = time.monotonic() - start
        self.assertLess(elapsed, 1.0)


if __name__ == "__main__":
    unittest.main()
