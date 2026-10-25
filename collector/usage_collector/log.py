from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from .models import iso_utc

# 日誌超過這個大小就改名為 `<檔名>.1`（覆蓋上一份）重新開始：每個日誌最多約 2 MB（ADR-0014）
MAX_LOG_BYTES = 1_000_000


def log(message: str) -> None:
    # launchd 會把 stderr 導到日誌檔，加上時間方便追查
    print(f"[{iso_utc(datetime.now(timezone.utc))}] {message}", file=sys.stderr)


def rotate_if_large(path: Path, limit: int = MAX_LOG_BYTES) -> bool:
    """`path` 超過 `limit` 位元組時改名為 `<檔名>.1`（只留一份舊的），回傳是否改名。
    改名失敗（Windows 上別的程序開著這個檔、權限）時不輪替，這次照常附加。"""
    try:
        if path.stat().st_size <= limit:
            return False
        os.replace(path, path.with_name(path.name + ".1"))
        return True
    except OSError:
        return False


def _identity(fd: int) -> tuple[int, int] | None:
    try:
        st = os.fstat(fd)
    except OSError:
        return None
    return (st.st_dev, st.st_ino)


def rotate_inherited(path: Path, limit: int = MAX_LOG_BYTES) -> bool:
    """launchd 依 plist 的 StandardErrorPath／StandardOutPath 開好檔案才啟動收集器：stderr 確實是 `path`、
    而且超過 `limit` 時，改名後把 stdout／stderr 重新指向新的 `path`。stderr 是終端機或別的檔案時不動。"""
    try:
        st = path.stat()
    except OSError:
        return False
    old = (st.st_dev, st.st_ino)
    targets = [fd for fd in (1, 2) if _identity(fd) == old]
    if 2 not in targets or not rotate_if_large(path, limit):
        return False
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except (OSError, ValueError):
            pass
    # 開不了新檔（磁碟滿、權限）時沿用原本的描述元：它指向剛改名的 `.1`，日誌照寫，收集照常（審查 C-01）
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    except OSError:
        return False
    try:
        for target in targets:
            os.dup2(fd, target)
    except OSError:
        return False
    finally:
        os.close(fd)
    return True
