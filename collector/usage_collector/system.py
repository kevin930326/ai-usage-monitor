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
CREATE_NEW_CONSOLE = 0x00000010
STARTF_USESHOWWINDOW = 0x00000001
SW_HIDE = 0


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


def hidden_console_kwargs() -> dict:
    """Windows：子程序開在新的主控台，視窗以 SW_HIDE 隱藏，並放在自己的 process group。
    不用 CREATE_NO_WINDOW：那樣子程序的主控台沒有視窗，claude／codex 再啟動的孫程序（hook、MCP 伺服器、
    Python 工具等）有時會被 Windows 另開一個看得到的新主控台，收集器每輪就閃出空白視窗。
    改成隱藏的主控台後，整棵程序樹共用這一個看不到的主控台。macOS／Linux 回傳空的 dict。"""
    if sys.platform != "win32":
        return {}
    startupinfo = subprocess.STARTUPINFO()  # 每次新建：subprocess 會改寫它的 dwFlags 與標準輸入輸出
    startupinfo.dwFlags |= STARTF_USESHOWWINDOW
    startupinfo.wShowWindow = SW_HIDE
    return {"creationflags": CREATE_NEW_PROCESS_GROUP | CREATE_NEW_CONSOLE, "startupinfo": startupinfo}


def isolated_popen_kwargs() -> dict:
    """子程序放在自己的 process group（逾時時連同它的子程序一起結束）；Windows 另外開在隱藏的主控台。"""
    if IS_WINDOWS:
        return hidden_console_kwargs()
    return {"start_new_session": True}


def kill_tree(proc: subprocess.Popen) -> None:
    """強制結束子程序與它啟動的子程序。macOS 由呼叫端以 killpg 分段處理，這裡只給 Windows 用。"""
    subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False, **hidden_console_kwargs())


CLEANUP_TIMEOUT = 5  # 秒；逾時結束程序樹後，等管線關閉的上限
PROCESS_TERMINATE = 0x0001
PROCESS_SET_QUOTA = 0x0100


def _job_for(pid: int) -> int | None:
    """Windows：把剛啟動的程序放進新的 Job Object，它之後啟動的子孫程序都會跟著在裡面；
    父程序先結束時 taskkill /T 找不到孫程序，以 TerminateJobObject 一次結束。失敗時回傳 None（退回 taskkill）。"""
    if sys.platform != "win32":
        return None
    import ctypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateJobObjectW.restype = ctypes.c_void_p
    kernel32.OpenProcess.restype = ctypes.c_void_p
    job = kernel32.CreateJobObjectW(None, None)
    if not job:
        return None
    process = kernel32.OpenProcess(PROCESS_TERMINATE | PROCESS_SET_QUOTA, False, pid)
    assigned = bool(process) and kernel32.AssignProcessToJobObject(ctypes.c_void_p(job), ctypes.c_void_p(process))
    if process:
        kernel32.CloseHandle(ctypes.c_void_p(process))
    if not assigned:
        kernel32.CloseHandle(ctypes.c_void_p(job))
        return None
    return job


def _close_job(job: int | None, terminate: bool) -> None:
    if sys.platform != "win32" or job is None:
        return
    import ctypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    if terminate:
        kernel32.TerminateJobObject(ctypes.c_void_p(job), 1)
    kernel32.CloseHandle(ctypes.c_void_p(job))


def run_isolated(argv: list[str], timeout: float, **kwargs) -> subprocess.CompletedProcess:
    """subprocess.run 的替代：Windows 開在隱藏的主控台與自己的 process group，並放進 Job Object；
    逾時時結束整棵程序樹（含父程序已結束後留下的孫程序），等管線關閉最多 CLEANUP_TIMEOUT 秒，再丟出 TimeoutExpired
    （subprocess.run 只會結束子程序本身，孫程序會留下，且孫程序握著管線時會一直等）。macOS／Linux 照舊直接呼叫 subprocess.run。"""
    if not IS_WINDOWS:
        return subprocess.run(argv, timeout=timeout, **kwargs)
    if kwargs.pop("capture_output", False):
        kwargs["stdout"] = kwargs["stderr"] = subprocess.PIPE
    proc = subprocess.Popen(argv, **kwargs, **isolated_popen_kwargs())
    job = _job_for(proc.pid)
    timed_out = False
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        _close_job(job, terminate=True)
        job = None
        kill_tree(proc)
        proc.kill()
        try:
            proc.communicate(timeout=CLEANUP_TIMEOUT)
        except subprocess.TimeoutExpired:
            pass
        raise
    finally:
        _close_job(job, terminate=False)
        if timed_out:
            for pipe in (proc.stdout, proc.stderr):
                if pipe is not None:
                    pipe.close()
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


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
