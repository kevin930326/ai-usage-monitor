from __future__ import annotations

import json
import os
import tempfile
import time
from pathlib import Path

from .paths import LOCAL_SNAPSHOT_PATH

STALE_TEMP_SECONDS = 86400


def remove_stale_temp(directory: Path, prefix: str, now: float | None = None) -> None:
    """刪掉 1 天以上的暫存檔：被強制結束（SIGKILL、斷電）時 except 不會執行，暫存檔會留下（ADR-0014 LT-20）。"""
    now = time.time() if now is None else now
    try:
        entries = list(directory.glob(f"{prefix}*.json"))
    except OSError:
        return
    for entry in entries:
        try:
            if now - entry.stat().st_mtime > STALE_TEMP_SECONDS:
                entry.unlink()
        except OSError:
            pass


def write_snapshot(snapshot: dict, path: Path = LOCAL_SNAPSHOT_PATH) -> Path:
    """原子寫入：先寫同目錄的暫存檔再改名，讀取端不會讀到寫一半的檔案。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    remove_stale_temp(path.parent, ".usage-")
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".usage-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(snapshot, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return path
