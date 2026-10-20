from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

from .paths import LOCAL_SNAPSHOT_PATH


def write_snapshot(snapshot: dict, path: Path = LOCAL_SNAPSHOT_PATH) -> Path:
    """原子寫入：先寫同目錄的暫存檔再改名，讀取端不會讀到寫一半的檔案。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".usage-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(snapshot, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return path
