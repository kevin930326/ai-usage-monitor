"""額度歷史（ADR-0009）：每次收集把快照的額度寫進本機 history.sqlite3。

- 只有收集器寫入與執行 migration；選單列 App 只讀（清除歷史、縮短保留期間例外，由 App 刪除）。
- 只存數字、時間、服務與額度 id：不存方案名稱、錯誤訊息、額度顯示名稱。
- 歷史是附加功能：任何失敗都不能影響 usage.json 與中繼上傳，所以 `record_safely` 不會丟出例外，
  日誌只記錄例外的類別名稱（sqlite 的訊息可能帶出路徑）。
"""
from __future__ import annotations

import os
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Iterator

from .log import log
from .models import parse_iso
from .paths import APP_SUPPORT_DIR

HISTORY_PATH = APP_SUPPORT_DIR / "history.sqlite3"

# App 宣告支援的版本範圍要跟著改（apple/MacMenuBar 的 HistoryStore）
SCHEMA_VERSION = 1
DEFAULT_RETENTION_DAYS = 365  # 0 = 永久
DOWNSAMPLE_AFTER_DAYS = 35
BUSY_TIMEOUT_MS = 5000
DEFAULT_DEVICE_NAME = "這台 Mac"  # 不用電腦名稱，避免把使用者名稱帶進資料（ADR-0009 第 6 節）


class HistoryError(Exception):
    """資料庫版本比收集器新等無法寫入的情況；訊息可以直接寫進日誌。"""


_V1_TABLES = (
    """CREATE TABLE IF NOT EXISTS quota_samples (
         ts        INTEGER NOT NULL,
         provider  TEXT    NOT NULL,
         window_id TEXT    NOT NULL,
         used_pct  REAL    NOT NULL,
         resets_at INTEGER,
         PRIMARY KEY (provider, window_id, ts))""",
    # runs：這一列代表幾次執行（降採樣後為該小時的次數）；ok：其中成功的次數
    """CREATE TABLE IF NOT EXISTS collector_runs (
         ts   INTEGER PRIMARY KEY,
         ok   INTEGER NOT NULL,
         runs INTEGER NOT NULL DEFAULT 1)""",
    "CREATE INDEX IF NOT EXISTS quota_samples_ts ON quota_samples (ts)",
    "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)",
)


def _v1(conn: sqlite3.Connection) -> None:
    # 不用 executescript：它會先 COMMIT，migration 就不在同一個交易裡
    for statement in _V1_TABLES:
        conn.execute(statement)
    conn.executemany("INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)", [
        ("device_id", str(uuid.uuid4())),
        ("device_name", DEFAULT_DEVICE_NAME),
        ("retention_days", str(DEFAULT_RETENTION_DAYS)),
    ])


# MIGRATIONS[i] 把版本 i 升到 i + 1；之後的版本（Token 統計等）往後加
MIGRATIONS = [_v1]


def schema_version(conn: sqlite3.Connection) -> int:
    try:
        row = conn.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
    except sqlite3.OperationalError:  # 還沒有 meta 表：全新的檔案
        return 0
    try:
        return int(row[0]) if row else 0
    except (TypeError, ValueError):
        raise HistoryError("history.sqlite3 的 schema_version 格式不正確") from None


def migrate(conn: sqlite3.Connection) -> None:
    current = schema_version(conn)
    if current > SCHEMA_VERSION:
        # 較新的 App／收集器建立的檔案：不降版、不改寫
        raise HistoryError(f"history.sqlite3 的版本（{current}）比收集器新，請更新收集器")
    for version in range(current, SCHEMA_VERSION):
        with _transaction(conn):
            MIGRATIONS[version](conn)
            conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)",
                         (str(version + 1),))


@contextmanager
def _transaction(conn: sqlite3.Connection) -> Iterator[None]:
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield
    except BaseException:
        conn.rollback()
        raise
    conn.commit()


@contextmanager
def _private_files() -> Iterator[None]:
    """資料庫與 -wal／-shm 都是 0600：建立檔案的那段期間把 umask 設成 077。
    收集器是單執行緒，改 umask 不會影響其他工作。"""
    old = os.umask(0o077)
    try:
        yield
    finally:
        os.umask(old)


def _tighten_permissions(path: Path) -> None:
    for suffix in ("", "-wal", "-shm"):
        p = Path(f"{path}{suffix}")
        try:
            if p.exists() and (p.stat().st_mode & 0o777) != 0o600:
                os.chmod(p, 0o600)
        except OSError:
            pass  # 權限修不了不影響寫入


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=BUSY_TIMEOUT_MS / 1000, isolation_level=None)
    try:
        conn.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
        conn.execute("PRAGMA journal_mode = WAL")
        migrate(conn)
    except BaseException:
        conn.close()
        raise
    return conn


def _epoch(value: str | None) -> int | None:
    return int(parse_iso(value).timestamp()) if value else None


def meta(conn: sqlite3.Connection, key: str) -> str | None:
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else None


def retention_days(conn: sqlite3.Connection) -> int:
    """`meta.retention_days`；格式不對時用預設值（不因為設定壞掉就刪掉所有資料）。"""
    try:
        days = int(meta(conn, "retention_days") or DEFAULT_RETENTION_DAYS)
    except ValueError:
        return DEFAULT_RETENTION_DAYS
    return days if days >= 0 else DEFAULT_RETENTION_DAYS


def write_samples(conn: sqlite3.Connection, snapshot: dict) -> int:
    """寫入一次執行：collector_runs 一列、每個額度（不含錯誤的服務）一列。回傳寫入的額度筆數。"""
    ts = _epoch(snapshot["updated_at"])
    providers = snapshot.get("providers") or {}
    ok = int(any(p.get("error") is None for p in providers.values()))
    rows = []
    for name, p in providers.items():
        if p.get("error") is not None:
            continue
        for w in p.get("windows") or []:
            rows.append((ts, name, w["id"], float(w["used_pct"]), _epoch(w.get("resets_at"))))
    with _transaction(conn):
        conn.execute("INSERT OR REPLACE INTO collector_runs (ts, ok, runs) VALUES (?, ?, 1)", (ts, ok))
        conn.executemany(
            "INSERT OR REPLACE INTO quota_samples (ts, provider, window_id, used_pct, resets_at)"
            " VALUES (?, ?, ?, ?, ?)", rows)
    return len(rows)


def cleanup(conn: sqlite3.Connection, now: int) -> None:
    """依保留期間刪除，並把 35 天前的資料降為每小時一筆（ADR-0009 第 5 節）。"""
    days = retention_days(conn)
    # 只處理完整的小時，避免同一小時被分兩次降採樣
    cutoff = (now - DOWNSAMPLE_AFTER_DAYS * 86400) // 3600 * 3600
    with _transaction(conn):
        if days > 0:
            oldest = now - days * 86400
            conn.execute("DELETE FROM quota_samples WHERE ts < ?", (oldest,))
            conn.execute("DELETE FROM collector_runs WHERE ts < ?", (oldest,))
        # 上次降採樣到哪裡：之前的資料已是每小時一筆，不必再看（一年的資料全部重看要約 0.7 秒）
        try:
            lower = int(meta(conn, "downsampled_before") or 0)
        except ValueError:
            lower = 0
        if lower >= cutoff:
            return
        # quota_samples：每個額度每小時保留最後一筆
        conn.execute("DROP TABLE IF EXISTS temp.keep")
        # 欄位要宣告型別：CREATE TABLE AS 的 MAX(ts) 沒有型別，比對時用不到索引（一年的資料要 3 秒）
        conn.execute("CREATE TEMP TABLE keep (provider TEXT, window_id TEXT, ts INTEGER,"
                     " PRIMARY KEY (provider, window_id, ts))")
        conn.execute("""
            INSERT INTO keep SELECT provider, window_id, MAX(ts) FROM quota_samples
            WHERE ts >= :lower AND ts < :cutoff GROUP BY provider, window_id, ts / 3600
        """, {"lower": lower, "cutoff": cutoff})
        conn.execute("""
            DELETE FROM quota_samples WHERE ts >= :lower AND ts < :cutoff AND NOT EXISTS (
              SELECT 1 FROM keep k WHERE k.provider = quota_samples.provider
                AND k.window_id = quota_samples.window_id AND k.ts = quota_samples.ts)
        """, {"lower": lower, "cutoff": cutoff})
        conn.execute("DROP TABLE temp.keep")
        # collector_runs：每小時合成一列，保留執行與成功的次數，時間用該小時最後一次
        merged = conn.execute("""
            SELECT ts / 3600, MAX(ts), SUM(ok), SUM(runs) FROM collector_runs
            WHERE ts >= ? AND ts < ? GROUP BY ts / 3600 HAVING COUNT(*) > 1
        """, (lower, cutoff)).fetchall()
        for hour, last, ok, runs in merged:
            conn.execute("DELETE FROM collector_runs WHERE ts >= ? AND ts < ?", (hour * 3600, hour * 3600 + 3600))
            conn.execute("INSERT INTO collector_runs (ts, ok, runs) VALUES (?, ?, ?)", (last, ok, runs))
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('downsampled_before', ?)", (str(cutoff),))


def maybe_cleanup(conn: sqlite3.Connection, now: int, today: date) -> bool:
    """每天（本機日期）第一次執行時清理；回傳是否有清理。"""
    if meta(conn, "last_cleanup_day") == today.isoformat():
        return False
    cleanup(conn, now)
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_cleanup_day', ?)",
                 (today.isoformat(),))
    return True


def record(snapshot: dict, path: Path | None = None, now: datetime | None = None) -> int:
    path = path or HISTORY_PATH
    now = now or datetime.now(timezone.utc)
    with _private_files():
        conn = connect(path)
        try:
            count = write_samples(conn, snapshot)
            maybe_cleanup(conn, int(now.timestamp()), now.astimezone().date())
        finally:
            conn.close()
    _tighten_permissions(path)
    return count


def record_safely(snapshot: dict, path: Path | None = None) -> bool:
    """`record` 的外層：不丟出任何例外。回傳是否寫入成功。"""
    try:
        record(snapshot, path)
        return True
    except HistoryError as e:
        log(f"略過額度歷史：{e}")
    except sqlite3.DatabaseError as e:
        # 鎖住（另一個程序寫入超過 5 秒）或檔案損毀；訊息可能含路徑，只記類別
        log(f"略過額度歷史（{type(e).__name__}）：history.sqlite3 被鎖住或已損毀；"
            "持續發生時在設定中清除歷史，或把檔案移走")
    except Exception as e:
        log(f"略過額度歷史：{type(e).__name__}")
    return False
