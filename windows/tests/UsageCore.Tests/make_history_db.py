"""HistoryReaderTests 用：以收集器自己的程式（usage_collector.history）建立 history.sqlite3，再寫入固定的資料。

用法：python make_history_db.py <路徑> <模式> [<現在的 Unix 秒>]
- full：建表（收集器的 migration、WAL）並寫入額度、收集紀錄、每日 Token（含其他電腦）、個人紀錄、裝置清單，然後關閉
- hold：開一個寫入交易、寫一筆新的額度，印出 locked 後等 stdin 一行再提交（測試讀取不被寫入擋住）
- old：只建 meta 表、schema_version 2（收集器尚未更新）
不讀真實的資料夾：路徑由測試給暫存資料夾。
"""
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "collector"))
from usage_collector import history  # noqa: E402

path, mode = Path(sys.argv[1]), sys.argv[2]
now = int(sys.argv[3]) if len(sys.argv) > 3 else 1793007000

if mode == "old":
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("INSERT INTO meta VALUES ('schema_version', '2')")
    conn.commit()
    conn.close()
    sys.exit(0)

conn = history.connect(path)
if mode == "hold":
    conn.execute("BEGIN IMMEDIATE")
    conn.execute("INSERT INTO quota_samples VALUES (?, 'claude', 'five_hour', 99.0, NULL)", (now,))
    print("locked", flush=True)
    sys.stdin.readline()
    conn.execute("COMMIT")
    conn.close()
    sys.exit(0)

local = history.meta(conn, "device_id")
with conn:
    conn.execute("BEGIN")
    for i in range(6):
        ts = now - 3600 + i * 600
        conn.execute("INSERT INTO collector_runs VALUES (?, 1, 1)", (ts,))
        conn.execute("INSERT INTO quota_samples VALUES (?, 'claude', 'five_hour', ?, ?)", (ts, 10.0 + i * 2.5, now + 7200))
    # 8 天以前的不讀
    conn.execute("INSERT INTO quota_samples VALUES (?, 'claude', 'weekly', 5.0, NULL)", (now - 9 * 86400,))
    conn.execute("INSERT INTO collector_runs VALUES (?, 11, 12)", (now - 86400,))
    conn.execute("""INSERT INTO daily_tokens (device_id, day, provider, model, input_tokens, cache_write_tokens, cache_read_tokens,
                    output_tokens, reasoning_tokens, task_count, task_seconds, longest_task_seconds, updated_at)
                    VALUES (?, '2026-10-25', 'claude', 'opus', 100, 20, 5000, 30, 4, 2, 600, 400, ?)""", (local, now))
    conn.execute("""INSERT INTO daily_tokens (device_id, day, provider, model, input_tokens, output_tokens, updated_at)
                    VALUES ('dev-desk', '2026-10-25', 'codex', 'gpt', 700, 70, ?)""", (now,))
    conn.execute("""INSERT INTO daily_tokens (device_id, day, provider, model, input_tokens, updated_at)
                    VALUES (?, '2024-01-01', 'claude', 'opus', 1, ?)""", (local, now))
    conn.execute("""INSERT INTO hourly_tokens (device_id, day, hour, provider, model, input_tokens, output_tokens, updated_at)
                    VALUES (?, '2026-10-25', 13, 'claude', 'opus', 100, 30, ?)""", (local, now))
    conn.execute("""INSERT INTO hourly_tokens (device_id, day, hour, provider, model, input_tokens, updated_at)
                    VALUES ('dev-desk', '2026-10-25', 13, 'codex', 'gpt', 700, ?)""", (now,))
    conn.execute("INSERT INTO records VALUES ('total_tokens', 123456, NULL)")
    conn.execute("INSERT INTO records VALUES ('best_day_tokens', 999, '2026-10-01')")
    conn.execute("INSERT INTO record_days VALUES ('2026-10-25', 'claude', 150)")
    conn.execute("INSERT INTO devices VALUES ('relay-self', 'PC', ?, 0, 1)", (now - 60,))
    conn.execute("INSERT INTO devices VALUES ('dev-desk', '桌機', NULL, 1, 0)")
    for key, value in [("retention_days", "90"), ("first_scan_done", "1"), ("first_scan_progress", "150"),
                       ("token_bad_lines", "3"), ("token_long_lines", "x"), ("token_days_from", "2026-10-01"),
                       ("token_format_suspect", "1"), ("upload_status", "copied")]:
        conn.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (key, value))
conn.close()
