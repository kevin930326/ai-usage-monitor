"""角色養成的資料（ADR-0020 第 1 節）：`level_days` 是每天「所有電腦合併」的主數字，只增不減。

- 這台：`record_days`（不套用保留期間）各服務相加；其他電腦：`daily_tokens` 中不是本機 device_id 的列
  （第二層下載，`input + cache_write + output`，同 record_days 的主數字）。這台自己在中繼上的列不會下載（token_sync）。
- 寫入取較大值、已有的日子不刪：保留期間清掉舊資料、其他電腦的列整批取代、Codex 重算變小，都不會讓它變小。
- 只有日期與數字；不上傳。App（Mac、Windows）讀這張表，以 UsageKit／UsageCore 的 MascotLevel 算經驗值與等級。
- 「清除歷史」（App 刪表）時一併清空，是唯一會變小的情況。
"""
from __future__ import annotations

import sqlite3
from pathlib import Path

from . import history
from .log import log

UPSERT = """
    INSERT INTO level_days (day, tokens)
    SELECT day, SUM(tokens) FROM (
        SELECT day, tokens FROM record_days
        UNION ALL
        SELECT day, input_tokens + cache_write_tokens + output_tokens FROM daily_tokens WHERE device_id != ?
    ) GROUP BY day HAVING SUM(tokens) > 0
    ON CONFLICT (day) DO UPDATE SET tokens = excluded.tokens WHERE excluded.tokens > level_days.tokens"""


def update(conn: sqlite3.Connection) -> None:
    local = history.meta(conn, "device_id") or ""
    with history._transaction(conn):
        conn.execute(UPSERT, (local,))


def update_safely(path: Path | None = None) -> None:
    """收集器每次執行（Token 統計與第二層之後）呼叫；不丟出例外，日誌只記類別"""
    path = path or history.HISTORY_PATH
    try:
        with history._private_files():
            # 同其他寫入入口：既有的資料庫與 -wal／-shm 收緊成 0600，收不了就丟 HistoryError、這次不寫
            history._tighten_permissions(path)
            conn = history.connect(path)
            try:
                update(conn)
            finally:
                conn.close()
        history._tighten_permissions(path)
    except history.HistoryError as e:
        log(f"略過等級資料：{e}")
    except Exception as e:
        log(f"略過等級資料：{type(e).__name__}")
