from __future__ import annotations

import json
import os
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from .models import iso_utc

# 日誌超過這個大小就改名為 `<檔名>.1`（覆蓋上一份）重新開始：每個日誌最多約 2 MB（ADR-0014）
MAX_LOG_BYTES = 1_000_000


# 相同的一行連續出現（每 5 分鐘一輪都失敗）時每小時只記一次，不再出現時記一行「已恢復」（ADR-0014 LT-02 後續）
REPEAT_INTERVAL = 3600
# 記住的不同訊息最多這麼多種（每種一列，避免狀態檔無限變大）
REPEAT_MAX_TRACKED = 50

_repeats: _Repeats | None = None


def log(message: str) -> None:
    if _repeats is not None:
        text = _repeats.filter(message, int(time.time()))
        if text is not None:
            _write(text)
        return
    _write(message)


def _write(text: str) -> None:
    # launchd 會把 stderr 導到日誌檔，加上時間方便追查。日誌寫不進去（磁碟滿、檔案已關）時放棄這一行：
    # 記錄失敗不能中斷收集，尤其是磁碟不足時照常上傳（ADR-0014 LT-06，審查 C-01）
    try:
        print(f"[{iso_utc(datetime.now(timezone.utc))}] {text}", file=sys.stderr, flush=True)
    except (OSError, ValueError):
        pass


def _duration(seconds: int) -> str:
    minutes = max(seconds, 0) // 60
    if minutes < 60:
        return f"{minutes} 分鐘"
    hours, minutes = divmod(minutes, 60)
    return f"{hours} 小時 {minutes} 分" if minutes else f"{hours} 小時"


class _Repeats:
    """一輪收集裡的訊息與上一輪的比較。狀態（每種訊息：第一次、最後一次出現與記錄的時間、略過幾次）存在
    日誌旁邊的 `<日誌>.repeats.json`：每輪是一個新的程序，只能靠檔案知道上一輪記過什麼。"""

    def __init__(self, path: Path):
        self.path = path
        self.seen: set[str] = set()
        self.entries: dict[str, dict[str, int]] = {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        if isinstance(data, dict):
            for message, entry in data.items():
                if isinstance(entry, dict) and all(isinstance(entry.get(k), int) for k in ("first", "last", "logged", "skipped")):
                    self.entries[message] = {k: entry[k] for k in ("first", "last", "logged", "skipped")}

    def filter(self, message: str, now: int) -> str | None:
        """這一行要寫的文字；略過時為 None。同一輪裡重複的一行只寫第一次"""
        if message in self.seen:
            return None
        entry = self.entries.get(message)
        if entry is None or not 0 <= now - entry["logged"]:
            # 第一次出現（或時鐘倒退）：照常記錄
            self.entries[message] = {"first": now, "last": now, "logged": now, "skipped": 0}
            text: str | None = message
        elif now - entry["logged"] >= REPEAT_INTERVAL:
            text = f"{message}（仍在發生，已持續 {_duration(now - entry['first'])}，期間略過 {entry['skipped']} 次）"
            entry.update(last=now, logged=now, skipped=0)
        else:
            entry.update(last=now, skipped=entry["skipped"] + 1)
            text = None
        self.seen.add(message)
        return text

    def finish(self, now: int) -> None:
        """上一輪出現、這一輪沒有出現的訊息：連續出現過（略過過）的記一行「已恢復」，然後忘掉"""
        for message, entry in list(self.entries.items()):
            if message in self.seen:
                continue
            if entry["last"] > entry["first"]:
                _write(f"已恢復：{message}（持續 {_duration(entry['last'] - entry['first'])}）")
            del self.entries[message]
        keep = sorted(self.entries.items(), key=lambda item: item[1]["last"], reverse=True)[:REPEAT_MAX_TRACKED]
        try:
            if keep:
                # 每個程序自己的暫存檔：同時結束的兩輪（手動執行與排程用同一個 --log-file）不會互相搬走對方的檔案。
                # 兩輪的狀態後寫的蓋掉先寫的，最多讓下一輪多記一行，不另外加鎖（審查 C-02）
                tmp = self.path.with_name(f"{self.path.name}.{os.getpid()}.tmp")
                # 內容是日誌的訊息：只有使用者自己能讀（與 App 內建收集器的日誌相同，審查 C-01）
                fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(json.dumps(dict(keep), ensure_ascii=False))
                os.chmod(tmp, 0o600)  # 之前留下的暫存檔可能是別的權限
                os.replace(tmp, self.path)
            else:
                self.path.unlink(missing_ok=True)
        except OSError:
            # 寫不進去（磁碟滿、權限）：下一輪當成第一次出現，照常記錄
            if keep:
                tmp.unlink(missing_ok=True)


def repeats_path(log_path: Path, owner: str = "") -> Path:
    """`log_path` 的重複訊息狀態檔；同一個日誌有兩種寫入者時以 `owner` 分開"""
    return log_path.with_name(f"{log_path.name}{'.' + owner if owner else ''}.repeats.json")


@contextmanager
def limit_repeats(state_path: Path | None) -> Iterator[None]:
    """在這段期間（一輪收集）以狀態檔 `state_path` 限制重複的訊息；None 時不限制（終端機、測試）"""
    global _repeats
    if state_path is None:
        yield
        return
    _repeats = _Repeats(state_path)
    try:
        yield
    finally:
        repeats, _repeats = _repeats, None
        repeats.finish(int(time.time()))


def stderr_is(path: Path) -> bool:
    """stderr 是不是 `path` 這個檔案（launchd 依 plist 開好的日誌）"""
    try:
        st = path.stat()
    except OSError:
        return False
    return _identity(2) == (st.st_dev, st.st_ino)


def rotate_if_large(path: Path, limit: int = MAX_LOG_BYTES, expected: tuple[int, int] | None = None) -> bool:
    """`path` 超過 `limit` 位元組時改名為 `<檔名>.1`（只留一份舊的），回傳是否改名。
    改名失敗（Windows 上別的程序開著這個檔、權限）時不輪替，這次照常附加。
    改名前再確認一次還是剛才量的那個檔（`expected` 或量大小時的 inode）：另一個收集器剛輪替過時，
    `path` 已經是新的短檔，不能拿它蓋掉剛存好的 `.1`（審查 C-02）。"""
    try:
        st = path.stat()
        if st.st_size <= limit or (expected is not None and (st.st_dev, st.st_ino) != expected):
            return False
        now = path.stat()
        if (now.st_dev, now.st_ino) != (st.st_dev, st.st_ino):
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
    if 2 not in targets or not rotate_if_large(path, limit, expected=old):
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
