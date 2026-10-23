"""Token 統計（ADR-0009）的測試：只用這裡編的假紀錄。"""
import io
import json
import os
import shutil
import sqlite3
import tempfile
import time
import unittest
from contextlib import contextmanager, redirect_stderr
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from usage_collector import history, token_stats

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
        # 日期以掃描當下的本機時區計算：固定成台北時間
        self._tz = os.environ.get("TZ")
        os.environ["TZ"] = "Asia/Taipei"
        time.tzset()

    def tearDown(self):
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
    def test_migrates_v1_to_v2_and_keeps_data(self):
        with mock.patch.object(history, "SCHEMA_VERSION", 1), mock.patch.object(history, "MIGRATIONS", [history._v1]):
            conn = history.connect(self.path)
            conn.execute("INSERT INTO collector_runs (ts, ok) VALUES (?, 1)", (T0,))
            device = history.meta(conn, "device_id")
            conn.close()
        conn = history.connect(self.path)
        self.assertEqual(history.schema_version(conn), 2)
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertTrue({"daily_tokens", "hourly_tokens", "records", "scan_state", "seen_ids", "file_tokens",
                         "seen_tasks", "quota_samples", "collector_runs", "meta"} <= tables)
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM collector_runs").fetchone()[0], 1)
        self.assertEqual(history.meta(conn, "device_id"), device)
        conn.close()

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
        os.unlink(self.codex_file())
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
        # 列舉之後被換成另一個檔案（inode 不同）
        real_list = token_stats.list_files
        def swapped(dirs):
            files = real_list(dirs)
            os.unlink(self.codex_file())
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
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM seen_ids").fetchone()[0], 2)  # 去重表永久保留
        conn.close()

    def test_unchanged_files_are_not_reopened(self):
        self.write(self.claude_file(), claude_assistant("a", T0, inp=1, out=0))
        self.scan()
        with mock.patch.object(token_stats.os, "open", side_effect=AssertionError("reopened")):
            result = self.scan()
        self.assertEqual(result.processed, 0)

    def test_locked_database_gives_up_once(self):
        for i in range(5):
            self.write(self.claude_file(f"{SESSION[:-1]}{i}"), claude_assistant(f"a{i}", T0, inp=1, out=1))
        history.connect(self.path).close()
        holder = sqlite3.connect(self.path, isolation_level=None)
        holder.execute("BEGIN IMMEDIATE")
        try:
            with mock.patch.object(history, "BUSY_TIMEOUT_MS", 100), mock.patch.object(token_stats.os, "nice"), \
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
             mock.patch.object(token_stats.os, "nice"), redirect_stderr(self.stderr):
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


if __name__ == "__main__":
    unittest.main()
