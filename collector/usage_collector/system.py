"""平台差異集中在這裡（ADR-0011 第 2 節「Windows 收集器」、FR-48）：資料夾、CLI 的常見安裝位置、
降低優先順序、開檔旗標、時區與結束子程序。其他模組不直接判斷平台。"""
from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Mapping
from datetime import datetime, tzinfo
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError, available_timezones

IS_WINDOWS = sys.platform == "win32"

# 讀對話紀錄時不跟隨符號連結（ADR-0009 第 3 節）；Windows 沒有 O_NOFOLLOW（列舉時已略過連結），另加 O_BINARY
OPEN_READ_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)

BELOW_NORMAL_PRIORITY_CLASS = 0x00004000
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_NO_WINDOW = 0x08000000


def default_home(environ: Mapping[str, str] = os.environ, windows: bool = IS_WINDOWS) -> Path:
    """沒有設定 AI_USAGE_MONITOR_HOME 時的資料夾：macOS 為 ~/Library/Application Support/AIUsageMonitor，
    Windows 為 %LOCALAPPDATA%\\AIUsageMonitor。"""
    if windows:
        base = environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "AIUsageMonitor"
    return Path.home() / "Library" / "Application Support" / "AIUsageMonitor"


def executable_fallbacks(name: str, environ: Mapping[str, str] = os.environ, windows: bool = IS_WINDOWS) -> tuple[str, ...]:
    """config.json 與 PATH 都找不到時再試的常見安裝位置。
    macOS：ChatGPT.app 內附的 Codex CLI。Windows：Claude Code 的原生安裝（%USERPROFILE%\\.local\\bin）與
    npm 全域安裝（%APPDATA%\\npm 的 .cmd）。"""
    if not windows:
        return ("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",) if name == "codex" else ()
    home = environ.get("USERPROFILE") or str(Path.home())
    appdata = environ.get("APPDATA") or str(Path(home) / "AppData" / "Roaming")
    return (str(Path(home) / ".local" / "bin" / f"{name}.exe"),
            str(Path(appdata) / "npm" / f"{name}.cmd"))


# Windows 上 subprocess 能直接啟動的副檔名。npm 另外產生的 codex.ps1 要經過 PowerShell，不能直接執行
LAUNCHABLE_SUFFIXES = (".exe", ".cmd", ".bat", ".com")


def is_launchable(path: str) -> bool:
    """可以用 subprocess.Popen([path, ...]) 直接執行的檔案。Windows 的 os.access(X_OK) 對任何存在的檔案都成立，
    改看副檔名。"""
    if IS_WINDOWS:
        return os.path.isfile(path) and os.path.splitext(path)[1].lower() in LAUNCHABLE_SUFFIXES
    return os.access(path, os.X_OK)


def entry_stat(entry: os.DirEntry) -> os.stat_result:
    """列舉到的檔案的 stat（不跟隨連結）。Windows 的 DirEntry.stat() 一律把 st_ino、st_dev 填 0，
    和開檔後 fstat 的值對不起來（每個檔案都會被當成「被換掉」而略過），要另外呼叫 os.stat。"""
    if IS_WINDOWS:
        return os.stat(entry.path, follow_symlinks=False)
    return entry.stat(follow_symlinks=False)


def file_identity(st: os.stat_result) -> tuple[int, int]:
    """(st_dev, st_ino) 換成 SQLite 存得下的有號 64 位元整數。Windows 的 st_dev 是磁碟區序號，
    可能 ≥ 2⁶³（寫進 scan_state 時 OverflowError，該檔永遠略過）；以二補數折成負數，比對時兩邊用同一個換算。"""
    def signed(n: int) -> int:
        n &= (1 << 64) - 1
        return n - (1 << 64) if n >= 1 << 63 else n
    return signed(st.st_dev), signed(st.st_ino)


def lower_priority() -> None:
    """降低這個程序的優先順序（首次掃描可能讀數百 MB）：macOS 用 nice，Windows 用 BELOW_NORMAL_PRIORITY_CLASS。"""
    if sys.platform == "win32":
        import ctypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.SetPriorityClass(kernel32.GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS)
    else:
        os.nice(10)


def isolated_popen_kwargs() -> dict:
    """子程序放在自己的 process group（逾時時連同它的子程序一起結束）；Windows 另外不開主控台視窗。"""
    if IS_WINDOWS:
        return {"creationflags": CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW}
    return {"start_new_session": True}


def kill_tree(proc: subprocess.Popen) -> None:
    """強制結束子程序與它啟動的子程序。macOS 由呼叫端以 killpg 分段處理，這裡只給 Windows 用。"""
    subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, creationflags=CREATE_NO_WINDOW, check=False)


def local_datetime(ts: float) -> datetime:
    """Unix 秒 → 本機時區的時間（不帶 tzinfo）。Token 統計的日期與小時都以它計算；
    Windows 不能用 TZ／time.tzset 切換時區，測試改 patch 這個函式。"""
    return datetime.fromtimestamp(ts)


def zone(name: str, local: tzinfo | None) -> tzinfo | None:
    """IANA 時區名稱 → tzinfo。Windows 的 Python 預設沒有時區資料庫（要另裝 tzdata 套件）：完全沒有資料庫時
    以本機時區代替（Claude Code 顯示的就是本機時區），有資料庫但名稱不認得時照樣丟出 ZoneInfoNotFoundError。"""
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError:
        if IS_WINDOWS and not available_timezones():
            return local
        raise
