"""磁碟空間不足時的保護（ADR-0014 LT-06）：剩餘空間不到 LOW_DISK_BYTES 時暫停寫入 history.sqlite3
（額度歷史、Token 統計、第二層同步、每日清理），usage.json 與上傳照常。

狀態改變時才記日誌：用資料夾裡的空檔案 `disk-low` 記住「目前是不足」（不能靠資料庫，暫停期間不寫它；
Windows 的 `--tokens-only` 也沒有 usage.json）。`shutil.disk_usage` 在 macOS 與 Windows 都讀得到剩餘空間。
"""
from __future__ import annotations

import shutil
from pathlib import Path

from . import paths
from .log import log

LOW_DISK_BYTES = 500 * 1024 * 1024
MARKER = "disk-low"


def free_bytes(path: Path) -> int | None:
    """`path` 所在磁碟的剩餘空間；資料夾還不存在時看最近存在的上層。讀不到時回傳 None（當成足夠）。"""
    while not path.exists() and path.parent != path:
        path = path.parent
    try:
        return shutil.disk_usage(path).free
    except OSError:
        return None


def low_space(directory: Path | None = None) -> int | None:
    """剩餘空間不足時回傳剩餘位元組，足夠或讀不到時回傳 None；狀態改變時記一行日誌。"""
    directory = directory or paths.APP_SUPPORT_DIR
    free = free_bytes(directory)
    low = free if free is not None and free < LOW_DISK_BYTES else None
    marker = directory / MARKER
    was_low = marker.exists()
    if low is not None and not was_low:
        log(f"磁碟剩餘空間不足（{low // (1024 * 1024)} MB）：暫停寫入額度歷史與 Token 統計，usage.json 與上傳照常")
        try:
            marker.touch()
        except OSError:
            pass  # 寫不進去就下一輪再記一次
    elif low is None and was_low:
        log("磁碟空間已恢復：繼續寫入額度歷史與 Token 統計")
        try:
            marker.unlink()
        except OSError:
            pass
    return low
