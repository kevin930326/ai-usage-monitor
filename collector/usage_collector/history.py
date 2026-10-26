"""額度歷史（ADR-0009）：每次收集把快照的額度寫進本機 history.sqlite3。

- 只有收集器寫入與執行 migration；選單列 App 只讀（清除歷史、縮短保留期間例外，由 App 刪除）。
- 只存數字、時間、服務與額度 id：不存方案名稱、錯誤訊息、額度顯示名稱。
- 歷史是附加功能：任何失敗都不能影響 usage.json 與中繼上傳，所以 `record_safely` 不會丟出例外，
  日誌只記錄例外的類別名稱（sqlite 的訊息可能帶出路徑）。
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from . import history_care, system
from .log import log
from .models import parse_iso
from .paths import APP_SUPPORT_DIR

HISTORY_PATH = APP_SUPPORT_DIR / "history.sqlite3"

# App 宣告支援的版本範圍要跟著改（apple/MacMenuBar 的 HistoryStore）
SCHEMA_VERSION = 3
DEFAULT_RETENTION_DAYS = 365  # 0 = 永久
DOWNSAMPLE_AFTER_DAYS = 35
HOURLY_TOKENS_DAYS = 90  # hourly_tokens 只留 90 天（daily_tokens 已有同樣的加總）
SCAN_STATE_DAYS = 90  # 超過 90 天沒看到的紀錄檔刪掉掃描進度
BUSY_TIMEOUT_MS = 5000
# 定期 VACUUM（ADR-0014 LT-14）：刪除只把頁面放回 freelist，檔案不會變小、WAL 停在曾達到的大小。
# 每 30 天，或可回收的空間超過全部的 20%（且至少 1 MB）時重建；VACUUM 要暫存一份資料庫，
# 磁碟剩餘空間不到資料庫大小的 2 倍＋64 MB 時這次不做（隔天再看）
VACUUM_INTERVAL_DAYS = 30
VACUUM_FREE_RATIO = 0.2
VACUUM_MIN_RECLAIM = 1024 * 1024
VACUUM_DISK_MARGIN = 64 * 1024 * 1024
# 任何一次完整的 checkpoint 之後把 WAL 縮回這個大小以內：VACUUM 時 App 正開著讀取、截斷不了時，
# WAL 不會停在整個資料庫的大小等到下一次 VACUUM（總檢查 F-04）
WAL_SIZE_LIMIT = 4 * 1024 * 1024
# 清理用的時間比上次清理最多前進 2 天（ADR-0014 LT-11）：時鐘被設到未來時，一次清理不會把保留期間內的資料全部刪掉；
# 正常每天清理一次只前進約 1 天，收集器停了一陣子時晚幾天刪（多留一點），每天追上 1 天
CLEANUP_CLOCK_STEP = 2 * 86400
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


_TOKEN_COLUMNS = """
         input_tokens       INTEGER NOT NULL DEFAULT 0,
         cache_write_tokens INTEGER NOT NULL DEFAULT 0,
         cache_read_tokens  INTEGER NOT NULL DEFAULT 0,
         output_tokens      INTEGER NOT NULL DEFAULT 0,
         reasoning_tokens   INTEGER NOT NULL DEFAULT 0"""
_TASK_COLUMNS = """
         task_count           INTEGER NOT NULL DEFAULT 0,
         task_seconds         INTEGER NOT NULL DEFAULT 0,
         longest_task_seconds INTEGER NOT NULL DEFAULT 0,
         updated_at           INTEGER NOT NULL"""

# Token 統計（ADR-0009 第 2 節；以下幾項是 v1.7 實作時加入、已寫進 ADR 正文，都只有數字與 ID）：
# - scan_state.state：跨次掃描要接著用的狀態（Claude 進行中任務的開始時間與第一則回覆 ID、Codex 目前的模型）
# - seen_ids.file_key：Codex 的回應 ID 由哪個檔案計入；該檔重算時一併移除，才能重新計入
# - seen_tasks：已計入的任務與當時的秒數。任務跨兩次掃描時補差額；重掃、--resume 副本不重複計算
# - record_days：每天每個服務的主數字，不套用保留期間；單日最高與連續天數這兩項個人紀錄以它計算
_V2_TABLES = (
    f"""CREATE TABLE IF NOT EXISTS daily_tokens (
         device_id TEXT NOT NULL,
         day       TEXT NOT NULL,
         provider  TEXT NOT NULL,
         model     TEXT NOT NULL,{_TOKEN_COLUMNS},{_TASK_COLUMNS},
         PRIMARY KEY (device_id, day, provider, model))""",
    f"""CREATE TABLE IF NOT EXISTS hourly_tokens (
         device_id TEXT    NOT NULL,
         day       TEXT    NOT NULL,
         hour      INTEGER NOT NULL,
         provider  TEXT    NOT NULL,
         model     TEXT    NOT NULL,{_TOKEN_COLUMNS},{_TASK_COLUMNS},
         PRIMARY KEY (device_id, day, hour, provider, model))""",
    "CREATE INDEX IF NOT EXISTS daily_tokens_day ON daily_tokens (day)",
    "CREATE INDEX IF NOT EXISTS hourly_tokens_day ON hourly_tokens (day)",
    "CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY, value INTEGER NOT NULL, day TEXT)",
    """CREATE TABLE IF NOT EXISTS record_days (
         day      TEXT    NOT NULL,
         provider TEXT    NOT NULL,
         tokens   INTEGER NOT NULL,
         PRIMARY KEY (day, provider))""",
    """CREATE TABLE IF NOT EXISTS scan_state (
         file_key   TEXT PRIMARY KEY,
         inode      INTEGER NOT NULL,
         device     INTEGER NOT NULL,
         size       INTEGER NOT NULL,
         mtime      INTEGER NOT NULL,
         offset     INTEGER NOT NULL,
         source     TEXT,
         last_total TEXT,
         state      TEXT,
         last_seen  INTEGER NOT NULL)""",
    f"""CREATE TABLE IF NOT EXISTS seen_ids (
         provider TEXT    NOT NULL,
         id       TEXT    NOT NULL,
         day      TEXT    NOT NULL,
         hour     INTEGER NOT NULL,
         model    TEXT    NOT NULL,{_TOKEN_COLUMNS},
         file_key TEXT,
         PRIMARY KEY (provider, id))""",
    "CREATE INDEX IF NOT EXISTS seen_ids_file ON seen_ids (file_key) WHERE file_key IS NOT NULL",
    f"""CREATE TABLE IF NOT EXISTS file_tokens (
         file_key TEXT    NOT NULL,
         day      TEXT    NOT NULL,
         hour     INTEGER NOT NULL,
         model    TEXT    NOT NULL,{_TOKEN_COLUMNS},
         PRIMARY KEY (file_key, day, hour, model))""",
    """CREATE TABLE IF NOT EXISTS seen_tasks (
         provider TEXT    NOT NULL,
         id       TEXT    NOT NULL,
         day      TEXT    NOT NULL,
         hour     INTEGER NOT NULL,
         model    TEXT    NOT NULL,
         seconds  INTEGER NOT NULL,
         PRIMARY KEY (provider, id))""",
)


def _v2(conn: sqlite3.Connection) -> None:
    for statement in _V2_TABLES:
        conn.execute(statement)


def _repair_v2(conn: sqlite3.Connection) -> None:
    """開發中的收集器建立的版本 2 檔案可能少了之後才加的 record_days：補建，並以每日資料回填
    （每日資料套用保留期間，回填的是目前還在的天數；之後的掃描照常累加）。其他表都已存在時什麼都不做。"""
    if _table_exists(conn, "record_days"):
        return
    with _transaction(conn):
        _v2(conn)
        conn.execute("""
            INSERT OR REPLACE INTO record_days (day, provider, tokens)
            SELECT day, provider, SUM(input_tokens + cache_write_tokens + output_tokens)
            FROM daily_tokens WHERE device_id = ? GROUP BY day, provider""", (meta(conn, "device_id") or "",))


# 含快取讀取的個人紀錄（FR-60）：同一個 schema 版本新增，舊版 App 不讀、舊版收集器不寫（App 找不到時改由每日資料計算）
# - record_days_cached：同 record_days，但數字是 input＋cache_write＋cache_read＋output；單日最高（含快取）以它計算
# - records 的 total_tokens_cached、best_day_tokens_cached（各加 :claude／:codex）
_CACHED_RECORD_DAYS = """CREATE TABLE IF NOT EXISTS record_days_cached (
         day      TEXT    NOT NULL,
         provider TEXT    NOT NULL,
         tokens   INTEGER NOT NULL,
         PRIMARY KEY (day, provider))"""


def _add_cached_records(conn: sqlite3.Connection) -> None:
    """還沒有 record_days_cached 時建立，並以目前的資料算出初始值。每天的數字是 record_days（主數字，不受保留期間影響）
    加上那天已計入的 cache_read，來源與重算時扣除的一致（不用會過期的每日資料）：
    - Claude：seen_ids 記著每則訊息計入的數值（永久保留）。只加 record_days 有的日子：「清除歷史」（不重新掃描）會清空
      record_days 卻留下 seen_ids，那些日子的主數字已不在累計裡，快取讀取也不該算進來
    - Codex：file_tokens 是各檔案已計入的數值，改寫時就是扣這份（「清除歷史」時歸零）
    累計是 total_tokens 加上這些 cache_read；單日最高取最大的一天。已經有這張表時什麼都不做（之後的掃描照常累加）。"""
    if _table_exists(conn, "record_days_cached") or not _table_exists(conn, "record_days"):
        return  # 已經有了，或是還沒有 Token 統計的版本 1 檔案
    with _transaction(conn):
        conn.execute(_CACHED_RECORD_DAYS)
        conn.execute("""
            WITH extra (day, provider, c) AS (
              SELECT s.day, 'claude', SUM(s.cache_read_tokens) FROM seen_ids s
              WHERE s.provider = 'claude'
                AND EXISTS (SELECT 1 FROM record_days r WHERE r.day = s.day AND r.provider = 'claude')
              GROUP BY s.day
              UNION ALL
              SELECT day, 'codex', SUM(cache_read_tokens) FROM file_tokens GROUP BY day
            )
            INSERT INTO record_days_cached (day, provider, tokens)
            SELECT day, provider, SUM(t) FROM (
              SELECT day, provider, tokens AS t FROM record_days
              UNION ALL
              SELECT day, provider, c FROM extra
            ) GROUP BY day, provider HAVING SUM(t) > 0""")
        for provider in (None, "claude", "codex"):
            suffix = f":{provider}" if provider else ""
            where, args = (" WHERE provider = ?", (provider,)) if provider else ("", ())
            base = conn.execute("SELECT value FROM records WHERE key = ?", ("total_tokens" + suffix,)).fetchone()
            cache = (conn.execute(f"SELECT COALESCE(SUM(tokens), 0) FROM record_days_cached{where}", args).fetchone()[0]
                     - conn.execute(f"SELECT COALESCE(SUM(tokens), 0) FROM record_days{where}", args).fetchone()[0])
            total = (base[0] if base else 0) + max(cache, 0)
            if total > 0:
                conn.execute("INSERT OR REPLACE INTO records (key, value, day) VALUES (?, ?, NULL)",
                             ("total_tokens_cached" + suffix, total))
            best = conn.execute(f"SELECT day, SUM(tokens) AS t FROM record_days_cached{where}"
                                " GROUP BY day HAVING t > 0 ORDER BY t DESC, day LIMIT 1", args).fetchone()
            if best:
                conn.execute("INSERT OR REPLACE INTO records (key, value, day) VALUES (?, ?, ?)",
                             ("best_day_tokens_cached" + suffix, best[1], best[0]))


# 第二層（ADR-0011 第 2 節，schema 3）：
# - upload_state：這台電腦每一列上次成功上傳時的數值雜湊與時間（只有本機 device_id 的列會上傳）
# - devices：從中繼下載的裝置清單（面板的裝置切換與最後上傳時間）；is_self＝這台電腦在中繼上的 device_id
#   （中繼的 device_id 由密鑰決定，和本機 meta.device_id 不同）
_V3_TABLES = (
    """CREATE TABLE IF NOT EXISTS upload_state (
         day         TEXT    NOT NULL,
         provider    TEXT    NOT NULL,
         model       TEXT    NOT NULL,
         hash        TEXT    NOT NULL,
         uploaded_at INTEGER NOT NULL,
         PRIMARY KEY (day, provider, model))""",
    """CREATE TABLE IF NOT EXISTS devices (
         device_id      TEXT    PRIMARY KEY,
         name           TEXT    NOT NULL,
         last_upload_at INTEGER,
         revoked        INTEGER NOT NULL DEFAULT 0,
         is_self        INTEGER NOT NULL DEFAULT 0)""",
)


def _v3(conn: sqlite3.Connection) -> None:
    for statement in _V3_TABLES:
        conn.execute(statement)


def _table_exists(conn: sqlite3.Connection, name: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (name,)).fetchone() is not None


# MIGRATIONS[i] 把版本 i 升到 i + 1；之後的版本往後加
MIGRATIONS = [_v1, _v2, _v3]


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
    if current >= 2:
        _repair_v2(conn)
    _add_cached_records(conn)


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
    """既有的資料庫與 -wal／-shm 改成 0600；改不了就丟出 HistoryError，這次不寫入歷史。
    Windows 沒有 POSIX 權限（chmod 只能切換唯讀，stat 一律回報 0666）：資料夾在 %LOCALAPPDATA%，
    預設的 ACL 只有使用者本人、SYSTEM 與 Administrators 能存取，不另外檢查。"""
    if system.IS_WINDOWS:
        return
    for suffix in ("", "-wal", "-shm"):
        p = Path(f"{path}{suffix}")
        try:
            if p.exists() and (p.stat().st_mode & 0o777) != 0o600:
                os.chmod(p, 0o600)
                if (p.stat().st_mode & 0o777) != 0o600:
                    raise OSError
        except OSError:
            raise HistoryError("無法把 history.sqlite3 的權限設為 0600，略過這次寫入") from None


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=BUSY_TIMEOUT_MS / 1000, isolation_level=None)
    try:
        conn.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
        # 先確認版本再改日誌模式：較新版本的檔案一個位元組都不動（journal_mode 會寫進檔案）
        if schema_version(conn) > SCHEMA_VERSION:
            raise HistoryError(f"history.sqlite3 的版本（{schema_version(conn)}）比收集器新，請更新收集器")
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute(f"PRAGMA journal_size_limit = {WAL_SIZE_LIMIT}")
        migrate(conn)
    except BaseException:
        conn.close()
        raise
    return conn


def _epoch(value: str | None) -> int | None:
    return int(parse_iso(value).timestamp()) if value else None


def local_day(ts: int) -> str:
    """Unix 秒換算成本機時區的日期 YYYY-MM-DD（Token 統計的 day 欄位）。"""
    return system.local_datetime(ts).date().isoformat()


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


def _cleanup_clock(conn: sqlite3.Connection, now: int) -> int:
    """清理用的時間：時鐘往回走時用現在的時間（刪得比較少，不會多刪），往前跳時最多比上次前進 CLEANUP_CLOCK_STEP。"""
    try:
        last = int(meta(conn, "cleanup_clock") or 0)
    except ValueError:
        last = 0
    if last <= 0:
        # 升級後第一次（還沒有 cleanup_clock）：以上次清理那天結束時當基準，時鐘剛好超前也不會刪光（審查 C-02）。
        # 都沒有時是新的資料庫，沒有東西可刪
        try:
            day = date.fromisoformat(meta(conn, "last_cleanup_day") or "")
            last = int(datetime.combine(day + timedelta(days=1), datetime.min.time()).timestamp())
        except (ValueError, OverflowError):
            last = 0
    clock = now if last <= 0 or now <= last else min(now, last + CLEANUP_CLOCK_STEP)
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('cleanup_clock', ?)", (str(clock),))
    return clock


def cleanup(conn: sqlite3.Connection, now: int) -> None:
    """依保留期間刪除，並把 35 天前的資料降為每小時一筆（ADR-0009 第 5 節）。"""
    now = _cleanup_clock(conn, now)
    days = retention_days(conn)
    # 只處理完整的小時，避免同一小時被分兩次降採樣
    cutoff = (now - DOWNSAMPLE_AFTER_DAYS * 86400) // 3600 * 3600
    with _transaction(conn):
        if days > 0:
            oldest = now - days * 86400
            conn.execute("DELETE FROM quota_samples WHERE ts < ?", (oldest,))
            conn.execute("DELETE FROM collector_runs WHERE ts < ?", (oldest,))
            conn.execute("DELETE FROM daily_tokens WHERE day < ?", (local_day(oldest),))
            conn.execute("DELETE FROM upload_state WHERE day < ?", (local_day(oldest),))
        hourly = min(days, HOURLY_TOKENS_DAYS) if days > 0 else HOURLY_TOKENS_DAYS
        conn.execute("DELETE FROM hourly_tokens WHERE day < ?", (local_day(now - hourly * 86400),))
        conn.execute("DELETE FROM scan_state WHERE last_seen < ?", (now - SCAN_STATE_DAYS * 86400,))
        # 上次降採樣到哪裡：之前的資料已是每小時一筆，不必再看（一年的資料全部重看要約 0.7 秒）
        try:
            lower = int(meta(conn, "downsampled_before") or 0)
        except ValueError:
            lower = 0
        if lower > cutoff + 86400:
            lower = 0  # 時鐘曾被設到未來時寫下的水位線：從頭重看一次（一年的資料約 0.7 秒），不然降採樣會停到那一天
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
    maybe_vacuum(conn, now)
    history_care.maybe_backup(conn, now)  # 每週一次；失敗只記日誌（ADR-0014 D-1）
    return True


def maybe_vacuum(conn: sqlite3.Connection, now: int) -> bool:
    """到期（30 天，或可回收的空間夠多）且磁碟空間足夠時 VACUUM 並截斷 WAL；回傳是否執行了。"""
    page_size = conn.execute("PRAGMA page_size").fetchone()[0]
    pages = conn.execute("PRAGMA page_count").fetchone()[0]
    free = conn.execute("PRAGMA freelist_count").fetchone()[0]
    try:
        last = int(meta(conn, "last_vacuum_at") or 0)
    except ValueError:
        last = 0
    # 上次的時間在未來（時鐘曾被設到未來）也視為到期，不然要等到那一天
    due = not 0 <= now - last < VACUUM_INTERVAL_DAYS * 86400 \
        or (free * page_size >= VACUUM_MIN_RECLAIM and free >= pages * VACUUM_FREE_RATIO)
    if not due:
        return False
    size = pages * page_size
    path = conn.execute("PRAGMA database_list").fetchone()[2]
    try:
        if shutil.disk_usage(os.path.dirname(path) or ".").free < 2 * size + VACUUM_DISK_MARGIN:
            return False
    except OSError:
        return False
    try:
        conn.execute("VACUUM")
    except sqlite3.OperationalError as e:
        # 等不到寫入鎖、暫存空間不夠（暫存資料夾可能在別的磁碟區）或剛好被寫滿：資料沒事（VACUUM 是一個交易），
        # 下次清理再試；不讓 record_safely 記成「被鎖住或已損毀，建議清除歷史」（總檢查 F-03）
        log(f"整理 history.sqlite3 失敗（{type(e).__name__}），下次清理再試")
        return False
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_vacuum_at', ?)", (str(now),))
    # App 正在讀時截斷不了：TRUNCATE 會用 busy handler 等讀取結束，所以暫時不等（busy_timeout 0，回傳 busy）；
    # 下次 checkpoint 照常，不影響 VACUUM 的結果（審查 C-01）
    timeout = int(conn.execute("PRAGMA busy_timeout").fetchone()[0])
    conn.execute("PRAGMA busy_timeout = 0")
    try:
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    except sqlite3.OperationalError:
        pass
    finally:
        conn.execute(f"PRAGMA busy_timeout = {timeout}")
    after = conn.execute("PRAGMA page_count").fetchone()[0] * page_size
    if size - after >= VACUUM_MIN_RECLAIM:
        log(f"整理 history.sqlite3：{size / 1048576:.1f} MB → {after / 1048576:.1f} MB")
    return True


def record(snapshot: dict, path: Path | None = None, now: datetime | None = None) -> int:
    path = path or HISTORY_PATH
    now = now or datetime.now(timezone.utc)
    with _private_files():
        # 寫入前先確保既有檔案只有自己能讀（新檔案由 umask 077 保護）
        _tighten_permissions(path)
        conn = connect(path)
        try:
            count = write_samples(conn, snapshot)
            maybe_cleanup(conn, int(now.timestamp()), now.astimezone().date())
        finally:
            conn.close()
    _tighten_permissions(path)
    return count


def tidy(path: Path | None = None, now: datetime | None = None) -> None:
    """只做每天一次的清理（`--tokens-only`，Windows 排程的預設）：`record` 只在收集額度時執行。"""
    path = path or HISTORY_PATH
    now = now or datetime.now(timezone.utc)
    if not path.exists():
        return  # Token 統計沒能建立資料庫：沒有東西要清
    with _private_files():
        _tighten_permissions(path)
        conn = connect(path)
        try:
            maybe_cleanup(conn, int(now.timestamp()), now.astimezone().date())
        finally:
            conn.close()
    _tighten_permissions(path)


def tidy_safely(path: Path | None = None) -> bool:
    """`tidy` 的外層：不丟出任何例外，日誌只記錄類別。Windows 的 `--tokens-only` 沒有 `record`，
    損毀復原的連續失敗由這裡計算（ADR-0014 D-1）。"""
    target = path or HISTORY_PATH
    try:
        tidy(path)
        if target.exists():
            history_care.succeeded(target)
        return True
    except HistoryError as e:
        log(f"略過歷史清理：{e}")
    except sqlite3.DatabaseError as e:
        log(f"略過歷史清理（{type(e).__name__}）：history.sqlite3 被鎖住或已損毀")
        history_care.failed(target, int(time.time()))
    except Exception as e:
        log(f"略過歷史清理：{type(e).__name__}")
    return False


def record_safely(snapshot: dict, path: Path | None = None) -> bool:
    """`record` 的外層：不丟出任何例外。回傳是否寫入成功。
    連續寫不進去、而且檔案確定損毀時改名保留並建新檔，這一輪就寫進新檔（ADR-0014 D-1，history_care）。"""
    target = path or HISTORY_PATH
    try:
        record(snapshot, path)
        history_care.succeeded(target)
        return True
    except HistoryError as e:
        log(f"略過額度歷史：{e}")
    except sqlite3.DatabaseError as e:
        # 鎖住（另一個程序寫入超過 5 秒）或檔案損毀；訊息可能含路徑，只記類別
        log(f"略過額度歷史（{type(e).__name__}）：history.sqlite3 被鎖住或已損毀；"
            "損毀時收集器約 1 小時後會改名保留並建立新檔")
        if history_care.failed(target, int(time.time())):
            try:
                record(snapshot, path)
                return True
            except Exception as e:
                log(f"略過額度歷史：新檔也寫不進去（{type(e).__name__}）")
    except Exception as e:
        log(f"略過額度歷史：{type(e).__name__}")
    return False
