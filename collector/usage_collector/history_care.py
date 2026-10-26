"""history.sqlite3 的損毀復原與每週備份（ADR-0014 D-1）。

- 損毀復原：額度歷史連續 RECOVER_AFTER 輪（約 1 小時）都因 `sqlite3.DatabaseError` 寫不進去，而且
  `PRAGMA quick_check` 也說檔案壞了（或根本不是資料庫）時，把舊檔連同 -wal、-shm 改名為
  `history.corrupt-<時間>.sqlite3` 保留，下一次寫入建立新檔。只是被鎖住、權限或讀取錯誤（OperationalError，
  quick_check 跑不完）不算損毀的證據，不動檔案。保留的舊檔最多 KEEP_CORRUPT 份。
- 連續失敗的次數記在資料夾裡的 `history-failures.json`（不能記在壞掉的資料庫裡），寫入成功就刪掉。
  改名後 `history-recovered.json` 記下時間與檔名：收集器 NOTICE_DAYS 天內在 usage.json 的 `local_status`
  提示，Mac 面板顯示；App 的「清除歷史」連同它、每週備份與保留的舊檔一起刪掉。
- 每週備份：每天的清理（`history.maybe_cleanup`）順便檢查，距離上次成功超過 7 天時，用 SQLite 的線上備份 API
  （`sqlite3` 的 `.backup` 用的同一個）把資料庫複製到 `backups/history-<日期>.sqlite3`，quick_check 通過才換上，
  只留最近 KEEP_BACKUPS 份（總量最多兩份資料庫大小）。複製後磁碟剩餘空間會低於 `disk.LOW_DISK_BYTES` 時跳過。
  任何失敗只記日誌、不寫 `last_backup_at`，隔天再試，不影響收集。
"""
from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from . import disk
from .log import log

RECOVER_AFTER = 12  # 收集器每 5 分鐘一輪：連續約 1 小時
KEEP_CORRUPT = 2
NOTICE_DAYS = 7
BACKUP_INTERVAL_DAYS = 7
KEEP_BACKUPS = 2
BACKUP_DIR = "backups"
FAILURES_FILE = "history-failures.json"
RECOVERED_FILE = "history-recovered.json"
CORRUPT_PREFIX = "history.corrupt-"
CHECK_TIMEOUT = 5  # 秒：與 history.BUSY_TIMEOUT_MS 相同


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_json(path: Path, data: dict) -> None:
    """先寫暫存檔再換上；只有自己能讀（0600）。"""
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def _remove(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


# MARK: - 損毀復原

def succeeded(path: Path) -> None:
    """寫入成功：連續失敗歸零。"""
    try:
        _remove(path.parent / FAILURES_FILE)
    except OSError:
        pass


def failed(path: Path, now: int) -> bool:
    """記一次 `DatabaseError`；連續 RECOVER_AFTER 的倍數輪時檢查檔案，確定損毀就改名保留。回傳是否改名了。"""
    counter = path.parent / FAILURES_FILE
    state = _read_json(counter)
    try:
        count = int(state.get("count", 0)) + 1
    except (TypeError, ValueError):
        count = 1
    try:
        _write_json(counter, {"count": count, "since": state.get("since", now)})
    except OSError:
        pass  # 記不下來就照常（這一輪不算）
    if count % RECOVER_AFTER or check(path) != "corrupt":
        return False
    kept = quarantine(path, now)
    if kept is None:
        return False
    succeeded(path)
    try:
        _write_json(path.parent / RECOVERED_FILE, {"at": now, "kept_as": kept})
    except OSError:
        pass
    log(f"history.sqlite3 已損毀（連續 {count} 輪寫不進去，quick_check 也失敗）：改名保留為 {kept}，"
        "建立新檔重新記錄；可以從 backups/ 的每週備份還原（docs/runbook.md）")
    return True


def check(path: Path) -> str:
    """`ok`、`corrupt`（quick_check 有錯，或不是資料庫）或 `unknown`（打不開、被鎖住，不能當成損毀）。"""
    if not path.is_file():
        return "unknown"
    try:
        conn = sqlite3.connect(str(path), timeout=CHECK_TIMEOUT)
    except sqlite3.Error:
        return "unknown"
    try:
        return "ok" if _intact(conn) else "corrupt"
    except sqlite3.OperationalError:
        return "unknown"
    except sqlite3.DatabaseError:
        return "corrupt"  # file is not a database、database disk image is malformed
    finally:
        conn.close()


def _intact(conn: sqlite3.Connection) -> bool:
    return conn.execute("PRAGMA quick_check(1)").fetchall() == [("ok",)]


def quarantine(path: Path, now: int) -> str | None:
    """把壞掉的資料庫連同 -wal、-shm 改名保留；回傳新檔名，改不了時回傳 None。"""
    stamp = datetime.fromtimestamp(now).strftime("%Y%m%d-%H%M%S")
    target = path.with_name(f"{CORRUPT_PREFIX}{stamp}.sqlite3")
    try:
        os.replace(path, target)
    except OSError as e:
        log(f"history.sqlite3 已損毀，但無法改名（{type(e).__name__}）：把檔案移走，或在設定中清除歷史")
        return None
    for suffix in ("-wal", "-shm"):
        side = Path(f"{path}{suffix}")
        try:
            os.replace(side, Path(f"{target}{suffix}"))
        except FileNotFoundError:
            pass
        except OSError:
            # 舊的 -wal 不能留在原位：新檔開啟時 SQLite 會把它套用到新檔上
            try:
                _remove(side)
            except OSError as e:
                log(f"無法移走 history.sqlite3{suffix}（{type(e).__name__}），請手動刪除")
    _prune(path.parent, f"{CORRUPT_PREFIX}*.sqlite3", KEEP_CORRUPT)
    return target.name


def notice(directory: Path, now: int) -> dict | None:
    """NOTICE_DAYS 天內自動改名保留過時，給 usage.json 的 `local_status`。"""
    data = _read_json(directory / RECOVERED_FILE)
    at, kept = data.get("at"), data.get("kept_as")
    if not isinstance(at, int) or not isinstance(kept, str) or not 0 <= now - at < NOTICE_DAYS * 86400:
        return None
    reset_at = datetime.fromtimestamp(at, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"history_reset_at": reset_at, "history_kept_as": kept}


def _prune(directory: Path, pattern: str, keep: int) -> None:
    """依檔名（含日期）留下最新的 `keep` 份，其他連同 -wal、-shm 刪掉。"""
    for old in sorted(directory.glob(pattern))[:-keep]:
        for p in (old, Path(f"{old}-wal"), Path(f"{old}-shm")):
            try:
                _remove(p)
            except OSError:
                pass


# MARK: - 每週備份

def maybe_backup(conn: sqlite3.Connection, now: int) -> bool:
    """距離上次成功超過 7 天時備份；回傳是否備份了。不丟出任何例外。"""
    try:
        row = conn.execute("SELECT value FROM meta WHERE key = 'last_backup_at'").fetchone()
        try:
            last = int(row[0]) if row else 0
        except (TypeError, ValueError):
            last = 0
        # 上次的時間在未來（時鐘曾被設到未來）也視為到期
        if 0 <= now - last < BACKUP_INTERVAL_DAYS * 86400:
            return False
        path = Path(conn.execute("PRAGMA database_list").fetchone()[2])
        if not backup(conn, path.parent / BACKUP_DIR, now):
            return False
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_backup_at', ?)", (str(now),))
        return True
    except Exception as e:
        log(f"每週備份 history.sqlite3 失敗（{type(e).__name__}），下次清理再試")
        return False


def backup(conn: sqlite3.Connection, folder: Path, now: int) -> bool:
    """把 `conn` 的資料庫複製成 `folder/history-<日期>.sqlite3`（單一檔案、quick_check 通過），只留最近兩份。"""
    size = conn.execute("PRAGMA page_count").fetchone()[0] * conn.execute("PRAGMA page_size").fetchone()[0]
    folder.mkdir(mode=0o700, exist_ok=True)
    free = disk.free_bytes(folder)
    if free is not None and free - size < disk.LOW_DISK_BYTES:
        log("略過每週備份 history.sqlite3：備份後磁碟剩餘空間會不足")
        return False
    day = datetime.fromtimestamp(now).strftime("%Y%m%d")
    target = folder / f"history-{day}.sqlite3"
    for leftover in folder.glob(".history-*.tmp*"):  # 上次被強制結束留下的（含 -journal）
        _remove(leftover)
    tmp = folder / f".history-{day}.tmp"
    dest = sqlite3.connect(str(tmp))
    try:
        conn.backup(dest)
        dest.execute("PRAGMA journal_mode = DELETE")  # 備份是單一檔案，不帶 -wal
        ok = _intact(dest)
    except BaseException:
        dest.close()
        _remove(tmp)
        raise
    dest.close()
    if not ok:
        _remove(tmp)
        log("略過每週備份 history.sqlite3：複製出來的檔案沒有通過 quick_check（原檔可能已損毀）")
        return False
    os.replace(tmp, target)
    _prune(folder, "history-*.sqlite3", KEEP_BACKUPS)
    return True
