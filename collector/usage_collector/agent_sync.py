"""跨裝置的 AI 狀態（ADR-0019 第 2 節）：只同步狀態的入口 `python -m usage_collector agent-sync`。

- 只有打開的電腦才執行：config.json 的 `agent_sync` 為 true（set-tier2.sh --agent-sync／set-tier2.ps1 -AgentSync 寫入）、
  有 https 的 `relay_url`，而且這台已經啟用第二層（有裝置密鑰、已上傳過一次，知道自己在中繼上的 device_id）。
- 上傳：讀 App 寫的 `agent-state.json`（每個 AI 的最高狀態、工作階段數、進入時間；沒有資料夾名稱、工作階段 ID 或任何內容），
  以裝置密鑰 POST /agents/state。內容和上次一樣、而且上次在 10 分鐘內時不傳；App 沒在跑（Mac：連不上 hook.sock；
  Windows：App 的 Mutex 不在）或檔案超過 10 分鐘沒更新時，上傳一次「全部閒置」後不再傳。兩次上傳至少隔 60 秒。
- 下載：有讀取密鑰時 GET /agents/state（至少隔 60 秒），拿掉自己這台（用過的所有 device_id）與裝置 ID，寫成 `agent-remote.json`
  （App 讀，30 分鐘內的才顯示）。
- 中繼回 404（舊版或 AGENT_SYNC 沒打開）：記一次日誌、1 小時後再試。其他失敗 5 分鐘後再試。都不算進第二層的撤銷計數。
- 日誌只記錄狀態碼與錯誤類別，不記錄密鑰、網址與內容；狀態沒變時不重複記錄。任何失敗都不影響收集器的其他工作與結束碼。

規則與 Swift（UsageKit/AgentSync.swift）、C#（UsageCore/AgentSync.cs）相同，`fixtures/agent` 的 golden 三邊比對。
"""
from __future__ import annotations

import hashlib
import json
import os
import socket
import sqlite3
import sys
import tempfile
import time
import unicodedata
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path

from . import credentials, history
from .http import HTTPStatusError, request_json
from .local_store import remove_stale_temp
from .log import log
from .models import ProviderError
from .paths import APP_SUPPORT_DIR, CONFIG_PATH

VERSION = 1
STATE_PATH = APP_SUPPORT_DIR / "agent-state.json"
REMOTE_PATH = APP_SUPPORT_DIR / "agent-remote.json"
MIN_INTERVAL = 60  # 秒：兩次上傳、兩次下載至少隔這麼久
HEARTBEAT = 600  # 秒：內容沒變時多久再傳一次（其他電腦以中繼收到的時間判斷 30 分鐘內才顯示）
STALE = 600  # 秒：agent-state.json 超過這麼久沒更新，當成 App 沒在跑（App 至少每 5 分鐘重寫一次）
NOT_SUPPORTED_RETRY = 3600
RETRY = 300
MAX_FILE = 4096
MAX_RESPONSE = 64 * 1024
MAX_DEVICES = 16
NAME_MAX = 32
AIS = ("claude", "codex")
STATES = ("needsYou", "error", "working", "done", "waiting", "idle")
WINDOWS_MUTEX = "Local\\io.github.kevin930326.AIUsageMonitor.Windows"
EMPTY = {"v": VERSION, "ais": []}
LOCK_FILE = ".agent-sync.lock"
LOCK_WAIT = 150  # 秒：另一個同步（App 觸發的與 5 分鐘一輪的）最多等 60 秒間隔＋上傳、下載各 30 秒
STALE_LOCK = 300  # 秒：鎖檔超過這麼久當成上一個程序被強制結束


# MARK: - 格式（golden）

def _int(value: object) -> int | None:
    """JSON 的整數（1.0 也算；布林與其他小數不算），同 Swift／C#"""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if abs(value) < 9 * 10**15 else None
    if isinstance(value, float) and value.is_integer() and abs(value) < 9e15:
        return int(value)
    return None


def _row(value: object) -> dict | None:
    if not isinstance(value, dict):
        return None
    ai, state = value.get("ai"), value.get("state")
    sessions, since = _int(value.get("sessions")), _int(value.get("since"))
    if ai not in AIS or state not in STATES or sessions is None or not 0 <= sessions <= 32 or since is None or since < 0:
        return None
    return {"ai": ai, "state": state, "sessions": sessions, "since": since}


def encode(body: dict) -> str:
    """鍵的順序固定、沒有空白（和 Swift、C# 的 AgentSummary 輸出一字不差）"""
    return json.dumps(body, ensure_ascii=False, separators=(",", ":"))


def read_state(data: bytes) -> dict | None:
    """驗證 App 寫的 agent-state.json：版本、AI 白名單且不重複、狀態白名單、工作階段數 0～32。任何一處不對就整個不用"""
    if len(data) > MAX_FILE:
        return None
    try:
        root = json.loads(data.decode("utf-8"), object_pairs_hook=_no_duplicates)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(root, dict) or _int(root.get("v")) != VERSION or not isinstance(root.get("ais"), list):
        return None
    rows = [_row(r) for r in root["ais"]]
    if len(rows) > len(AIS) or any(r is None for r in rows) or len({r["ai"] for r in rows if r}) != len(rows):
        return None
    return {"v": VERSION, "ais": rows}


def _no_duplicates(pairs: list[tuple[str, object]]) -> dict:
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")
    return dict(pairs)


def clean_name(name: str) -> str:
    """控制字元與格式字元拿掉、前後的空白（Zs 與 tab）去掉、最多 32 個字元（同 Swift 的 Unicode 純量、C# 的 Rune）"""
    kept = [c for c in name if unicodedata.category(c) not in ("Cc", "Cf")]

    def space(c: str) -> bool:
        return c == "\t" or unicodedata.category(c) == "Zs"
    while kept and space(kept[0]):
        kept.pop(0)
    while kept and space(kept[-1]):
        kept.pop()
    return "".join(kept[:NAME_MAX])


def remote_file(response: object, own: set[str], fetched_at: int) -> dict | None:
    """中繼 GET /agents/state 的回應 → agent-remote.json：拿掉自己這台與 device_id，名稱清理過，格式不對的裝置或列略過。
    回應本身格式不對時回傳 None（不寫檔，保留上一份）"""
    if not isinstance(response, dict):
        return None
    now, devices = _int(response.get("now")), response.get("devices")
    if now is None or not isinstance(devices, list):
        return None
    out: list[dict] = []
    for device in devices:
        if len(out) >= MAX_DEVICES:
            break
        if not isinstance(device, dict) or device.get("device_id") in own or not isinstance(device.get("device_id"), str):
            continue
        name, updated, ais = device.get("name"), _int(device.get("updated_at")), device.get("ais")
        if not isinstance(name, str) or updated is None or not isinstance(ais, list):
            continue
        name = clean_name(name)
        rows = [r for r in (_row(a) for a in ais[:len(AIS)]) if r is not None]
        if not name or len({r["ai"] for r in rows}) != len(rows):
            continue
        out.append({"name": name, "ais": rows, "updated_at": updated})
    return {"v": VERSION, "fetched_at": fetched_at, "now": now, "devices": out}


# MARK: - 設定與狀態

def load_config(path: Path | None = None) -> str | None:
    """打開了而且有 https 的中繼網址時回傳網址，否則 None"""
    try:
        config = json.loads((path or CONFIG_PATH).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(config, dict) or config.get("agent_sync") is not True:
        return None
    url = config.get("relay_url")
    return url.rstrip("/") if isinstance(url, str) and url.startswith("https://") else None


def app_running() -> bool:
    """App 在不在跑：Mac 連得上 hook.sock（連上立刻關，App 收到空的連線直接丟掉）；Windows 打得開 App 的 Mutex"""
    if sys.platform == "win32":
        import ctypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        handle = kernel32.OpenMutexW(0x00100000, False, WINDOWS_MUTEX)  # SYNCHRONIZE
        if handle:
            kernel32.CloseHandle(handle)
            return True
        return False
    path = APP_SUPPORT_DIR / "agent" / "hook.sock"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(0.2)
        s.connect(str(path))
        return True
    except OSError:
        return False
    finally:
        s.close()


def local_body(now: float, running: Callable[[], bool] = app_running, path: Path | None = None) -> dict:
    """要上傳的內容：App 沒在跑、檔案太舊、讀不到或格式不對時是「全部閒置」"""
    path = path or STATE_PATH
    try:
        st = path.stat()
        data = path.read_bytes() if st.st_size <= MAX_FILE else b""
    except OSError:
        return EMPTY
    if now - st.st_mtime > STALE or not running():
        return EMPTY
    return read_state(data) or EMPTY


def _meta_int(conn: sqlite3.Connection, key: str) -> int:
    try:
        return int(history.meta(conn, key) or 0)
    except ValueError:
        return 0


def _set_meta(conn: sqlite3.Connection, **values: object) -> None:
    conn.executemany("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [(k, str(v)) for k, v in values.items()])


def _report(conn: sqlite3.Connection, kind: str, status: str, message: str | None) -> None:
    key = f"agent_{kind}_status"
    if history.meta(conn, key) != status and message:
        log(message)
    _set_meta(conn, **{key: status})


def _failed(conn: sqlite3.Connection, kind: str, now: int, e: Exception) -> None:
    if isinstance(e, HTTPStatusError) and e.status == 404:
        _set_meta(conn, **{f"agent_{kind}_next_at": now + NOT_SUPPORTED_RETRY})
        _report(conn, kind, "not_supported", "中繼還不支援 AI 狀態同步（舊版或 AGENT_SYNC 沒打開），1 小時後再試")
        return
    _set_meta(conn, **{f"agent_{kind}_next_at": now + RETRY})
    what = f"HTTP {e.status}" if isinstance(e, HTTPStatusError) else str(e) if isinstance(e, ProviderError) else type(e).__name__
    _report(conn, kind, "error", f"AI 狀態{'上傳' if kind == 'upload' else '下載'}失敗（{what}），稍後重試")


def _own_ids(conn: sqlite3.Connection) -> set[str]:
    try:
        ids = json.loads(history.meta(conn, "relay_device_ids") or "[]")
    except ValueError:
        ids = []
    own = {i for i in ids if isinstance(i, str)} if isinstance(ids, list) else set()
    current = history.meta(conn, "relay_device_id")
    return own | {current} if current else own


# MARK: - 上傳與下載

def upload(conn: sqlite3.Connection, url: str, now: int, read_body: Callable[[int], dict],
           enabled: Callable[[], bool] = lambda: True) -> bool:
    """回傳是否真的送出。`read_body(now)` 讀這台的彙總；等候 60 秒的間隔後再讀一次，送出的是最新的狀態。
    等候期間關掉同步（`enabled()` 變成 False）就不送"""
    if now < _meta_int(conn, "agent_upload_next_at"):
        return False
    body = read_body(now)
    text = encode(body)
    digest = hashlib.sha256(text.encode()).hexdigest()[:32]
    last = _meta_int(conn, "agent_upload_at")
    same = history.meta(conn, "agent_upload_hash") == digest
    # 全部閒置傳過一次就不再傳；其他內容沒變時 10 分鐘傳一次（讓其他電腦知道這台還在）
    if same and (not body["ais"] or now - last < HEARTBEAT):
        return False
    key = credentials.read(credentials.DEVICE_KEY)
    if not key:
        return False
    if 0 <= now - last < MIN_INTERVAL:
        # 狀態剛改變又改變：等到滿 60 秒再送最新的（不丟掉這次改變）
        time.sleep(MIN_INTERVAL - (now - last))
        now += MIN_INTERVAL - (now - last)
        if not enabled():
            return False
        body = read_body(now)
        digest = hashlib.sha256(encode(body).encode()).hexdigest()[:32]
    try:
        request_json(f"{url}/agents/state", {"Authorization": f"Bearer {key}"}, body={"ais": body["ais"]})
    except ProviderError as e:
        _failed(conn, "upload", now, e)
        return False
    _set_meta(conn, agent_upload_hash=digest, agent_upload_at=now, agent_upload_next_at=0)
    _report(conn, "upload", "ok", None)
    return True


def download(conn: sqlite3.Connection, url: str, now: int, path: Path | None = None,
             enabled: Callable[[], bool] = lambda: True) -> bool:
    if now < _meta_int(conn, "agent_download_next_at") or 0 <= now - _meta_int(conn, "agent_download_at") < MIN_INTERVAL:
        return False
    read_key = credentials.read(credentials.READ_KEY)
    if not read_key:
        return False
    try:
        response = request_json(f"{url}/agents/state", {"Authorization": f"Bearer {read_key}"})
    except ProviderError as e:
        _failed(conn, "download", now, e)
        return False
    remote = remote_file(response, _own_ids(conn), now * 1000)
    if remote is None:
        _failed(conn, "download", now, ProviderError("回應格式不對"))
        return False
    if not enabled():  # 下載期間關掉同步：不重建 forget 刪掉的檔
        return False
    write_remote(remote, path or REMOTE_PATH)
    _set_meta(conn, agent_download_at=now, agent_download_next_at=0)
    _report(conn, "download", "ok", None)
    return True


def write_remote(remote: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    remove_stale_temp(path.parent, ".agent-remote-")
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".agent-remote-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(encode(remote))
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def run(path: Path | None = None, now: int | None = None, config_path: Path | None = None,
        running: Callable[[], bool] = app_running) -> None:
    url = load_config(config_path)
    if url is None:
        return
    path = path or history.HISTORY_PATH
    with sync_lock(path.parent) as locked:
        if not locked:
            return
        # 拿到鎖之後才看時間與狀態：等過另一個同步，節流的時間與要送的內容都要是新的
        _run_locked(path, url, int(time.time()) if now is None else now, config_path, running)


def _run_locked(path: Path, url: str, now: int, config_path: Path | None, running: Callable[[], bool]) -> None:
    def enabled() -> bool:
        return load_config(config_path) is not None

    with history._private_files():
        conn = history.connect(path)
        try:
            # 還沒上傳過第二層（不知道自己在中繼上的 device_id）：裝置密鑰可能還沒生效，也分不出哪台是自己
            if not history.meta(conn, "relay_device_id"):
                return
            # 自動提交（isolation_level=None）：等候與連線時不鎖住資料庫，Token 統計照常寫入
            upload(conn, url, now, lambda t: local_body(t, running), enabled)
            download(conn, url, now, enabled=enabled)
        finally:
            conn.close()


def run_safely(path: Path | None = None) -> None:
    """`run` 的外層：不丟出任何例外，日誌只記錄類別"""
    try:
        run(path)
    except history.HistoryError as e:
        log(f"略過 AI 狀態同步：{e}")
    except Exception as e:
        log(f"略過 AI 狀態同步：{type(e).__name__}")


def forget(path: Path | None = None) -> None:
    """關閉同步時刪除本機的其他電腦狀態（`set-tier2.sh --no-agent-sync`／`--disable`）；中繼上的不動，30 分鐘後自然不顯示。
    呼叫前設定已經關掉：先等進行中的同步結束（它寫檔前會再看一次設定），再刪"""
    path = path or REMOTE_PATH
    with sync_lock(path.parent):
        try:
            path.unlink()
        except FileNotFoundError:
            pass


@contextmanager
def sync_lock(directory: Path, wait: float = LOCK_WAIT) -> Iterator[bool]:
    """跨程序互斥（`O_EXCL` 建立鎖檔，Mac 與 Windows 都能用）：App 觸發的同步與 5 分鐘一輪的不同時讀寫進度、不並行上傳。
    另一個程序拿著時每秒再試，等 `wait` 秒還拿不到回傳 False"""
    lock = directory / LOCK_FILE
    waited = 0.0
    while True:
        try:
            os.close(os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
            break
        except FileExistsError:
            try:
                if time.time() - lock.stat().st_mtime >= STALE_LOCK:
                    lock.unlink(missing_ok=True)
                    continue
            except OSError:
                pass
        except OSError:
            yield False
            return
        if waited >= wait:
            yield False
            return
        time.sleep(1)
        waited += 1
    try:
        yield True
    finally:
        try:
            lock.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    # python -m usage_collector.agent_sync forget
    if sys.argv[1:] != ["forget"]:
        print("用法：python3 -m usage_collector.agent_sync forget", file=sys.stderr)
        sys.exit(2)
    forget()
