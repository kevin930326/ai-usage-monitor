"""Token 統計（ADR-0009）的測試：只用這裡編的假紀錄。"""
import io
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
import unittest
from contextlib import contextmanager, redirect_stderr
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from usage_collector import history, system, token_stats

TAIPEI = timezone(timedelta(hours=8))

T0 = 1_790_000_000  # 2026-09-21 13:33:20 UTC
HOUR = 3600
DAY = 86400
SESSION = "11111111-2222-4333-8444-555555555555"
OTHER = "66666666-7777-4888-8999-aaaaaaaaaaaa"
ROLLOUT = "abcdefab-cdef-4abc-8def-abcdefabcdef"

# 每一種行都放進去的假內容：不能出現在資料庫、日誌或輸出
SECRETS = ("SECRET-PROMPT-TEXT", "fake.person@example.com", "secret-project-folder", "secret-branch",
           "SECRET-AGENT-MESSAGE", "SECRET-TOOL-OUTPUT", "/Users/fake")


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def claude_assistant(msg_id, ts, inp=0, cw=0, cr=0, out=0, model="claude-opus-5-5", sidechain=False,
                     request_id="req_1", compact=False):
    line = {
        "parentUuid": "x", "isSidechain": sidechain, "type": "assistant", "timestamp": iso(ts),
        "cwd": "/Users/fake/secret-project-folder", "gitBranch": "secret-branch", "requestId": request_id,
        "message": {"id": msg_id, "type": "message", "role": "assistant", "model": model,
                    "content": [{"type": "text", "text": "SECRET-PROMPT-TEXT reply"}],
                    "usage": {"input_tokens": inp, "cache_creation_input_tokens": cw,
                              "cache_read_input_tokens": cr, "output_tokens": out, "service_tier": "standard"}},
    }
    if msg_id is None:
        del line["message"]["id"]
    return json.dumps(line, separators=(",", ":") if compact else (", ", ": "))


def claude_user(ts, tool_result=False, meta=False, sidechain=False):
    content = ([{"type": "tool_result", "tool_use_id": "t", "content": "SECRET-TOOL-OUTPUT"}]
               if tool_result else "SECRET-PROMPT-TEXT please")
    return json.dumps({
        "type": "user", "timestamp": iso(ts), "isMeta": meta, "isSidechain": sidechain,
        "cwd": "/Users/fake/secret-project-folder", "gitBranch": "secret-branch",
        "attachment": {"userEmail": "fake.person@example.com", "gitStatus": "M secret.txt"},
        "message": {"role": "user", "content": content},
    })


def codex_turn(model="gpt-6.1-sol"):
    return json.dumps({"timestamp": iso(T0), "type": "turn_context",
                       "payload": {"model": model, "cwd": "/Users/fake/secret-project-folder",
                                   "workspace_roots": ["/Users/fake"]}})


def codex_usage(inp, cached=0, cw=0, out=0, reasoning=0):
    return {"input_tokens": inp, "cached_input_tokens": cached, "cache_write_input_tokens": cw,
            "output_tokens": out, "reasoning_output_tokens": reasoning, "total_tokens": inp + out}


def codex_record(rid, ts, **usage):
    return json.dumps({"timestamp": iso(ts), "type": "token_usage_record", "ordinal": 1,
                       "payload": {"response_id": rid, "turn_id": "turn", "usage": codex_usage(**usage)}})


def codex_count(ts, **usage):
    info = None if not usage else {"total_token_usage": codex_usage(**usage), "last_token_usage": codex_usage(0)}
    return json.dumps({"timestamp": iso(ts), "type": "event_msg",
                       "payload": {"type": "token_count", "info": info,
                                   "rate_limits": {"primary": {"used_percent": 1}}}})


def codex_task(turn, started, completed, duration_ms=None):
    payload = {"type": "task_complete", "turn_id": turn, "started_at": started, "completed_at": completed,
               "last_agent_message": "SECRET-AGENT-MESSAGE"}
    if duration_ms is not None:
        payload["duration_ms"] = duration_ms
    return json.dumps({"timestamp": iso(completed), "type": "event_msg", "payload": payload})


def codex_noise():
    return json.dumps({"timestamp": iso(T0), "type": "response_item",
                       "payload": {"type": "message", "content": "SECRET-PROMPT-TEXT"}})


class TokenStatsTestCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = Path(self.dir.name)
        self.path = root / "data" / "history.sqlite3"
        self.claude = root / "claude"
        self.codex = root / "codex"
        self.project = self.claude / "projects" / "-Users-fake-secret-project-folder"
        self.project.mkdir(parents=True)
        self.sessions = self.codex / "sessions" / "2026" / "09" / "21"
        self.sessions.mkdir(parents=True)
        self.stderr = io.StringIO()
        # 日期以掃描當下的本機時區計算：固定成台北時間（UTC+8、沒有日光節約）。
        # Windows 沒有 time.tzset，改 patch system.local_datetime；macOS 另外設 TZ，其他用到本機時間的地方也一致
        self._local = mock.patch.object(system, "local_datetime",
                                        lambda ts: datetime.fromtimestamp(ts, TAIPEI).replace(tzinfo=None))
        self._local.start()
        self._tz = os.environ.get("TZ")
        if hasattr(time, "tzset"):
            os.environ["TZ"] = "Asia/Taipei"
            time.tzset()

    def tearDown(self):
        self._local.stop()
        if hasattr(time, "tzset"):
            if self._tz is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = self._tz
            time.tzset()
        self.dir.cleanup()

    @property
    def dirs(self):
        return {"claude": self.claude, "codex": self.codex}

    def claude_file(self, name=SESSION):
        return self.project / f"{name}.jsonl"

    def codex_file(self, rid=ROLLOUT):
        return self.sessions / f"rollout-2026-09-21T21-33-20-{rid}.jsonl"

    def write(self, path: Path, *lines: str, newline=True, mode="a"):
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, mode) as fh:
            fh.write("\n".join(lines) + ("\n" if newline else ""))

    def scan(self, budget=None, path=None, now=T0 + DAY):
        with redirect_stderr(self.stderr):
            return token_stats.run(path or self.path, self.dirs, now=now, budget=budget)

    def scan_before_seen_window(self):
        """以加入去重時間窗（ADR-0014）之前的行為掃描：不設略過界、不刪去重列（模擬當時的資料庫）。"""
        with mock.patch.object(token_stats, "_advance_seen_window", lambda *a: None):
            self.scan()

    @contextmanager
    def db(self, path=None):
        conn = sqlite3.connect(path or self.path)
        try:
            yield conn
        finally:
            conn.close()

    def totals(self, provider=None, path=None):
        """各欄位的總和（input、cache_write、cache_read、output、reasoning、tasks、seconds）。"""
        where = "WHERE provider = ?" if provider else ""
        with self.db(path) as c:
            row = c.execute(
                "SELECT SUM(input_tokens), SUM(cache_write_tokens), SUM(cache_read_tokens), SUM(output_tokens),"
                f" SUM(reasoning_tokens), SUM(task_count), SUM(task_seconds) FROM daily_tokens {where}",
                (provider,) if provider else ()).fetchone()
        return tuple(v or 0 for v in row)

    def table(self, name, path=None):
        with self.db(path) as c:
            cols = [r[1] for r in c.execute(f"PRAGMA table_info({name})") if r[1] not in ("updated_at", "device_id")]
            return sorted(c.execute(f"SELECT {', '.join(cols)} FROM {name}").fetchall(), key=repr)

    def records(self, path=None):
        with self.db(path) as c:
            return {k: (v, d) for k, v, d in c.execute("SELECT key, value, day FROM records")}

    def fresh(self, *files: tuple[Path, str]) -> Path:
        """把最終的檔案內容放進另一組資料夾一次讀完，回傳那份資料庫（比較「分次讀」與「一次讀完」）。"""
        other = Path(self.dir.name) / f"fresh{len(list(Path(self.dir.name).glob('fresh*')))}"
        for src, kind in files:
            rel = src.relative_to(self.claude if kind == "claude" else self.codex)
            dest = other / kind / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
        db = other / "history.sqlite3"
        with redirect_stderr(io.StringIO()):
            token_stats.run(db, {"claude": other / "claude", "codex": other / "codex"}, now=T0 + DAY)
        return db


class SchemaTest(TokenStatsTestCase):
    def test_migrates_v1_to_latest_and_keeps_data(self):
        with mock.patch.object(history, "SCHEMA_VERSION", 1), mock.patch.object(history, "MIGRATIONS", [history._v1]):
            conn = history.connect(self.path)
            conn.execute("INSERT INTO collector_runs (ts, ok) VALUES (?, 1)", (T0,))
            device = history.meta(conn, "device_id")
            conn.close()
        conn = history.connect(self.path)
        self.assertEqual(history.schema_version(conn), 3)
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertTrue({"daily_tokens", "hourly_tokens", "records", "scan_state", "seen_ids", "file_tokens",
                         "seen_tasks", "quota_samples", "collector_runs", "meta", "upload_state", "devices"} <= tables)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM collector_runs").fetchone()[0], 1)
        self.assertEqual(history.meta(conn, "device_id"), device)
        conn.close()

    def test_migrates_v2_to_v3_and_keeps_tokens(self):
        """第二層（schema 3）只加 upload_state 與 devices，既有的 Token 資料不動。"""
        with mock.patch.object(history, "SCHEMA_VERSION", 2), \
                mock.patch.object(history, "MIGRATIONS", [history._v1, history._v2]):
            conn = history.connect(self.path)
            conn.execute("INSERT INTO daily_tokens (device_id, day, provider, model, input_tokens, updated_at)"
                         " VALUES ('d', '2026-10-01', 'claude', 'claude-opus-5-5', 5, 0)")
            conn.close()
        conn = history.connect(self.path)
        self.assertEqual(history.schema_version(conn), 3)
        self.assertEqual(conn.execute("SELECT SUM(input_tokens) FROM daily_tokens").fetchone()[0], 5)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM upload_state").fetchone()[0], 0)
        conn.close()

    def test_upgrade_backfills_cached_records_from_daily_data(self):
        """還沒有 record_days_cached 的檔案（之前的收集器）：以 record_days 加每日資料的 cache_read 算出初始值，只做一次。"""
        self.write(self.claude_file(),
                   claude_user(T0), claude_assistant("d1", T0 + 10, inp=100, cr=10_000, out=0),
                   claude_user(T0 + DAY), claude_assistant("d2", T0 + DAY + 5, inp=300, cr=5, out=0))
        self.write(self.codex_file(), codex_record("r1", T0, inp=50, cached=20, out=0))
        self.scan()
        expected = self.records()
        days = self.table("record_days_cached")
        self.simulate_before_cached_records()
        history.connect(self.path).close()
        self.assertEqual(self.table("record_days_cached"), days)
        self.assertEqual(self.records(), expected)
        self.assertEqual(self.records()["best_day_tokens_cached"], (10_150, "2026-09-21"))
        self.assertEqual(self.records()["total_tokens_cached:codex"], (50, None))
        # 已經有這張表：之後連線不再重算（不會重複加上 cache_read）
        history.connect(self.path).close()
        self.assertEqual(self.records(), expected)

    def simulate_before_cached_records(self):
        """模擬升級前的檔案：拿掉含快取的表與紀錄"""
        with self.db() as c:
            c.execute("DROP TABLE record_days_cached")
            c.execute("DELETE FROM records WHERE key LIKE '%_cached%'")
            c.commit()

    def test_upgrade_counts_cache_reads_of_expired_days(self):
        """每日資料已超過保留期間：初始值仍包含那些日子的快取讀取（來自 seen_ids／file_tokens），與沒有升級過的一樣。"""
        self.write(self.claude_file(), claude_user(T0 - 400 * DAY),
                   claude_assistant("old", T0 - 400 * DAY + 5, inp=100, cr=900, out=0),
                   claude_assistant("new", T0, inp=50, cr=50, out=0))
        self.write(self.codex_file(), codex_turn(), codex_count(T0 - 400 * DAY, inp=1000, cached=600, out=0))
        self.scan_before_seen_window()
        expected = self.records()
        self.assertEqual(expected["total_tokens_cached"][0], 1000 + 100 + 1000)
        self.simulate_before_cached_records()
        history.connect(self.path).close()
        self.assertEqual(self.records(), expected)

    def test_upgrade_then_rewriting_an_expired_codex_file_stays_consistent(self):
        """升級後改寫只剩扣除帳本（file_tokens）的舊 Codex 檔：先扣再加不會誤扣其他日子（審查 C-01）。"""
        self.write(self.codex_file(), codex_turn(), codex_count(T0 - 400 * DAY, inp=1000, cached=900, out=0))
        self.write(self.claude_file(), claude_assistant("new", T0, inp=50, cr=50, out=0))
        self.scan_before_seen_window()
        self.simulate_before_cached_records()
        history.connect(self.path).close()
        self.assertEqual(self.records()["total_tokens_cached"][0], 1000 + 100)
        # 同樣的數量改寫（mtime 變了、內容較短 → 重算）
        self.write(self.codex_file(), codex_turn(), codex_count(T0 - 400 * DAY, inp=1000, cached=900, out=0), mode="w")
        os.utime(self.codex_file(), (T0 + DAY, T0 + DAY))
        self.scan()
        self.scan()
        records = self.records()
        self.assertEqual(records["total_tokens_cached"][0], 1100)
        self.assertEqual(records["total_tokens_cached:codex"][0], 1000)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT SUM(tokens) FROM record_days_cached").fetchone()[0], 1100)

    def test_upgrade_skips_claude_days_cleared_from_history(self):
        """「清除歷史」（不重新掃描）後 record_days 已空、seen_ids 還在：那些日子的快取讀取不算進初始值。"""
        self.write(self.claude_file(), claude_assistant("old", T0, inp=100, cr=900, out=0))
        self.scan()
        with self.db() as c:
            for table in ("daily_tokens", "hourly_tokens", "records", "record_days", "record_days_cached"):
                c.execute(f"DELETE FROM {table}")
            c.commit()
        self.write(self.claude_file(), claude_assistant("new", T0 + DAY, inp=10, cr=20, out=0))
        self.scan()
        self.simulate_before_cached_records()
        history.connect(self.path).close()
        self.assertEqual(self.records()["total_tokens_cached"][0], 30)

    def test_failed_v2_migration_keeps_v1(self):
        with mock.patch.object(history, "SCHEMA_VERSION", 1), mock.patch.object(history, "MIGRATIONS", [history._v1]):
            history.connect(self.path).close()

        def broken(conn):
            history._v2(conn)
            raise RuntimeError("boom")
        with mock.patch.object(history, "MIGRATIONS", [history._v1, broken]), self.assertRaises(RuntimeError):
            history.connect(self.path)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()[0], "1")
            tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertNotIn("daily_tokens", tables)


class EnumerationTest(TokenStatsTestCase):
    def test_only_listed_files(self):
        allowed = {
            self.claude_file(): f"claude:{SESSION}",
            self.project / f"{OTHER}.orphaned-1700000000.jsonl": f"claude:{OTHER}.orphaned-1700000000",
            self.project / f"{SESSION}.superseded-abc_123.jsonl": f"claude:{SESSION}.superseded-abc_123",
            self.project / SESSION / "subagents" / "agent-a1b2c3.jsonl": "claude:agent-a1b2c3",
            self.codex_file(): f"codex:{ROLLOUT}",
            self.codex / "archived_sessions" / f"rollout-2026-01-01T00-00-00-{OTHER}.jsonl": f"codex:{OTHER}",
        }
        for p in allowed:
            self.write(p, "{}")
        outside = Path(self.dir.name) / "outside"
        outside.mkdir()
        (outside / f"{OTHER}.jsonl").write_text("{}\n")
        not_allowed = [
            self.project / SESSION / "tool-results" / "x.jsonl",
            self.project / SESSION / "other" / "y.jsonl",
            self.project / "notes.txt",
            self.claude / "history.jsonl",
            self.claude / ".credentials.json",
            self.claude / "settings.json",
            self.claude / "projects" / "top-level.jsonl",
            self.codex / "auth.json",
            self.codex / "history.jsonl",
            self.codex / "state.sqlite",
            self.codex / "sessions" / "2026" / "09" / f"rollout-x-{OTHER}.jsonl",
            self.codex / "sessions" / "abcd" / "09" / "21" / f"rollout-x-{OTHER}.jsonl",
            self.sessions / f"other-{OTHER}.jsonl",
            # 檔名不是固定格式（可能含專案或帳號名稱）：不列舉、不寫進資料庫
            self.project / "customer-secret-project.jsonl",
            self.project / f"{SESSION}.secret-project.jsonl",
            self.project / f"{SESSION}.orphaned-secret project.jsonl",
            self.project / SESSION / "subagents" / "agent-secret-project.jsonl",
            self.project / SESSION / "subagents" / "helper.jsonl",
            self.sessions / "rollout-customer-secret-project.jsonl",
            self.codex / "archived_sessions" / "rollout-2026-01-01.jsonl",
            self.codex / "archived_sessions" / "sub" / f"rollout-x-{OTHER}.jsonl",
        ]
        for p in not_allowed:
            self.write(p, "{}")
        # 符號連結：檔案與資料夾都不跟隨
        os.symlink(outside / f"{OTHER}.jsonl", self.project / "linked.jsonl")
        os.symlink(outside, self.claude / "projects" / "linked-project")
        os.symlink(outside, self.project / SESSION / "linked-sub")
        os.symlink(outside, self.codex / "sessions" / "2026" / "10")
        files = token_stats.list_files(self.dirs)
        self.assertEqual({f.key for f in files}, set(allowed.values()))
        self.assertEqual({f.path for f in files}, {str(p) for p in allowed})

    def test_log_dirs_config_then_env_then_default(self):
        config = Path(self.dir.name) / "config.json"
        config.write_text(json.dumps({"claude_config_dir": "/c1", "codex_home": ["bad"]}))
        dirs = token_stats.log_dirs(config, {"CLAUDE_CONFIG_DIR": "/c2", "CODEX_HOME": "/x2"})
        self.assertEqual(dirs, {"claude": Path("/c1"), "codex": Path("/x2")})
        dirs = token_stats.log_dirs(Path(self.dir.name) / "missing.json", {})
        self.assertEqual(dirs, {"claude": Path.home() / ".claude", "codex": Path.home() / ".codex"})

    def test_missing_dirs_finish_first_scan(self):
        shutil.rmtree(self.claude)
        shutil.rmtree(self.codex)
        result = self.scan()
        self.assertTrue(result.done)
        with self.db() as c:
            meta = dict(c.execute("SELECT key, value FROM meta"))
        self.assertEqual((meta["first_scan_done"], meta["first_scan_progress"]), ("1", "100"))


class PrivacyTest(TokenStatsTestCase):
    def test_no_content_paths_or_names_leak(self):
        self.write(self.claude_file(),
                   claude_user(T0), claude_assistant("msg_1", T0 + 5, inp=10, out=5),
                   claude_user(T0 + 6, tool_result=True), claude_user(T0 + 7, meta=True),
                   '{"type": "user", "broken SECRET-PROMPT-TEXT')
        self.write(self.codex_file(), codex_turn(), codex_noise(), codex_record("resp_1", T0, inp=10, out=2),
                   codex_count(T0, inp=10, out=2), codex_task("turn_1", T0, T0 + 9, 9000))
        with mock.patch.object(token_stats, "_count_task", side_effect=ValueError("SECRET-PROMPT-TEXT /Users/fake")):
            self.scan()
        self.scan()
        with self.db() as c:
            dump = "\n".join(c.iterdump())
        output = self.stderr.getvalue()
        for secret in SECRETS:
            self.assertNotIn(secret, dump, secret)
            self.assertNotIn(secret, output, secret)
        self.assertNotIn(self.dir.name, dump + output)
        self.assertNotIn("rollout-", dump + output)
        self.assertIn("ValueError", output)  # 只記錄例外類別與檔案序號
        self.assertRegex(output, r"略過第 \d+ 個紀錄檔（ValueError）")

    def test_source_does_not_read_other_fields_or_files(self):
        source = Path(token_stats.__file__).read_text()
        for needle in ("cwd", "gitBranch", "last_agent_message", "userEmail", "gitStatus", "workspace_roots",
                       "lastPrompt", "customTitle", "auth.json", ".credentials", "stats-cache", "history.jsonl",
                       "rate_limits\"", "response_item", "\"text\""):
            self.assertNotIn(needle, source, needle)


class ClaudeTest(TokenStatsTestCase):
    def test_streaming_dedupe_keeps_last_usage(self):
        # 同一則回應寫成三行（每個內容區塊一行），usage 逐步變大
        self.write(self.claude_file(),
                   claude_assistant("msg_1", T0, inp=10, cw=100, cr=1000, out=1),
                   claude_assistant("msg_1", T0, inp=10, cw=100, cr=1000, out=7),
                   claude_assistant("msg_1", T0, inp=10, cw=100, cr=1000, out=30, compact=True))
        self.scan()
        self.assertEqual(self.totals("claude")[:5], (10, 100, 1000, 30, 0))
        self.assertEqual(self.records()["total_tokens"][0], 140)  # input + cache_write + output

    def test_streaming_split_across_scans_matches_one_pass(self):
        self.write(self.claude_file(), claude_user(T0), claude_assistant("msg_1", T0 + 1, inp=10, out=1))
        self.scan()
        self.write(self.claude_file(), claude_assistant("msg_1", T0 + 2, inp=10, cw=5, out=20),
                   claude_assistant("msg_2", T0 + 3, inp=3, out=4))
        self.scan()
        self.scan()  # 重掃不增加
        fresh = self.fresh((self.claude_file(), "claude"))
        self.assertEqual(self.table("daily_tokens"), self.table("daily_tokens", fresh))
        self.assertEqual(self.records(), self.records(fresh))
        self.assertEqual(self.totals("claude")[:4], (13, 5, 0, 24))

    def test_resume_copies_and_cross_file_duplicates(self):
        lines = [claude_user(T0), claude_assistant("msg_1", T0 + 60, inp=10, out=5),
                 claude_assistant("msg_2", T0 + 120, inp=1, out=1)]
        self.write(self.claude_file(), *lines)
        self.scan()
        before = self.table("daily_tokens")
        # --resume 與舊副本：相同的訊息出現在別的檔案（含較早、較小的串流行）
        self.write(self.claude_file(OTHER), claude_assistant("msg_1", T0 + 60, inp=10, out=2), *lines,
                   claude_user(T0 + DAY), claude_assistant("msg_3", T0 + DAY + 30, inp=2, out=2))
        self.write(self.project / f"{SESSION}.orphaned-1.jsonl", *lines)
        self.scan()
        after = self.totals("claude")
        self.assertEqual(after[:4], (13, 0, 0, 8))
        self.assertEqual(after[5], 2)  # 兩個任務（副本中的同一任務不重算）
        self.assertNotEqual(before, self.table("daily_tokens"))

    def test_requestid_fallback_and_lines_without_id(self):
        self.write(self.claude_file(),
                   claude_assistant(None, T0, inp=5, out=5, request_id="req_9"),
                   claude_assistant(None, T0, inp=5, out=6, request_id="req_9"),
                   json.dumps({"type": "assistant", "timestamp": iso(T0),
                               "message": {"usage": {"input_tokens": 99}}}))
        self.scan()
        self.assertEqual(self.totals("claude")[:4], (5, 0, 0, 6))
        with self.db() as c:
            self.assertEqual(c.execute("SELECT value FROM meta WHERE key = 'token_bad_lines'").fetchone()[0], "1")

    def test_task_time(self):
        self.write(self.claude_file(),
                   claude_user(T0),
                   claude_assistant("a1", T0 + 60, out=1),
                   claude_user(T0 + 70, tool_result=True),  # 工具結果不算新的提示
                   claude_user(T0 + 71, meta=True),
                   claude_assistant("a2", T0 + 120, out=1),
                   claude_assistant("s1", T0 + 500, out=1, sidechain=True),  # 子代理只算 Token
                   claude_user(T0 + 1000),
                   claude_assistant("a3", T0 + 1030, out=1))
        self.scan()
        totals = self.totals("claude")
        self.assertEqual((totals[5], totals[6]), (2, 150))
        self.assertEqual(self.records()["longest_task_seconds"][0], 120)

    def test_task_split_across_scans_and_cap(self):
        self.write(self.claude_file(), claude_user(T0), claude_assistant("a1", T0 + 60, out=1))
        self.scan()
        self.write(self.claude_file(), claude_assistant("a2", T0 + 200, out=1))
        self.scan()
        self.assertEqual(self.totals("claude")[5:], (1, 200))
        self.write(self.claude_file(), claude_user(T0 + 300), claude_assistant("a3", T0 + 300 + 8 * HOUR, out=1))
        self.scan()
        self.assertEqual(self.totals("claude")[5:], (2, 200 + 6 * HOUR))

    def test_subagent_file_counts_tokens_only(self):
        self.write(self.project / SESSION / "subagents" / "agent-1.jsonl",
                   claude_user(T0, sidechain=True), claude_assistant("s1", T0 + 99, inp=4, out=4, sidechain=True))
        self.scan()
        self.assertEqual(self.totals("claude")[:6], (4, 0, 0, 4, 0, 0))

    def test_rewritten_file_is_rescanned_without_double_counting(self):
        self.write(self.claude_file(), claude_user(T0), claude_assistant("a1", T0 + 5, inp=1, out=1))
        self.scan()
        # 改寫（較小的新檔案、不同 inode）：從頭重掃，以 seen_ids 去重
        self.claude_file().unlink()
        self.write(self.claude_file(), claude_assistant("a1", T0 + 5, inp=1, out=1))
        self.scan()
        self.write(self.claude_file(), claude_assistant("a9", T0 + 9, inp=2, out=2))
        self.scan()
        self.assertEqual(self.totals("claude")[:4], (3, 0, 0, 3))
        self.assertEqual(self.totals("claude")[5], 1)


class LineHandlingTest(TokenStatsTestCase):
    def test_incomplete_last_line_waits(self):
        full = claude_assistant("a1", T0, inp=1, out=1)
        self.write(self.claude_file(), full[:40], newline=False)
        self.scan()
        self.assertEqual(self.totals("claude")[:4], (0, 0, 0, 0))
        with open(self.claude_file(), "a") as fh:
            fh.write(full[40:] + "\n")
        self.scan()
        self.assertEqual(self.totals("claude")[:4], (1, 0, 0, 1))
        with self.db() as c:
            self.assertIsNone(c.execute("SELECT value FROM meta WHERE key = 'token_bad_lines'").fetchone())

    def test_long_and_bad_lines_are_skipped_and_counted(self):
        long_line = claude_assistant("big", T0, inp=1000, out=1000).replace("reply", "x" * 5000)
        self.write(self.claude_file(), claude_assistant("a1", T0, inp=1, out=1), long_line,
                   "not json \"user\"", "[\"user\"]", claude_assistant("a2", T0, inp=2, out=2))
        with mock.patch.object(token_stats, "MAX_LINE_BYTES", 2048):
            self.scan()
        self.assertEqual(self.totals("claude")[:4], (3, 0, 0, 3))
        with self.db() as c:
            meta = dict(c.execute("SELECT key, value FROM meta"))
        self.assertEqual((meta["token_long_lines"], meta["token_bad_lines"]), ("1", "2"))
        self.scan()  # 重掃不增加計數
        with self.db() as c:
            self.assertEqual(c.execute("SELECT value FROM meta WHERE key = 'token_bad_lines'").fetchone()[0], "2")

    def test_long_line_at_end_without_newline_is_skipped_later(self):
        self.write(self.claude_file(), claude_assistant("a1", T0, inp=1, out=1), "x" * 5000, newline=False)
        with mock.patch.object(token_stats, "MAX_LINE_BYTES", 2048):
            self.scan()
            self.write(self.claude_file(), "y" * 3000, claude_assistant("a2", T0, inp=2, out=2))
            self.scan()
            self.scan()
        self.assertEqual(self.totals("claude")[:4], (3, 0, 0, 3))
        with self.db() as c:
            self.assertEqual(c.execute("SELECT value FROM meta WHERE key = 'token_long_lines'").fetchone()[0], "1")

    def test_skipping_a_long_line_respects_the_budget(self):
        # 一行比整次預算還長：分好幾次丟完，不重讀已丟棄的部分
        self.write(self.claude_file(), claude_assistant("a1", T0, inp=1, out=1), "z" * 20_000,
                   claude_assistant("a2", T0, inp=2, out=2))
        size = self.claude_file().stat().st_size
        consumed, runs = 0, 0
        with mock.patch.object(token_stats, "MAX_LINE_BYTES", 2048), mock.patch.object(token_stats, "SKIP_CHUNK_BYTES", 1024):
            while runs < 50:
                budget = token_stats.Budget(bytes_left=4000)
                result = self.scan(budget=budget)
                consumed += 4000 - budget.bytes_left
                self.assertLessEqual(4000 - budget.bytes_left, 4000 + 2049)
                runs += 1
                if result.done:
                    break
        self.assertGreater(runs, 4)
        self.assertLessEqual(consumed, size)
        self.assertEqual(self.totals("claude")[:4], (3, 0, 0, 3))

    def test_model_whitelist(self):
        for value, expected in (("claude-opus-5-5", "claude-opus-5-5"), ("gpt-6.1-sol", "gpt-6.1-sol"),
                                ("codex-mini-latest", "codex-mini-latest"), ("o4-mini", "o4-mini"),
                                ("<synthetic>", "other"), ("my-proxy/claude", "other"), ("Claude-Opus", "other"),
                                ("claude-" + "x" * 60, "other"), ("omni", "other"), (None, "other"), (42, "other")):
            self.assertEqual(token_stats.normalize_model(value), expected, value)

    def test_local_timezone_day_and_hour(self):
        # 2026-09-21 16:30 UTC = 台北 9/22 00:30
        ts = int(datetime(2026, 9, 21, 16, 30, tzinfo=timezone.utc).timestamp())
        self.write(self.claude_file(), claude_assistant("a1", ts, inp=1, out=1))
        self.scan()
        with self.db() as c:
            self.assertEqual(c.execute("SELECT day, hour FROM hourly_tokens").fetchall(), [("2026-09-22", 0)])


class CodexTest(TokenStatsTestCase):
    def test_record_normalization_and_total(self):
        self.write(self.codex_file(), codex_turn("gpt-6.1-sol"), codex_noise(),
                   codex_record("r1", T0, inp=1000, cached=600, cw=100, out=50, reasoning=20),
                   codex_record("r1", T0, inp=1000, cached=600, cw=100, out=50, reasoning=20),  # 重送
                   codex_count(T0, inp=999999, out=1))  # 有 record 時忽略 token_count
        self.scan()
        inp, cw, cr, out, reasoning = self.totals("codex")[:5]
        self.assertEqual((inp, cw, cr, out, reasoning), (300, 100, 600, 50, 20))
        self.assertEqual(inp + cw + cr + out, 1000 + 50)  # == total_tokens
        with self.db() as c:
            self.assertEqual(c.execute("SELECT DISTINCT model FROM daily_tokens").fetchall(), [("gpt-6.1-sol",)])

    def test_record_dedupe_across_files(self):
        self.write(self.codex_file(), codex_record("r1", T0, inp=10, out=1))
        self.write(self.codex / "archived_sessions" / f"rollout-x-{OTHER}.jsonl", codex_record("r1", T0, inp=10, out=1))
        self.scan()
        self.assertEqual(self.totals("codex")[:4], (10, 0, 0, 1))

    def test_token_count_positive_deltas_and_compaction(self):
        self.write(self.codex_file(), codex_turn(),
                   codex_count(T0),  # info 為 null
                   codex_count(T0, inp=100, cached=40, out=10),
                   codex_count(T0 + 1, inp=100, cached=40, out=10),  # 重送相同的累計值
                   codex_count(T0 + 2, inp=250, cached=100, out=30))
        self.scan()
        self.assertEqual(self.totals("codex")[:4], (150, 0, 100, 30))
        # compaction：累計值變小 → 以新值重新起算，不計入
        self.write(self.codex_file(), codex_count(T0 + 3, inp=50, cached=0, out=5),
                   codex_count(T0 + 4, inp=80, cached=10, out=9))
        self.scan()
        self.scan()
        self.assertEqual(self.totals("codex")[:4], (150 + 20, 0, 100 + 10, 30 + 4))
        fresh = self.fresh((self.codex_file(), "codex"))
        self.assertEqual(self.table("daily_tokens"), self.table("daily_tokens", fresh))

    def test_concurrent_collector_does_not_add_codex_deltas_twice(self):
        """兩個收集器同時執行（launchd 一輪＋手動執行）：第一個在交易外讀了掃描進度後，
        第二個先拿到寫入鎖並處理完同一段新內容；第一個拿到鎖後不能沿用舊 offset 再累加一次。"""
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=100, out=10))
        self.scan()
        self.write(self.codex_file(), codex_count(T0 + 1, inp=300, out=30))
        original = history._transaction
        other_ran = []

        @contextmanager
        def racing(conn):
            if not other_ran:
                other_ran.append(True)
                self.scan()  # 另一個收集器（另一條連線）先完成
            with original(conn):
                yield

        with mock.patch.object(history, "_transaction", racing):
            self.scan()
        self.assertTrue(other_ran)
        self.assertEqual(self.totals("codex")[:4], (300, 0, 0, 30))
        fresh = self.fresh((self.codex_file(), "codex"))
        self.assertEqual(self.table("daily_tokens"), self.table("daily_tokens", fresh))

    def test_concurrent_collector_append_is_not_mistaken_for_a_rewrite(self):
        """A 列舉後紀錄又附加、B 先處理完並寫下較新的 mtime：A 不能拿列舉時較舊的 mtime 判成改寫、整檔重算（審查 C-01）。"""
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=100, out=10))
        self.scan()
        self.write(self.codex_file(), codex_count(T0 + 1, inp=300, out=30))
        original = history._transaction
        other_ran = []

        @contextmanager
        def racing(conn):
            if not other_ran:
                other_ran.append(True)
                self.write(self.codex_file(), codex_count(T0 + 2, inp=600, out=60))
                later = time.time() + 100
                os.utime(self.codex_file(), (later, later))
                self.scan()  # B
            with original(conn):
                yield

        with mock.patch.object(history, "_transaction", racing), \
             mock.patch.object(token_stats, "_reset_codex", wraps=token_stats._reset_codex) as reset:
            self.scan()  # A
        self.assertTrue(other_ran)
        reset.assert_not_called()
        self.assertEqual(self.totals("codex")[:4], (600, 0, 0, 60))

    def test_records_go_down_when_a_codex_recount_subtracts(self):
        """Codex 重算扣除後，單日最高與連續天數跟著下修，與一次讀完相同（ADR-0014 LT-18）。"""
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=1_000_000, out=0),
                   codex_count(T0 + DAY, inp=1_000_100, out=0))
        self.scan(now=T0 + 2 * DAY)
        self.assertEqual(self.records()["best_day_tokens"][0], 1_000_000)
        self.assertEqual(self.records()["longest_streak_days"][0], 2)
        # 改寫成較小的內容（只剩第一天、數字小很多）→ 先扣再加
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=500, out=0), mode="w")
        os.utime(self.codex_file(), (T0 - DAY, T0 - DAY))
        self.scan(now=T0 + 2 * DAY)
        records = self.records()
        self.assertEqual(records["best_day_tokens"][0], 500)
        self.assertEqual(records["longest_streak_days"][0], 1)
        fresh = self.fresh((self.codex_file(), "codex"))
        for key in ("best_day_tokens", "best_day_tokens:codex", "longest_streak_days", "total_tokens"):
            self.assertEqual(records[key], self.records(fresh)[key], key)

    def test_copied_codex_rollout_counts_once(self):
        # 同一個 rollout 被複製（不是搬移）到 archived_sessions：token_count 沒有跨檔 ID，只算一份
        lines = (codex_turn(), codex_count(T0, inp=100, out=10), codex_count(T0 + 1, inp=300, out=30))
        self.write(self.codex_file(), *lines)
        copy = self.codex / "archived_sessions" / self.codex_file().name
        self.write(copy, *lines)
        self.assertEqual([f.key for f in token_stats.list_files(self.dirs)], [f"codex:{ROLLOUT}"])
        self.scan()
        self.scan()
        self.assertEqual(self.totals("codex")[:4], (300, 0, 0, 30))
        # 原檔不見後改讀複本：視為同一檔被替換，先扣再重算，合計不變
        self.codex_file().unlink()
        self.scan()
        self.assertEqual(self.totals("codex")[:4], (300, 0, 0, 30))

    def test_undecided_source_waits_for_token_events(self):
        self.write(self.codex_file(), codex_turn("gpt-6.1-sol"))
        self.scan()
        with self.db() as c:
            self.assertEqual(c.execute("SELECT source FROM scan_state").fetchone()[0], None)
        self.write(self.codex_file(), codex_record("r1", T0, inp=5, out=5))
        self.scan()
        with self.db() as c:
            self.assertEqual(c.execute("SELECT source FROM scan_state").fetchone()[0], "record")
            self.assertEqual(c.execute("SELECT DISTINCT model FROM daily_tokens").fetchall(), [("gpt-6.1-sol",)])

    def check_switch_to_records(self, overlap):
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=100, out=10),
                   codex_count(T0 + 1, inp=300, cached=100, out=30))
        self.scan()
        self.assertEqual(self.totals("codex")[:4], (200, 0, 100, 30))
        # 之後出現 record：改用 record 從頭重算（先扣掉 token_count 計入的）
        lines = [codex_record("r1", T0, inp=100, out=10), codex_record("r2", T0 + 1, inp=200, cached=100, out=20)]
        if not overlap:
            lines = [codex_record("r9", T0 + 5, inp=7, out=7)]
        self.write(self.codex_file(), *lines, codex_count(T0 + 9, inp=999, out=99))
        self.scan()
        self.scan()
        fresh = self.fresh((self.codex_file(), "codex"))
        self.assertEqual(self.table("daily_tokens"), self.table("daily_tokens", fresh))
        self.assertEqual(self.records()["total_tokens"], self.records(fresh)["total_tokens"])
        with self.db() as c:
            self.assertEqual(c.execute("SELECT source FROM scan_state").fetchone()[0], "record")

    def test_token_count_then_overlapping_records(self):
        self.check_switch_to_records(overlap=True)

    def test_token_count_then_other_records(self):
        self.check_switch_to_records(overlap=False)

    def test_truncated_and_rewritten_file_recomputes(self):
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=100, out=10),
                   codex_count(T0 + 1, inp=500, out=50))
        self.scan()
        # 截斷後寫入不同的內容（較小）：先扣掉該檔的貢獻再從頭重算
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=40, out=4), mode="w")
        self.scan()
        self.assertEqual(self.totals("codex")[:4], (40, 0, 0, 4))
        # 換成新的檔案（不同 inode、mtime 倒退）
        os.rename(self.codex_file(), Path(self.dir.name) / "moved-away.jsonl")
        self.write(self.codex_file(), codex_turn(), codex_record("r1", T0, inp=9, out=1), codex_record("r2", T0, inp=1, out=1))
        os.utime(self.codex_file(), (T0 - DAY, T0 - DAY))
        self.scan()
        self.scan()
        fresh = self.fresh((self.codex_file(), "codex"))
        self.assertEqual(self.table("daily_tokens"), self.table("daily_tokens", fresh))
        self.assertEqual(self.table("file_tokens"), self.table("file_tokens", fresh))
        self.assertEqual(self.records()["total_tokens"], self.records(fresh)["total_tokens"])

    def test_unreadable_or_replaced_file_changes_nothing(self):
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=100, out=10))
        self.scan()
        before = {t: self.table(t) for t in ("daily_tokens", "hourly_tokens", "records", "seen_ids", "file_tokens", "scan_state")}
        # 截斷（需要重算）但開不了：扣除不能先提交
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=1, out=1), mode="w")
        with mock.patch.object(token_stats.os, "open", side_effect=PermissionError("denied")):
            self.scan()
        self.assertEqual({t: self.table(t) for t in before}, before)
        # 列舉之後被換成另一個檔案（inode 不同）。舊檔移到紀錄資料夾外而不是刪除：
        # Linux 會立刻重用剛釋放的 inode，新檔可能與列舉到的檔案 inode 相同
        real_list = token_stats.list_files
        def swapped(dirs):
            files = real_list(dirs)
            os.rename(self.codex_file(), Path(self.dir.name) / "moved-away.jsonl")
            self.write(self.codex_file(), codex_count(T0, inp=5, out=5))
            return files
        with mock.patch.object(token_stats, "list_files", side_effect=swapped):
            self.scan()
        self.assertEqual({t: self.table(t) for t in before}, before)
        self.scan()  # 下次執行才處理新的檔案
        self.assertEqual(self.totals("codex")[:4], (5, 0, 0, 5))

    def test_cleared_history_recompute_only_clears(self):
        # App 的「清除歷史」把 file_tokens 歸零（對應的加總已刪除）：之後改寫時不會扣成負數或扣到新資料
        self.write(self.codex_file(), codex_count(T0, inp=100, out=10))
        self.write(self.claude_file(), claude_assistant("a1", T0, inp=7, out=7))
        self.scan()
        with self.db() as c:
            c.execute("DELETE FROM daily_tokens")
            c.execute("DELETE FROM hourly_tokens")
            c.execute("DELETE FROM records")
            c.execute("UPDATE file_tokens SET input_tokens = 0, cache_write_tokens = 0, cache_read_tokens = 0,"
                      " output_tokens = 0, reasoning_tokens = 0")
            c.commit()
        self.write(self.codex_file(), codex_count(T0 + DAY, inp=120, out=12))
        self.scan()
        self.assertEqual(self.totals("codex")[:4], (20, 0, 0, 2))
        self.write(self.codex_file(), codex_count(T0, inp=50, out=5), mode="w")
        self.scan()
        self.assertEqual(self.totals("codex")[:4], (50 + 0, 0, 0, 5))

    def test_rewrite_subtracts_then_adds_cached_records(self):
        # 含快取讀取的紀錄（FR-60）與主數字一樣：Codex 改寫時先扣掉該檔的貢獻再重算，結果與一次讀完相同
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=100, cached=60, out=10),
                   codex_count(T0 + 1, inp=500, cached=300, out=50))
        self.scan()
        self.assertEqual(self.records()["total_tokens_cached"][0], 550)
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=40, cached=20, out=4), mode="w")
        self.scan()
        fresh = self.fresh((self.codex_file(), "codex"))
        for key in ("total_tokens_cached", "total_tokens_cached:codex"):
            self.assertEqual(self.records()[key], (44, None))
            self.assertEqual(self.records()[key], self.records(fresh)[key])
        self.assertEqual(self.table("record_days_cached"), [("2026-09-21", "codex", 44)])
        self.assertEqual(self.table("record_days_cached"), self.table("record_days_cached", fresh))

    def test_tasks(self):
        self.write(self.codex_file(), codex_turn(),
                   codex_task("t1", T0, T0 + 30, duration_ms=29_500),
                   codex_task("t1", T0, T0 + 30, duration_ms=29_500),  # 重送
                   codex_task("t2", T0 + 100, T0 + 160))  # 沒有 duration_ms
        self.scan()
        self.assertEqual(self.totals("codex")[5:], (2, 29 + 60))
        self.write(self.codex / "archived_sessions" / f"rollout-x-{OTHER}.jsonl", codex_task("t1", T0, T0 + 30, 29_500))
        self.scan()
        self.assertEqual(self.totals("codex")[5:], (2, 89))


class ScanTest(TokenStatsTestCase):
    def test_chunked_first_scan_reports_progress_and_matches_one_pass(self):
        for i in range(6):
            self.write(self.claude_file(f"{SESSION[:-1]}{i}"), claude_user(T0 + i * DAY),
                       *[claude_assistant(f"m{i}-{j}", T0 + i * DAY + j, inp=j, out=j) for j in range(1, 40)])
        for i in range(3):
            self.write(self.codex_file(f"{ROLLOUT[:-1]}{i}"), codex_turn(),
                       *[codex_count(T0 + i * DAY + j, inp=100 * j, out=10 * j) for j in range(1, 40)])
        progress = []
        for _ in range(100):
            result = self.scan(budget=token_stats.Budget(bytes_left=6000))
            with self.db() as c:
                progress.append(int(c.execute("SELECT value FROM meta WHERE key = 'first_scan_progress'").fetchone()[0]))
            if result.done:
                break
        self.assertTrue(result.done)
        self.assertGreater(len(progress), 5)
        self.assertEqual(progress, sorted(progress))
        self.assertEqual(progress[-1], 100)
        self.assertLess(progress[0], 100)
        files = [(p, "claude") for p in self.project.glob("*.jsonl")] + [(p, "codex") for p in self.sessions.glob("*.jsonl")]
        fresh = self.fresh(*files)
        self.assertEqual(self.table("daily_tokens"), self.table("daily_tokens", fresh))
        self.assertEqual(self.table("hourly_tokens"), self.table("hourly_tokens", fresh))
        self.assertEqual(self.records(), self.records(fresh))
        self.assertIn("首次整理", self.stderr.getvalue())

    def test_time_budget(self):
        self.write(self.claude_file(), claude_assistant("a1", T0, inp=1, out=1))
        result = self.scan(budget=token_stats.Budget(deadline=time.monotonic() - 1))
        self.assertFalse(result.done)
        self.assertEqual(result.processed, 0)

    def test_records(self):
        self.write(self.claude_file(),
                   claude_user(T0), claude_assistant("d1", T0 + 10, inp=100, cr=10_000, out=0),
                   claude_user(T0 + DAY), claude_assistant("d2", T0 + DAY + 500, inp=10, out=0),
                   claude_user(T0 + 2 * DAY), claude_assistant("d3", T0 + 2 * DAY + 20, inp=10, out=0),
                   claude_user(T0 + 5 * DAY), claude_assistant("d6", T0 + 5 * DAY + 20, inp=1, out=0))
        self.write(self.codex_file(), codex_record("r1", T0 + 3 * DAY, inp=5000, out=0))
        self.scan(now=T0 + 6 * DAY)
        records = self.records()
        self.assertEqual(records["total_tokens"][0], 100 + 10 + 10 + 1 + 5000)
        self.assertEqual(records["total_tokens:claude"][0], 121)
        self.assertEqual(records["total_tokens:codex"][0], 5000)
        self.assertEqual(records["best_day_tokens"], (5000, "2026-09-24"))
        self.assertEqual(records["best_day_tokens:claude"], (100, "2026-09-21"))
        self.assertEqual(records["longest_task_seconds"], (500, "2026-09-22"))
        self.assertEqual(records["longest_streak_days"], (4, "2026-09-24"))
        self.assertEqual(records["longest_streak_days:claude"], (3, "2026-09-23"))
        # 保留期間刪掉舊的每日資料後，個人紀錄不變
        with self.db() as c:
            c.execute("DELETE FROM daily_tokens")
            c.commit()
        self.write(self.claude_file(), claude_user(T0 + 6 * DAY), claude_assistant("d7", T0 + 6 * DAY + 5, inp=1, out=0))
        self.scan(now=T0 + 7 * DAY)
        self.assertEqual(self.records()["best_day_tokens"], (5000, "2026-09-24"))
        self.assertEqual(self.records()["longest_streak_days"], (4, "2026-09-24"))
        self.assertEqual(self.records()["total_tokens"][0], 5122)

    def test_cached_records(self):
        # 含快取讀取的單日最高與累計（FR-60）：快取讀取多的那天變成最高；連續天數不變；保留期間刪掉每日資料後不變
        self.write(self.claude_file(),
                   claude_user(T0), claude_assistant("d1", T0 + 10, inp=100, cr=10_000, out=0),
                   claude_user(T0 + DAY), claude_assistant("d2", T0 + DAY + 5, inp=10, cr=5, out=0))
        self.write(self.codex_file(), codex_record("r1", T0 + 3 * DAY, inp=5000, cached=1000, out=0))
        self.scan(now=T0 + 4 * DAY)
        records = self.records()
        self.assertEqual(records["total_tokens"][0], 100 + 10 + 4000)
        self.assertEqual(records["total_tokens_cached"][0], 10_100 + 15 + 5000)
        self.assertEqual(records["total_tokens_cached:claude"][0], 10_115)
        self.assertEqual(records["total_tokens_cached:codex"][0], 5000)
        self.assertEqual(records["best_day_tokens"], (4000, "2026-09-24"))
        self.assertEqual(records["best_day_tokens_cached"], (10_100, "2026-09-21"))
        self.assertEqual(records["best_day_tokens_cached:codex"], (5000, "2026-09-24"))
        self.assertNotIn("longest_streak_days_cached", records)
        with self.db() as c:
            c.execute("DELETE FROM daily_tokens")
            c.commit()
        self.write(self.claude_file(), claude_assistant("d5", T0 + 4 * DAY + 5, inp=1, cr=1, out=0))
        self.scan(now=T0 + 5 * DAY)
        self.assertEqual(self.records()["best_day_tokens_cached"], (10_100, "2026-09-21"))
        self.assertEqual(self.records()["total_tokens_cached"][0], 15_117)

    def test_retention_skips_old_rows_but_counts_records(self):
        self.write(self.claude_file(), claude_assistant("old", T0 - 400 * DAY, inp=10, out=0),
                   claude_assistant("hour", T0 - 100 * DAY, inp=20, out=0),
                   claude_assistant("new", T0, inp=30, out=0))
        self.scan(now=T0 + HOUR)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT SUM(input_tokens) FROM daily_tokens").fetchone()[0], 50)
            self.assertEqual(c.execute("SELECT SUM(input_tokens) FROM hourly_tokens").fetchone()[0], 30)
        self.assertEqual(self.records()["total_tokens"][0], 60)

    def test_records_ignore_retention(self):
        # 首次掃描的紀錄全部超過保留期間：單日最高與連續天數仍要算出來
        self.write(self.claude_file(), *[claude_assistant(f"old{i}", T0 - (400 - i) * DAY, inp=1000, out=0) for i in range(3)])
        self.scan(now=T0)
        records = self.records()
        self.assertEqual(records["total_tokens"][0], 3000)
        self.assertEqual(records["best_day_tokens"][0], 1000)
        self.assertEqual(records["longest_streak_days"][0], 3)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM daily_tokens").fetchone()[0], 0)
        # 保留 7 天、連續使用 12 天：最長連續天數是 12
        with self.db() as c:
            c.execute("UPDATE meta SET value = '7' WHERE key = 'retention_days'")
            c.commit()
        for i in range(12):
            self.write(self.claude_file(), claude_assistant(f"d{i}", T0 + i * DAY, inp=1, out=0))
            self.scan(now=T0 + i * DAY + HOUR)
            conn = history.connect(self.path)
            history.cleanup(conn, T0 + i * DAY + HOUR)
            conn.close()
        self.assertEqual(self.records()["longest_streak_days"][0], 12)

    def test_cleanup_applies_retention_to_token_tables(self):
        self.write(self.claude_file(), claude_assistant("a", T0 - 50 * DAY, inp=1, out=0),
                   claude_assistant("b", T0 - 5 * DAY, inp=2, out=0))
        self.scan(now=T0)
        conn = history.connect(self.path)
        conn.execute("UPDATE meta SET value = '30' WHERE key = 'retention_days'")
        conn.execute("UPDATE scan_state SET last_seen = ?", (T0 - 91 * DAY,))
        history.cleanup(conn, T0)
        self.assertEqual(conn.execute("SELECT SUM(input_tokens) FROM daily_tokens").fetchone()[0], 2)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM scan_state").fetchone()[0], 0)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM seen_ids").fetchone()[0], 2)  # cleanup 不動去重表
        conn.close()

    def test_unchanged_files_are_not_reopened(self):
        self.write(self.claude_file(), claude_assistant("a", T0, inp=1, out=0))
        self.scan()
        with mock.patch.object(token_stats.os, "open", side_effect=AssertionError("reopened")):
            result = self.scan()
        self.assertEqual(result.processed, 0)

    def test_volume_serial_above_signed_64_bits_is_counted(self):
        # Windows 的 st_dev 可能 ≥ 2⁶³：要能存進 scan_state，第二次掃描也認得是同一個檔案
        def big(st):
            t = list(st[:10])
            t[2] = 11962255239693178705
            return os.stat_result(t)
        entry_stat, fstat = system.entry_stat, token_stats.os.fstat
        with mock.patch.object(system, "entry_stat", lambda e: big(entry_stat(e))), \
                mock.patch.object(token_stats.os, "fstat", lambda fd: big(fstat(fd))):
            self.write(self.claude_file(), claude_assistant("a", T0, inp=3, out=4))
            self.scan()
            self.write(self.claude_file(), claude_assistant("b", T0 + 1, inp=3, out=4))
            self.scan()
        self.assertEqual(self.totals("claude")[:4], (6, 0, 0, 8))
        self.assertNotIn("OverflowError", self.stderr.getvalue())

    def test_locked_database_gives_up_once(self):
        for i in range(5):
            self.write(self.claude_file(f"{SESSION[:-1]}{i}"), claude_assistant(f"a{i}", T0, inp=1, out=1))
        history.connect(self.path).close()
        holder = sqlite3.connect(self.path, isolation_level=None)
        holder.execute("BEGIN IMMEDIATE")
        try:
            with mock.patch.object(history, "BUSY_TIMEOUT_MS", 100), mock.patch.object(token_stats.system, "lower_priority"), \
                 redirect_stderr(self.stderr):
                started = time.monotonic()
                with mock.patch.object(token_stats, "log_dirs", return_value=self.dirs):
                    self.assertFalse(token_stats.run_safely(self.path))
                elapsed = time.monotonic() - started
        finally:
            holder.rollback()
            holder.close()
        self.assertLess(elapsed, 1.5)
        self.assertIn("OperationalError", self.stderr.getvalue())

    def test_run_safely_never_raises(self):
        with mock.patch.object(token_stats, "run", side_effect=sqlite3.OperationalError("database is locked /Users/fake")), \
             mock.patch.object(token_stats.system, "lower_priority"), redirect_stderr(self.stderr):
            self.assertFalse(token_stats.run_safely(self.path))
        self.assertNotIn("/Users/fake", self.stderr.getvalue())
        self.assertIn("OperationalError", self.stderr.getvalue())

    def test_normal_run_overhead(self):
        """一般情況（首次掃描完成後、少量新增）每次執行增加的時間 < 1 秒（ADR-0009 第 7 節）。"""
        for i in range(300):
            self.write(self.claude_file(f"{SESSION[:-3]}{i:03d}"), claude_user(T0),
                       *[claude_assistant(f"m{i}-{j}", T0 + j, inp=j, out=j) for j in range(20)])
        for i in range(50):
            self.write(self.codex_file(f"{ROLLOUT[:-3]}{i:03d}"), codex_turn(),
                       *[codex_record(f"r{i}-{j}", T0 + j, inp=100, out=10) for j in range(20)])
        self.scan()
        self.write(self.claude_file(f"{SESSION[:-3]}000"), claude_assistant("new", T0 + 99, inp=1, out=1))
        started = time.monotonic()
        self.scan()
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 1.0)

    def test_run_that_advances_the_window_stays_fast(self):
        """時間窗內的去重列到上限（90 天 × 每天 3,000 則 ≈ 27 萬列）、這一輪 D 前進一天並刪一天的列：仍 < 1 秒。"""
        self.write(self.claude_file(), claude_assistant("a", T0, inp=1, out=1))
        self.scan()
        start = datetime(2026, 6, 23, tzinfo=TAIPEI)
        with self.db() as c:
            c.executemany("INSERT INTO seen_ids (provider, id, day, hour, model, input_tokens) VALUES (?, ?, ?, 0, ?, 1)",
                          (("claude", f"msg_{d:03d}_{i:05d}_0123456789abcdef", (start + timedelta(days=d)).date().isoformat(),
                            "claude-opus-5-5") for d in range(91) for i in range(3000)))
            c.commit()
        self.write(self.claude_file(), claude_assistant("new", T0 + DAY, inp=1, out=1))
        started = time.monotonic()
        self.scan(now=T0 + 2 * DAY)
        elapsed = time.monotonic() - started
        with self.db() as c:
            self.assertEqual(c.execute("SELECT value FROM meta WHERE key = 'seen_cutoff_day'").fetchone()[0], "2026-06-25")
            self.assertEqual(c.execute("SELECT COUNT(*) FROM seen_ids WHERE day < '2026-06-24'").fetchone()[0], 0)
        # 本機約 0.4 秒（前進與刪除只佔 0.01 秒，其餘是一般掃描）；CI 的 Windows 機器曾跑到 1.1 秒，門檻放寬到 2 秒
        self.assertLess(elapsed, 2.0)


class SeenWindowTest(TokenStatsTestCase):
    """去重時間窗（ADR-0014 第 1 節）：略過界 D 以前的訊息不計算也不記錄；一次讀完、分批讀、重掃、舊副本重現結果相同。"""

    def cutoff(self, path=None):
        with self.db(path) as c:
            row = c.execute("SELECT value FROM meta WHERE key = 'seen_cutoff_day'").fetchone()
        return row[0] if row else None

    def prime(self, path):
        """首次掃描已完成（沒有紀錄檔），略過界設好：之後的掃描都是一般的增量掃描。"""
        empty = Path(self.dir.name) / f"empty-{path.parent.name}"
        with redirect_stderr(io.StringIO()):
            token_stats.run(path, {"claude": empty / "claude", "codex": empty / "codex"}, now=T0 + DAY)

    def spread(self):
        """T0 往前 0～200 天、每 10 天一則：Claude 訊息、Codex record 與 Codex token_count（累計值）各一檔。"""
        self.write(self.claude_file(), *[claude_assistant(f"m{k}", T0 - k * 10 * DAY, inp=k + 1, out=1)
                                         for k in range(20, -1, -1)])
        self.write(self.codex_file(), codex_turn(), *[codex_record(f"r{k}", T0 - k * 10 * DAY, inp=100 * (k + 1), out=1)
                                                      for k in range(20, -1, -1)])
        total = 0
        lines = [codex_turn()]
        for k in range(20, -1, -1):
            total += 1000 * (k + 1)
            lines.append(codex_count(T0 - k * 10 * DAY, inp=total, out=0))
        self.write(self.codex_file(OTHER), *lines)

    def counted(self, path=None):
        with self.db(path) as c:
            return dict(c.execute("SELECT provider, SUM(input_tokens) FROM daily_tokens GROUP BY provider").fetchall())

    def snapshot(self, path=None):
        return [self.table(t, path) for t in ("daily_tokens", "hourly_tokens", "record_days", "record_days_cached")] \
            + [self.records(path)]

    def test_one_pass_batched_and_rescan_agree(self):
        self.prime(self.path)
        self.assertEqual(self.cutoff(), "2026-06-24")  # 2026-09-22（掃描當天）往前 90 天
        self.spread()
        for _ in range(200):
            result = self.scan(budget=token_stats.Budget(bytes_left=1500))
            if result.done and result.processed == 0:
                break
        one_pass = Path(self.dir.name) / "one" / "history.sqlite3"
        self.prime(one_pass)
        with redirect_stderr(io.StringIO()):
            token_stats.run(one_pass, self.dirs, now=T0 + DAY)
        self.assertEqual(self.snapshot(), self.snapshot(one_pass))
        # 只算 D 以後的：往前 0～80 天（k = 0～8）；90 天前是 06-23，早於 D
        in_window = range(9)
        self.assertEqual(self.counted(), {"claude": sum(k + 1 for k in in_window),
                                          "codex": sum(100 * (k + 1) + 1000 * (k + 1) for k in in_window)})
        with self.db() as c:
            for table in token_stats.SEEN_TABLES:
                self.assertEqual(c.execute(f"SELECT COUNT(*) FROM {table} WHERE day < '2026-06-24'").fetchone()[0], 0)
        # 重掃（掃描進度不見了，例如 90 天沒看到的檔案又出現）：每個檔案從頭讀，結果不變
        before = self.snapshot()
        with self.db() as c:
            c.execute("DELETE FROM scan_state")
            c.commit()
        self.scan()
        self.scan()
        self.assertEqual(self.snapshot(), before)

    def test_old_copy_after_the_window_is_not_counted_again(self):
        self.prime(self.path)
        self.write(self.claude_file(), claude_assistant("old", T0, inp=100, out=1))
        self.scan()
        # 時間往前走 100 天（每天一輪）：D 走過 T0，"old" 的去重列被刪
        for day in range(1, 101):
            self.scan(now=T0 + DAY + day * DAY)
        self.assertEqual(self.cutoff(), history.local_day(T0 + 101 * DAY - token_stats.SEEN_DAYS * DAY))
        with self.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM seen_ids WHERE id = 'old'").fetchone()[0], 0)
        before = self.snapshot()
        # --resume 把舊訊息（原始時間戳，數字甚至更大）複製到新檔：不計入、不記錄
        self.write(self.claude_file(OTHER), claude_assistant("old", T0, inp=500, out=9),
                   claude_assistant("new", T0 + 101 * DAY, inp=7, out=0))
        self.scan(now=T0 + 101 * DAY)
        after = self.snapshot()
        self.assertEqual(after[-1]["total_tokens"][0], before[-1]["total_tokens"][0] + 7)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM seen_ids WHERE id = 'old'").fetchone()[0], 0)

    def test_copy_inside_the_window_adds_only_the_difference_once(self):
        self.prime(self.path)
        self.write(self.claude_file(), claude_assistant("a", T0 - 30 * DAY, inp=10, out=1))
        self.scan()
        self.write(self.claude_file(OTHER), claude_assistant("a", T0 - 30 * DAY, inp=15, out=1))
        self.scan()
        self.scan()
        self.assertEqual(self.counted(), {"claude": 15})

    def test_boundary_days(self):
        self.prime(self.path)
        cutoff = datetime(2026, 6, 24, 12, tzinfo=TAIPEI).timestamp()
        self.write(self.claude_file(), claude_assistant("on", int(cutoff), inp=1, out=0),
                   claude_assistant("day-1", int(cutoff - DAY), inp=10, out=0),
                   claude_assistant("day-2", int(cutoff - 2 * DAY), inp=100, out=0))
        self.scan()
        self.assertEqual(self.counted(), {"claude": 1})
        # 去重表留 D − 1 那天的列（吸收時區差），更早的刪掉
        with self.db() as c:
            c.execute("INSERT INTO seen_ids (provider, id, day, hour, model) VALUES ('claude', 'x1', '2026-06-23', 0, 'm'),"
                      " ('claude', 'x2', '2026-06-22', 0, 'm')")
            c.commit()
        self.scan(now=T0 + DAY + 60)
        with self.db() as c:
            self.assertEqual(sorted(r[0] for r in c.execute("SELECT id FROM seen_ids")), ["on", "x1"])

    def test_clock_jumps(self):
        self.prime(self.path)
        self.write(self.claude_file(), claude_assistant("a", T0, inp=1, out=0))
        self.scan()
        # 時鐘被設到一年後：D 最多前進兩天
        self.scan(now=T0 + 400 * DAY)
        self.assertEqual(self.cutoff(), "2026-06-26")
        # 改回來（比 D 對應的時間早）：D 不動、不刪；今天的新訊息照算
        self.write(self.claude_file(), claude_assistant("b", T0 + DAY, inp=2, out=0))
        self.scan(now=T0 + DAY + 60)
        self.assertEqual(self.cutoff(), "2026-06-26")
        # 倒退 10 天：D 不動，副本不重算
        self.write(self.claude_file(OTHER), claude_assistant("a", T0, inp=1, out=0))
        self.scan(now=T0 - 10 * DAY)
        self.assertEqual(self.cutoff(), "2026-06-26")
        self.assertEqual(self.counted(), {"claude": 3})

    def test_clock_ahead_for_many_runs_moves_the_cutoff_a_few_days(self):
        """時鐘被設到一年後、維持 8 小時（96 輪）：每個日期最多前進兩天（不是每輪）；改回後新訊息照算（總檢查 F-01）。"""
        self.prime(self.path)
        self.write(self.claude_file(), claude_assistant("a", T0, inp=1, out=0))
        self.scan()
        for i in range(96):
            self.scan(now=T0 + 400 * DAY + i * 300)
        self.assertEqual(self.cutoff(), "2026-06-28")  # 21:33 開始的 8 小時跨過一次午夜：兩個日期各兩天
        self.write(self.claude_file(), claude_assistant("b", T0 + DAY, inp=10, out=0))
        self.scan(now=T0 + DAY + 3600)
        for d in range(1, 4):
            self.write(self.claude_file(), claude_assistant(f"c{d}", T0 + (d + 1) * DAY, inp=100, out=0))
            self.scan(now=T0 + (d + 1) * DAY + 3600)
        self.assertEqual(self.counted(), {"claude": 311})
        self.assertEqual(self.cutoff(), "2026-06-28")  # 只進不退，等目標追上

    def test_cutoff_never_passes_the_newest_message(self):
        """升級那一輪時鐘剛好超前一年：D 不超過去重表裡最新的日期，不會跑到未來；時鐘改回後新訊息照算、
        舊訊息的副本不重複計入（總檢查 F-01、審查 C-01）。"""
        self.write(self.claude_file(), claude_assistant("a", T0, inp=1, out=0))
        self.scan_before_seen_window()
        self.scan(now=T0 + 400 * DAY)
        self.assertEqual(self.cutoff(), "2026-09-21")
        self.write(self.claude_file(), claude_assistant("b", T0 + DAY, inp=10, out=0))
        self.write(self.claude_file(OTHER), claude_assistant("a", T0, inp=1, out=0))  # --resume 的副本
        self.scan(now=T0 + DAY + 3600)
        self.assertEqual(self.counted(), {"claude": 11})
        self.assertEqual(self.cutoff(), "2026-09-21")

    def test_cutoff_catches_up_after_the_collector_stopped(self):
        """收集器停了 30 天：恢復後每天前進兩天，落差每天縮小一天，30 天後回到「今天往前 90 天」（審查 C-02）。"""
        self.write(self.claude_file(), claude_assistant("a", T0, inp=1, out=0))
        self.scan()
        self.assertEqual(self.cutoff(), "2026-06-24")
        for d in range(31, 62):
            self.write(self.claude_file(), claude_assistant(f"m{d}", T0 + d * DAY, inp=1, out=0))
            self.scan(now=T0 + d * DAY + 3600)
        with self.db() as c:
            self.assertEqual(self.cutoff(), history.local_day(T0 + 61 * DAY + 3600 - token_stats.SEEN_DAYS * DAY))
            prune_before = (date.fromisoformat(self.cutoff()) - timedelta(days=1)).isoformat()
            self.assertEqual(c.execute("SELECT COUNT(*) FROM seen_ids WHERE day < ?", (prune_before,)).fetchone()[0], 0)
        self.assertEqual(self.counted(), {"claude": 32})

    def test_codex_rewrite_across_the_window_keeps_old_days(self):
        self.write(self.codex_file(), codex_turn(), codex_count(T0 - 120 * DAY, inp=1000, out=0),
                   codex_count(T0, inp=1500, out=0))
        self.scan()  # 首次掃描：不略過，兩段都計入
        self.assertEqual(self.counted(), {"codex": 1500})
        self.assertEqual(self.cutoff(), "2026-06-24")
        with self.db() as c:  # T0 − 120 天的帳本列已刪
            self.assertEqual(c.execute("SELECT COUNT(*) FROM file_tokens WHERE day < '2026-06-23'").fetchone()[0], 0)
        old_day = self.table("daily_tokens")[0]
        # 改寫（同樣內容、mtime 倒退 → 重算）：只扣 D 以後的帳本；舊事件重讀時略過，舊日子的數字不動
        self.write(self.codex_file(), codex_turn(), codex_count(T0 - 120 * DAY, inp=1000, out=0),
                   codex_count(T0, inp=1500, out=0), mode="w")
        os.utime(self.codex_file(), (T0 - DAY, T0 - DAY))
        self.scan()
        self.scan()
        self.assertEqual(self.counted(), {"codex": 1500})
        self.assertEqual(self.table("daily_tokens")[0], old_day)
        self.assertEqual(self.records()["total_tokens"][0], 1500)

    def test_leftover_old_ledger_rows_are_not_subtracted(self):
        """分段刪除還沒刪到的舊帳本列：改寫該檔時不能扣掉（那些事件不會再加回來）。"""
        self.prime(self.path)
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=50, out=0))
        self.scan()
        with self.db() as c:
            fk = c.execute("SELECT file_key FROM file_tokens").fetchone()[0]
            c.execute("INSERT INTO file_tokens (file_key, day, hour, model, input_tokens, cache_write_tokens,"
                      " cache_read_tokens, output_tokens, reasoning_tokens) VALUES (?, '2026-05-01', 0, 'gpt-6.1-sol',"
                      " 999, 0, 0, 0, 0)", (fk,))
            c.commit()
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=50, out=0), mode="w")
        os.utime(self.codex_file(), (T0 - DAY, T0 - DAY))
        self.scan()
        self.assertEqual(self.counted(), {"codex": 50})
        self.assertEqual(self.records()["total_tokens"][0], 50)

    def test_upgrade_prunes_existing_rows_in_chunks(self):
        self.write(self.claude_file(), *[claude_assistant(f"o{i}", T0 - 200 * DAY + i, inp=1, out=0) for i in range(12)],
                   claude_assistant("n", T0, inp=1, out=0))
        self.scan_before_seen_window()
        totals = self.snapshot()
        with mock.patch.object(token_stats, "SEEN_PRUNE_ROWS", 5):
            counts = []
            for _ in range(4):
                self.scan()
                with self.db() as c:
                    counts.append(c.execute("SELECT COUNT(*) FROM seen_ids").fetchone()[0])
        self.assertEqual(counts, [8, 3, 1, 1])
        self.assertEqual(self.snapshot(), totals)

    def test_first_scan_counts_the_whole_history(self):
        self.write(self.claude_file(), claude_assistant("old", T0 - 200 * DAY, inp=100, out=0),
                   claude_assistant("new", T0, inp=1, out=0))
        self.scan()
        self.assertEqual(self.records()["total_tokens"][0], 101)
        self.assertEqual(self.cutoff(), "2026-06-24")
        with self.db() as c:
            self.assertEqual([r[0] for r in c.execute("SELECT id FROM seen_ids")], ["new"])

    def test_rescan_from_the_app_rebuilds_the_whole_history(self):
        self.write(self.claude_file(), claude_assistant("old", T0 - 200 * DAY, inp=100, out=0),
                   claude_assistant("new", T0, inp=1, out=0))
        self.scan()
        # 舊版 App 的「清除並重新掃描」：清空統計、去重表與掃描進度，刪 first_scan_done，但留著略過界
        with self.db() as c:
            for table in ("daily_tokens", "hourly_tokens", "records", "record_days", "record_days_cached",
                          "scan_state", "seen_ids", "seen_tasks", "file_tokens"):
                c.execute(f"DELETE FROM {table}")
            c.execute("DELETE FROM meta WHERE key IN ('first_scan_progress', 'first_scan_done')")
            c.commit()
        self.scan()
        self.assertEqual(self.records()["total_tokens"][0], 101)
        self.assertEqual(self.cutoff(), "2026-06-24")

    def test_tasks_started_before_the_cutoff_are_skipped(self):
        self.prime(self.path)
        old_start = int(datetime(2026, 6, 23, 23, tzinfo=TAIPEI).timestamp())
        self.write(self.codex_file(), codex_turn(), codex_task("t-old", old_start, old_start + 7200),
                   codex_task("t-new", T0, T0 + 60))
        self.scan()
        with self.db() as c:
            self.assertEqual(c.execute("SELECT SUM(task_count), SUM(task_seconds) FROM daily_tokens").fetchone(), (1, 60))

    # 以下是審查 C-01～C-03：Codex 重算分成幾輪讀時略過界前進、並行收集器、改時區
    def on_cutoff_day(self):
        return int(datetime(2026, 6, 24, 12, tzinfo=TAIPEI).timestamp())  # 略過界 D 當天

    def rewrite(self, *lines, mtime=T0 - DAY):
        """改寫（mtime 倒退）：Codex 會扣掉這個檔案的帳本、從頭重算"""
        self.write(self.codex_file(), *lines, mode="w")
        os.utime(self.codex_file(), (mtime, mtime))

    def file_state(self):
        with self.db() as c:
            row = c.execute("SELECT state FROM scan_state WHERE file_key LIKE 'codex%'").fetchone()  # 只有一個 Codex 檔
        return json.loads(row[0]) if row and row[0] else {}

    def test_codex_recount_split_across_runs_while_the_cutoff_advances(self):
        """重算的第一輪只讀到 turn_context（帳本已扣、事件還沒重讀），兩輪之間 D 前進一天：
        D 當天的事件仍要補回來（凍結重算開始時的 D，審查 C-01；舊版漏掉 1000）。"""
        self.prime(self.path)
        lines = (codex_turn(), codex_count(self.on_cutoff_day(), inp=1000, out=0), codex_count(T0, inp=1500, out=0))
        self.write(self.codex_file(), *lines)
        self.scan()
        self.assertEqual(self.counted(), {"codex": 1500})
        self.rewrite(*lines)
        result = self.scan(budget=token_stats.Budget(bytes_left=len(lines[0]) + 1), now=T0 + 2 * DAY)
        self.assertFalse(result.done)
        self.assertEqual(self.cutoff(), "2026-06-25")
        self.assertEqual(self.file_state().get("cutoff"), "2026-06-24")
        for _ in range(2):
            self.scan(now=T0 + 3 * DAY)
        self.assertEqual(self.counted(), {"codex": 1500})
        self.assertEqual(self.records()["total_tokens"][0], 1500)
        self.assertNotIn("cutoff", self.file_state())  # 讀到檔尾就放開

    def test_codex_recount_split_across_the_upgrade_run(self):
        """升級前（沒有略過界）計入的舊事件：升級那一輪剛好在重算中途設定 D，舊事件仍照原樣補回（審查 C-01）。"""
        lines = (codex_turn(), codex_count(T0 - 120 * DAY, inp=1000, out=0), codex_count(T0, inp=1500, out=0))
        self.write(self.codex_file(), *lines)
        self.scan_before_seen_window()
        self.assertIsNone(self.cutoff())
        self.assertEqual(self.counted(), {"codex": 1500})
        self.rewrite(*lines)
        self.scan(budget=token_stats.Budget(bytes_left=len(lines[0]) + 1), now=T0 + DAY)
        self.assertEqual(self.cutoff(), "2026-06-24")
        self.assertEqual(self.file_state().get("cutoff"), "")  # 凍結為「不設界」
        for _ in range(2):
            self.scan(now=T0 + DAY)
        self.assertEqual(self.counted(), {"codex": 1500})

    def test_rewrite_again_during_a_split_recount(self):
        """分輪重算還沒讀完又被改寫：以新的 D 重新凍結，結果和以目前的 D 一次讀完最後的內容相同。"""
        self.prime(self.path)
        on_d = self.on_cutoff_day()
        self.write(self.codex_file(), codex_turn(), codex_count(on_d, inp=1000, out=0), codex_count(T0, inp=1500, out=0))
        self.scan()
        self.rewrite(codex_turn(), codex_count(on_d, inp=400, out=0), codex_count(T0, inp=900, out=0))
        self.scan(budget=token_stats.Budget(bytes_left=len(codex_turn()) + 1), now=T0 + 2 * DAY)
        self.rewrite(codex_turn(), codex_count(on_d, inp=300, out=0), codex_count(T0, inp=700, out=0), mtime=T0 - 2 * DAY)
        for _ in range(2):
            self.scan(now=T0 + 3 * DAY)
        self.assertEqual(self.cutoff(), "2026-06-26")
        # 第二次改寫時的 D（06-25）以前的 06-24 只接上累計值、不計入：T0 那筆是 700 − 300
        self.assertEqual(self.counted(), {"codex": 400})
        self.assertNotIn("cutoff", self.file_state())

    def test_events_appended_after_a_recount_use_the_current_cutoff(self):
        """凍結只到讀完為止：之後附加、日期早於目前 D 的事件照樣略過。"""
        self.prime(self.path)
        self.write(self.codex_file(), codex_turn(), codex_count(T0, inp=100, out=0))
        self.scan()
        self.write(self.codex_file(), codex_count(T0 - 100 * DAY, inp=300, out=0))
        self.scan()
        self.assertEqual(self.counted(), {"codex": 100})

    def test_concurrent_collector_advances_the_cutoff_twice(self):
        """A 開始掃描後，另一個收集器跑了兩輪（D 06-24 → 06-26，刪掉 day < 06-25 的去重列）：
        A 不能用舊的 D 把副本裡的同一則訊息再算一次，也不能把 D 寫回較早的日期（審查 C-02）。"""
        self.prime(self.path)
        on_d = self.on_cutoff_day()
        self.write(self.claude_file(), claude_assistant("x", on_d, inp=100, out=0))
        self.scan()
        self.write(self.claude_file(OTHER), claude_assistant("x", on_d, inp=100, out=0))  # --resume 的副本
        original = history._transaction
        other_ran = []

        @contextmanager
        def racing(conn):
            if not other_ran:
                other_ran.append(True)
                empty = Path(self.dir.name) / "empty-b"
                for later in (T0 + 2 * DAY, T0 + 3 * DAY):
                    with redirect_stderr(io.StringIO()):
                        token_stats.run(self.path, {"claude": empty / "claude", "codex": empty / "codex"}, now=later)
            with original(conn):
                yield

        with mock.patch.object(history, "_transaction", racing):
            self.scan(now=T0 + DAY)
        self.assertTrue(other_ran)
        self.assertEqual(self.counted(), {"claude": 100})
        self.assertEqual(self.cutoff(), "2026-06-26")

    def test_clear_and_rescan_during_a_run_does_not_mark_the_first_scan_done(self):
        """App 的「清除並重新掃描」落在一輪中間（交易外判斷檔案沒變之後、最後一個交易之前）：這一輪不能標記
        首次掃描完成、不能設略過界，下一輪才會重建完整歷史（Codex 200 天前的紀錄也算回來；總檢查 F-02）。"""
        self.write(self.codex_file(), codex_turn(), codex_count(T0 - 200 * DAY, inp=100, out=0),
                   codex_count(T0, inp=101, out=0))
        self.scan()
        self.assertEqual(self.counted(), {"codex": 101})
        original = history._transaction
        cleared = []

        @contextmanager
        def racing(conn):
            if not cleared:  # 檔案都沒變：第一個交易就是最後一個，App 在它拿到鎖之前清除
                cleared.append(True)
                with self.db() as other:
                    for t in ("daily_tokens", "hourly_tokens", "records", "record_days", "record_days_cached",
                              "scan_state", "seen_ids", "seen_tasks", "file_tokens"):
                        other.execute(f"DELETE FROM {t}")
                    other.execute("DELETE FROM meta WHERE key IN ('first_scan_progress', 'first_scan_done',"
                                  " 'token_bad_lines', 'token_long_lines', 'token_days_from', 'seen_cutoff_day')")
                    other.commit()
            with original(conn):
                yield

        with mock.patch.object(history, "_transaction", racing):
            self.scan(now=T0 + DAY + 300)
        self.assertTrue(cleared)
        with self.db() as c:
            self.assertIsNone(c.execute("SELECT value FROM meta WHERE key = 'first_scan_done'").fetchone())
        self.assertIsNone(self.cutoff())
        self.scan(now=T0 + DAY + 600)
        self.scan(now=T0 + DAY + 900)
        self.assertEqual(self.counted(), {"codex": 101})
        self.assertEqual(self.records()["total_tokens"][0], 101)
        self.assertEqual(self.cutoff(), "2026-06-24")

    @unittest.skipIf(sys.platform == "win32" or os.geteuid() == 0, "chmod 000 擋不住 Windows 與 root")
    def test_unreadable_file_still_lets_the_first_scan_finish(self):
        """打不開的檔案沒有掃描進度列，但首次掃描照樣完成（ADR-0014 LT-19：下一輪再讀）。"""
        self.write(self.claude_file(), claude_assistant("a", T0, inp=1, out=0))
        self.write(self.claude_file(OTHER), claude_assistant("b", T0, inp=2, out=0))
        os.chmod(self.claude_file(OTHER), 0)
        try:
            self.scan()
        finally:
            os.chmod(self.claude_file(OTHER), 0o600)
        self.assertEqual(self.counted(), {"claude": 1})
        with self.db() as c:
            self.assertEqual(c.execute("SELECT value FROM meta WHERE key = 'first_scan_done'").fetchone()[0], "1")

    @unittest.expectedFailure
    def test_timezone_change_then_codex_rewrite(self):
        """已知限制（ADR-0014 第 1 節）：帳本只記當時時區的日期，改時區後重算一個含 D 附近事件的 Codex 檔，
        那幾小時可能多算或少算。需要「改時區＋Codex 改寫 90 天前的紀錄」同時發生，Codex 不改寫舊的 rollout。"""
        west = timezone(timedelta(hours=-7))
        event = int(datetime(2026, 6, 24, 1, tzinfo=timezone.utc).timestamp())  # UTC−7 是 06-23，台北是 06-24
        lines = (codex_turn(), codex_count(event, inp=100, out=0), codex_count(T0, inp=150, out=0))
        self.write(self.codex_file(), *lines)
        with mock.patch.object(system, "local_datetime", lambda ts: datetime.fromtimestamp(ts, west).replace(tzinfo=None)):
            self.scan()
        self.assertEqual(self.cutoff(), "2026-06-24")
        self.rewrite(*lines)
        self.scan()
        self.assertEqual(self.counted(), {"codex": 150})


class FormatChangeTest(TokenStatsTestCase):
    """紀錄格式改變的偵測（ADR-0009 第 9 節）：門檻保守，證據不足時沿用上次的判斷。"""

    def meta(self, key):
        with self.db() as c:
            row = c.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def test_normal_logs_are_not_suspect(self):
        lines = []
        for i in range(60):
            lines += [claude_user(T0 + i * 60), claude_assistant(f"m{i}", T0 + i * 60 + 5, inp=1, out=1)]
        self.write(self.claude_file(), *lines)
        self.scan()
        self.assertEqual(self.meta("token_format_suspect"), "0")
        scan = json.loads(self.meta("token_format_scan"))
        self.assertEqual((scan["candidates"], scan["bad"], scan["token_lines"]), (120, 0, 60))

    def test_many_unparseable_lines_are_suspect_then_clear(self):
        good = [claude_assistant(f"m{i}", T0 + i, inp=1, out=1) for i in range(80)]
        # 新格式：通過位元組篩選但缺少 message.id／requestId 等必要欄位
        bad = [json.dumps({"type": "assistant", "timestamp": iso(T0 + i), "usage": {"input_tokens": 1}})
               for i in range(30)]
        self.write(self.claude_file(), *good, *bad)
        self.scan()
        self.assertEqual(self.meta("token_format_suspect"), "1")  # 30／110 ≥ 20%
        # 下一次只有少量新行：證據不足，維持「可能已改變」
        self.write(self.claude_file(), *[claude_assistant(f"n{i}", T0 + 500 + i, inp=1, out=1) for i in range(5)])
        self.scan()
        self.assertEqual(self.meta("token_format_suspect"), "1")
        # 之後又有足夠的正常紀錄：清除
        self.write(self.claude_file(), *[claude_assistant(f"k{i}", T0 + 900 + i, inp=1, out=1) for i in range(120)])
        self.scan()
        self.assertEqual(self.meta("token_format_suspect"), "0")

    def test_few_bad_lines_are_below_threshold(self):
        good = [claude_assistant(f"m{i}", T0 + i, inp=1, out=1) for i in range(100)]
        self.write(self.claude_file(), *good, *["not json \"user\""] * 10)
        self.scan()
        self.assertEqual(self.meta("token_format_suspect"), "0")  # 10／110 < 20%

    def test_lots_of_new_bytes_without_any_token_line_is_suspect(self):
        # 欄位改名之後所有行都通不過位元組篩選：沒有候選行，但新內容很多
        renamed = json.dumps({"kind": "reply", "tokens": {"in": 1}, "pad": "z" * 2000})
        self.write(self.codex_file(), *[renamed] * 40)
        with mock.patch.object(token_stats, "FORMAT_MIN_BYTES", 64 * 1024):
            self.scan()
        self.assertEqual(self.meta("token_format_suspect"), "1")

    def test_skipped_long_lines_do_not_count_as_read(self):
        # 貼上的圖片（base64 的 user 行）超過上限被丟棄、回覆還沒寫進檔案：不是格式改變
        self.write(self.claude_file(), json.dumps({"type": "user", "message": {"content": "z" * (300 * 1024)}}))
        with mock.patch.object(token_stats, "MAX_LINE_BYTES", 64 * 1024), \
                mock.patch.object(token_stats, "SKIP_CHUNK_BYTES", 16 * 1024), \
                mock.patch.object(token_stats, "FORMAT_MIN_BYTES", 256 * 1024):
            self.scan()
        self.assertIsNone(self.meta("token_format_suspect"))

    def test_a_modest_amount_of_normal_logs_clears_the_warning(self):
        bad = [json.dumps({"type": "assistant", "timestamp": iso(T0 + i), "usage": {"input_tokens": 1}})
               for i in range(100)]
        self.write(self.claude_file(), *bad)
        self.scan()
        self.assertEqual(self.meta("token_format_suspect"), "1")
        lines = []
        for i in range(10):  # 10 個正常的回合（20 行候選）
            lines += [claude_user(T0 + 900 + i * 60), claude_assistant(f"k{i}", T0 + 905 + i * 60, inp=1, out=1)]
        self.write(self.claude_file(), *lines)
        self.scan()
        self.assertEqual(self.meta("token_format_suspect"), "0")

    def test_unfinished_last_line_is_not_counted(self):
        # 還沒寫完的最後一行下次會重讀，這次不算讀取量
        path = self.codex_file()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'{"kind": "reply", "pad": "' + b"z" * (300 * 1024))
        with mock.patch.object(token_stats, "FORMAT_MIN_BYTES", 256 * 1024):
            self.scan()
        self.assertIsNone(self.meta("token_format_suspect"))

    def test_small_scans_do_not_decide(self):
        self.write(self.claude_file(), claude_assistant("m1", T0, inp=1, out=1))
        self.scan()
        self.assertIsNone(self.meta("token_format_suspect"))

    def test_verdict_function(self):
        c = token_stats.Counters
        self.assertIsNone(token_stats.format_suspect(c(candidate_lines=99, bad_lines=99)))
        self.assertTrue(token_stats.format_suspect(c(candidate_lines=100, bad_lines=20)))
        self.assertFalse(token_stats.format_suspect(c(candidate_lines=100, bad_lines=19, token_lines=81)))
        self.assertTrue(token_stats.format_suspect(c(bytes_read=4 * 1024 * 1024, token_lines=0)))
        self.assertFalse(token_stats.format_suspect(c(bytes_read=4 * 1024 * 1024, token_lines=1)))
        self.assertFalse(token_stats.format_suspect(c(candidate_lines=20, bad_lines=3, token_lines=8)))
        self.assertIsNone(token_stats.format_suspect(c(candidate_lines=20, bad_lines=4, token_lines=8)))
        self.assertIsNone(token_stats.format_suspect(c(candidate_lines=19, token_lines=19)))
        self.assertIsNone(token_stats.format_suspect(c(candidate_lines=30, token_lines=0)))


if __name__ == "__main__":
    unittest.main()
