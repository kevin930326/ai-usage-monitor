"""Antigravity（Gemini）對話資料庫的 Token 統計（ADR-0023）：只用這裡編的假資料庫。"""
import json
import sqlite3
from pathlib import Path
from unittest import mock

from usage_collector import token_stats

from .test_token_stats import DAY, SECRETS, T0, TokenStatsTestCase

CONVERSATION = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
SECOND = "12345678-1234-4234-8234-123456789abc"


def varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field(number: int, value) -> bytes:
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    if isinstance(value, str):
        value = value.encode()
    return varint(number << 3 | 2) + varint(len(value)) + value


def generation(inp=0, out=0, cw=0, cr=0, thinking=0, model="gemini-4-neon", step=0, usage=True):
    stats = b"".join(field(f, v) for f, v in ((1, 1532), (2, inp), (3, out), (4, cw), (5, cr), (6, 24),
                                               (9, thinking), (10, out - thinking)) if v)
    stats += field(11, "SECRET-TOOL-OUTPUT-response-id")
    meta = b""
    if usage:
        meta += field(4, stats)
    meta += field(17, field(2, stats))  # 實際資料的鏡像位置：不能重複計入
    if model is not None:
        meta += field(19, model)
    for key, value in (("cascade_id", "SECRET-PROMPT-TEXT"), ("last_step_index", str(step)),
                       ("trajectory_id", "fake.person@example.com")):
        meta += field(20, field(1, key) + field(2, value))
    return field(1, meta) + field(2, "SECRET-AGENT-MESSAGE")


def step_metadata(ts: int) -> bytes:
    return field(1, field(1, ts) + field(2, 500_000_000)) + field(3, "secret-project-folder")


class GeminiTokenTest(TokenStatsTestCase):
    def setUp(self):
        super().setUp()
        self.gemini = Path(self.dir.name) / "antigravity"
        (self.gemini / "conversations").mkdir(parents=True)

    @property
    def dirs(self):
        return {"claude": self.claude, "codex": self.codex, "gemini": self.gemini}

    def conversation(self, name=CONVERSATION) -> sqlite3.Connection:
        """與 Antigravity 相同的兩張表（WAL 模式）；呼叫端寫入後要 commit。"""
        conn = sqlite3.connect(self.gemini / "conversations" / f"{name}.db")
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("CREATE TABLE IF NOT EXISTS gen_metadata (idx integer, data blob, size integer NOT NULL DEFAULT 0,"
                     " PRIMARY KEY (idx))")
        conn.execute("CREATE TABLE IF NOT EXISTS steps (idx integer, step_type integer NOT NULL DEFAULT 0,"
                     " metadata blob, step_payload blob, PRIMARY KEY (idx))")
        self.addCleanup(conn.close)
        return conn

    def add_steps(self, conn, *times):
        start = conn.execute("SELECT count(*) FROM steps").fetchone()[0]
        conn.executemany("INSERT INTO steps (idx, metadata, step_payload) VALUES (?, ?, ?)",
                         [(start + i, step_metadata(ts), b"SECRET-PROMPT-TEXT /Users/fake") for i, ts in enumerate(times)])

    def add_generation(self, conn, idx, **kwargs):
        conn.execute("INSERT OR REPLACE INTO gen_metadata (idx, data) VALUES (?, ?)", (idx, generation(**kwargs)))

    def test_counts_generations_with_step_times(self):
        conn = self.conversation()
        self.add_steps(conn, T0, T0 + 10, T0 + DAY)
        self.add_generation(conn, 0, inp=2000, out=400, thinking=350, cr=14000, step=1)
        self.add_generation(conn, 1, inp=100, out=50, cw=7, step=2, model="claude-sonnet-5-5")
        self.add_generation(conn, 2, usage=False, step=2)  # 失敗的生成：沒有用量
        conn.commit()
        self.scan(now=T0 + 2 * DAY)
        self.assertEqual(self.totals("gemini"), (2100, 7, 14000, 450, 350, 0, 0))
        rows = self.table("daily_tokens")
        self.assertEqual({(r[0], r[1], r[2]) for r in rows},
                         {("2026-09-21", "gemini", "gemini-4-neon"), ("2026-09-22", "gemini", "claude-sonnet-5-5")})
        records = self.records()
        self.assertEqual(records["total_tokens:gemini"][0], 2000 + 400 + 100 + 50 + 7)
        self.assertEqual(records["total_tokens_cached:gemini"][0], 2557 + 14000)

    def test_new_and_finished_generations_are_added_once(self):
        conn = self.conversation()
        self.add_steps(conn, T0)
        self.add_generation(conn, 0, inp=10, out=1, step=0)
        conn.commit()
        self.scan()
        self.scan()
        self.assertEqual(self.totals("gemini")[:4], (10, 0, 0, 1))
        # 最後一筆在上次讀完後才寫完（數字變大）、又多了一筆
        self.add_generation(conn, 0, inp=10, out=5, step=0)
        self.add_generation(conn, 1, inp=3, out=2, step=0)
        conn.commit()
        self.scan()
        self.scan()
        self.assertEqual(self.totals("gemini")[:4], (13, 0, 0, 7))

    def test_unreadable_files_do_not_stop_the_scan(self):
        conversations = self.gemini / "conversations"
        (conversations / f"{SECOND}.db").write_bytes(b"not a database" * 100)
        (conversations / "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.db").write_bytes(b"")
        (conversations / "notes.db").write_bytes(b"x")  # 檔名不是 UUID：不讀
        conn = self.conversation()
        self.add_steps(conn, T0)
        self.add_generation(conn, 0, inp=5, out=1, step=0)
        conn.execute("INSERT INTO gen_metadata (idx, data) VALUES (1, ?)", (b"\xff\xff\xff",))  # 壞掉的列
        conn.commit()
        result = self.scan()
        self.assertTrue(result.done)
        self.assertEqual(self.totals("gemini")[:4], (5, 0, 0, 1))
        self.assertEqual(result.counters.bad_lines, 1)
        keys = {f.key for f in token_stats.list_files(self.dirs)}
        self.assertNotIn("gemini:notes", keys)
        self.assertIn(f"gemini:{CONVERSATION}", keys)

    def test_only_when_enabled(self):
        config = Path(self.dir.name) / "config.json"
        config.write_text(json.dumps({"enabled_providers": ["claude", "codex"]}))
        self.assertNotIn("gemini", token_stats.log_dirs(config, {}))
        config.write_text(json.dumps({"enabled_providers": ["gemini"]}))
        self.assertEqual(token_stats.log_dirs(config, {})["gemini"], Path.home() / ".gemini" / "antigravity")

    def test_budget_splits_large_conversations(self):
        conn = self.conversation()
        self.add_steps(conn, T0)
        for i in range(30):
            self.add_generation(conn, i, inp=1, out=1, step=0)
        conn.commit()
        progress = []
        with mock_batch(7):
            for _ in range(10):
                progress.append(self.scan(budget=token_stats.Budget(bytes_left=len(generation(inp=1, out=1)) * 9)).progress)
                if progress[-1] == 100:
                    break
        self.assertEqual(progress[:4], sorted(progress[:4]))
        self.assertGreater(len(progress), 1)
        self.assertEqual(self.totals("gemini")[:4], (30, 0, 0, 30))

    def test_no_content_or_names_leak(self):
        conn = self.conversation()
        self.add_steps(conn, T0)
        self.add_generation(conn, 0, inp=5, out=1, step=0, model="SECRET-PROMPT-TEXT")
        conn.commit()
        self.scan()
        with self.db() as c:
            dump = "\n".join(c.iterdump())
        for secret in SECRETS:
            self.assertNotIn(secret, dump + self.stderr.getvalue(), secret)
        self.assertNotIn(self.dir.name, dump)
        self.assertEqual({r[2] for r in self.table("daily_tokens")}, {"other"})


    def test_update_without_size_change_is_read(self):
        """審查 C-01：SQLite 改寫既有的頁時大小不變，只有時間變了。"""
        conn = self.conversation()
        self.add_steps(conn, T0)
        self.add_generation(conn, 0, inp=10, out=1, step=0)
        conn.commit()
        self.scan()
        self.add_generation(conn, 0, inp=10, out=5, step=0)  # 同樣長度的資料：頁數不變
        conn.commit()
        f, = token_stats.list_files(self.dirs)[-1:]
        with self.db() as c:
            c.execute("UPDATE scan_state SET offset = ? WHERE file_key = ?", (f.size, f.key))  # 模擬大小不變
            c.commit()
        self.scan()
        self.assertEqual(self.totals("gemini")[:4], (10, 0, 0, 5))

    def test_source_error_midway_changes_nothing(self):
        """審查 C-02：讀到一半出錯時不留下計入一半的去重紀錄；之後重試的結果與一次讀完相同。"""
        conn = self.conversation()
        self.add_steps(conn, T0, T0 + 1)
        self.add_generation(conn, 0, inp=10, out=1, step=0)
        self.add_generation(conn, 1, inp=10, out=1, step=1)
        conn.commit()
        real = token_stats._gemini_step_time
        calls = []

        def flaky(db, step):
            calls.append(step)
            if len(calls) == 2:
                raise sqlite3.OperationalError("database is locked")
            return real(db, step)

        with mock.patch.object(token_stats, "_gemini_step_time", flaky):
            self.scan()
        self.assertEqual(self.totals("gemini")[:4], (0, 0, 0, 0))
        self.assertEqual(self.table("seen_ids"), [])
        self.scan()
        self.assertEqual(self.totals("gemini")[:4], (20, 0, 0, 2))

    def test_rows_are_loaded_one_at_a_time_within_the_budget(self):
        """審查 C-03：預算用完後不再載入；過大的列不載入，只計次數。"""
        conn = self.conversation()
        self.add_steps(conn, T0)
        for i in range(3):
            self.add_generation(conn, i, inp=1, out=1, step=0)
        conn.commit()
        size = len(generation(inp=1, out=1))
        loaded = []
        real = token_stats._gemini_generation
        with mock.patch.object(token_stats, "_gemini_generation", lambda d: loaded.append(len(d)) or real(d)):
            self.scan(budget=token_stats.Budget(bytes_left=1))
        self.assertEqual(loaded, [size])
        with mock.patch.object(token_stats, "MAX_LINE_BYTES", size - 1):
            result = self.scan()
        self.assertEqual(result.counters.long_lines, 3)  # 上次最後一筆重讀，加上另外兩筆
        self.assertEqual(self.totals("gemini")[:4], (1, 0, 0, 1))

def mock_batch(rows):
    return mock.patch.object(token_stats, "GEMINI_BATCH_ROWS", rows)

