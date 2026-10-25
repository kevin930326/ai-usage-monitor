"""Codex provider（ADR-0007）。

執行未修改的 Codex CLI：`codex app-server --listen stdio://` 是 Codex 給桌面 App、編輯器外掛使用的本機介面
（標準輸入輸出上一行一個 JSON-RPC 訊息）。收集器只送 `initialize` 與 `account/rateLimits/read`：
不開對話、不呼叫模型、不消耗額度，也不使用重置次數卷（只讀張數與到期時間；使用卷的方法不在程式裡，
`tests/test_codex.py` 會掃描確認）。收集器不讀取 Codex 的登入檔、不持有 token、不直接呼叫用量端點；
token 的讀取與續期都由 Codex CLI 自己完成。

app-server 標示為 experimental，回應格式沒有保證：只取認得的欄位，格式不對時整個視為格式改變，
不猜測、不把缺少的欄位當成 0%。回應含帳號 ID 等資料，除了額度與方案名稱一律不保留；
app-server 的 stderr 直接丟棄，錯誤訊息不帶出它的內容，不會進入日誌或快照。
"""
from __future__ import annotations

import json
import os
import queue
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import IO, cast

from .. import __version__, paths, system
from ..models import ProviderError, ProviderUsage, ResetCredits, Window, parse_pct

APP_SERVER_ARGS = ("app-server", "--listen", "stdio://")
# 安裝腳本沒寫入 codex_path 時（舊安裝、Windows）也找得到：macOS 為 ChatGPT.app 內附的 Codex CLI，
# Windows 為 npm 全域安裝的 codex.cmd 等（system.executable_fallbacks）
FALLBACK_PATHS = system.executable_fallbacks("codex")
TIMEOUT = 30  # 秒，整段對話；正常約 0.7 秒
MAX_WINDOW_MINUTES = 366 * 24 * 60  # 更長的額度長度視為格式改變（window id 也不會超過中繼的長度上限）
CLOSE_TIMEOUT = 3  # 關閉 stdin 後等 app-server 自己結束的秒數，超過就強制結束
MAX_OUTPUT = 1024 * 1024  # 讀取的位元組上限，避免異常輸出吃光記憶體
# 與中繼的 LIMITS.resetCredits／resetCreditDetails 相同：張數超過視為格式不對；明細只留最早到期的幾張
MAX_RESET_CREDITS = 1000
MAX_RESET_CREDIT_DETAILS = 16

FORMAT_CHANGED = "Codex app-server 的回應格式已改變，請更新收集器"

PLAN_NAMES = {"pro": "Pro", "plus": "Plus", "team": "Team", "business": "Business", "free": "Free",
              "go": "Go", "enterprise": "Enterprise", "edu": "Edu"}
# 不在對照表的方案（prolite、edu_plus …）轉成 `Prolite`、`Edu Plus`；其他字元或太長時不顯示方案名稱
PLAN_RE = re.compile(r"^[a-z0-9_]{1,32}$")


def resolve_codex_path(config_path: Path | None = None) -> str | None:
    """config.json 的 codex_path（安裝腳本偵測），手動執行時退回 PATH 與 ChatGPT.app 內附的 codex。"""
    return paths.resolve_executable("codex_path", "codex", FALLBACK_PATHS, config_path)


class AppServer:
    """一次性的 app-server 連線：啟動、依序送出請求並讀取對應的回應，結束時確實關閉。"""

    def __init__(self, path: str):
        self.deadline = time.monotonic() + TIMEOUT
        self.buffer = b""
        self.received = 0
        self.next_id = 1
        # 暫存資料夾：不讓 app-server 以收集器的工作目錄當成專案
        self.cwd = tempfile.TemporaryDirectory(prefix="aum-codex-")
        # npm 安裝的 codex 是 `#!/usr/bin/env node` 腳本，launchd 的 PATH 只有系統目錄：
        # 把 codex 所在的資料夾（Homebrew 的 node 也在這）放到最前面
        base = paths.cli_environ()  # config.json 的 codex_home 也要傳下去（Codex C-02）
        env = {**base, "PATH": os.pathsep.join(filter(None, (os.path.dirname(path), base.get("PATH"))))}
        try:
            # 自己的 process group：逾時時連同 app-server 可能啟動的子程序一起結束
            self.proc = subprocess.Popen([path, *APP_SERVER_ARGS], cwd=self.cwd.name, env=env,
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, **system.isolated_popen_kwargs())
        except OSError:
            self.cwd.cleanup()
            raise ProviderError("無法執行 codex，重新執行 scripts/install-launchd.sh") from None
        try:
            if system.IS_WINDOWS:
                # Windows 的 select 不支援管線：由背景執行緒讀 stdout，主執行緒等待佇列
                self.chunks: queue.Queue[bytes] = queue.Queue()
                self.pumped = 0
                self.reader = threading.Thread(target=self._pump, daemon=True)
                self.reader.start()
            else:
                self.selector = selectors.DefaultSelector()
                self.selector.register(self._stdout, selectors.EVENT_READ)
        except BaseException:
            self.proc.kill()
            self.proc.wait()
            self._stdin.close()
            self._stdout.close()
            self.cwd.cleanup()
            raise

    def __enter__(self):
        return self

    def __exit__(self, exc_type, *exc):
        try:
            self.close()
        except Exception:
            if exc_type is None:
                raise
            # 已經有錯誤在傳遞中：不讓清理時的錯誤蓋掉原本的錯誤

    def send(self, message: dict) -> None:
        try:
            self._stdin.write((json.dumps(message) + "\n").encode())
            self._stdin.flush()
        except OSError:  # 含 BrokenPipeError：app-server 已經結束
            raise ProviderError("Codex app-server 意外結束") from None

    def request(self, method: str, params: dict | None = None) -> dict:
        """送出請求並等待同一個 id 的回應，回傳整個回應物件（含 result 或 error）。"""
        request_id = self.next_id
        self.next_id += 1
        self.send({"method": method, "id": request_id, "params": params})
        while True:
            message = self.read_message()
            # 沒有 method 的才是回應；通知（沒有 id）與伺服器發來的請求都略過
            if "method" not in message and message.get("id") == request_id:
                return message

    # stdin／stdout 都是 PIPE，不會是 None（型別上是 Optional）
    @property
    def _stdin(self) -> IO[bytes]:
        return cast("IO[bytes]", self.proc.stdin)

    @property
    def _stdout(self) -> IO[bytes]:
        return cast("IO[bytes]", self.proc.stdout)

    def _pump(self) -> None:
        """Windows：持續讀 stdout 放進佇列；讀到結尾（或管線關閉）時放空位元組。
        超過 MAX_OUTPUT 就不再讀（主執行緒累計同樣的位元組，還在等回應時會以 FORMAT_CHANGED 結束），
        佇列不會無限長大；app-server 之後寫滿管線就會停住，由 close() 結束。"""
        try:
            while chunk := os.read(self._stdout.fileno(), 65536):
                self.chunks.put(chunk)
                self.pumped += len(chunk)
                if self.pumped > MAX_OUTPUT:
                    return
        except OSError:
            pass
        self.chunks.put(b"")

    def _next_chunk(self, remaining: float) -> bytes | None:
        """等最多 `remaining` 秒讀到下一段輸出；逾時回傳 None，結束時回傳空位元組。"""
        if system.IS_WINDOWS:
            try:
                return self.chunks.get(timeout=remaining)
            except queue.Empty:
                return None
        if not self.selector.select(remaining):
            return None
        return os.read(self._stdout.fileno(), 65536)

    def read_message(self) -> dict:
        while b"\n" not in self.buffer:
            remaining = self.deadline - time.monotonic()
            chunk = self._next_chunk(remaining) if remaining > 0 else None
            if chunk is None:
                raise ProviderError(f"Codex app-server 回應逾時（{TIMEOUT:g} 秒）")
            if not chunk:
                raise ProviderError("Codex app-server 意外結束")
            self.received += len(chunk)
            if self.received > MAX_OUTPUT:
                raise ProviderError(FORMAT_CHANGED)
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        try:
            message = json.loads(line)
        except ValueError:  # 含 JSONDecodeError 與 UnicodeDecodeError
            raise ProviderError(FORMAT_CHANGED) from None
        if not isinstance(message, dict):
            raise ProviderError(FORMAT_CHANGED)
        return message

    def close(self) -> None:
        """關閉 stdin，app-server 收到 EOF 會自己結束（約 0.05 秒）；等不到就結束整個 process group，
        不留下背景程序。"""
        try:
            if not system.IS_WINDOWS:
                self.selector.close()
            try:
                self._stdin.close()
            except OSError:
                pass
            if system.IS_WINDOWS:
                try:
                    self.proc.wait(CLOSE_TIMEOUT)
                except subprocess.TimeoutExpired:
                    system.kill_tree(self.proc)
                    self.proc.wait(CLOSE_TIMEOUT)
                self.reader.join(CLOSE_TIMEOUT)  # 程序結束後管線關閉，讀取執行緒隨即結束
                return
            self._terminate_group()
        finally:
            self._stdout.close()
            self.cwd.cleanup()

    def _terminate_group(self) -> None:
        """macOS：等 app-server 自己結束，等不到就依序送 SIGTERM、SIGKILL 給整個 process group。"""
        if sys.platform == "win32":  # Windows 在 close() 以 kill_tree 結束；這裡讓型別檢查知道
            return
        for sig in (None, signal.SIGTERM, signal.SIGKILL):
            if sig is not None:
                try:
                    os.killpg(self.proc.pid, sig)
                except OSError:
                    # 已經結束：沒有這個 group 是 ESRCH；macOS 對只剩殭屍的 group 回 EPERM。照樣 wait 收掉
                    pass
            try:
                self.proc.wait(CLOSE_TIMEOUT)
                break
            except subprocess.TimeoutExpired:
                continue


def result_of(response: dict, failure: str) -> dict:
    """取出回應的 result。錯誤訊息可能含帳號資訊，不帶出去，只用來判斷是不是沒登入。"""
    error = response.get("error")
    if error is not None:
        message = error.get("message") if isinstance(error, dict) else None
        if isinstance(message, str) and "authentication required" in message:
            raise ProviderError("尚未登入 Codex CLI，請在終端機執行 codex login")
        code = error.get("code") if isinstance(error, dict) else None
        has_code = isinstance(code, int) and not isinstance(code, bool)
        raise ProviderError(failure + (f"（代碼 {code}）" if has_code else ""))
    result = response.get("result")
    if not isinstance(result, dict):
        raise ProviderError(FORMAT_CHANGED)
    return result


def window_label(minutes: int) -> tuple[str, str]:
    if minutes == 7 * 24 * 60:
        return "weekly", "每週"
    if minutes == 5 * 60:
        return "five_hour", "5 小時"
    if minutes % 60 == 0:
        return f"{minutes // 60}h", f"{minutes // 60} 小時"
    return f"{minutes}m", f"{minutes} 分鐘"


def plan_name(plan: object) -> str | None:
    if not isinstance(plan, str) or plan == "unknown" or not PLAN_RE.match(plan):
        return None
    return PLAN_NAMES.get(plan) or plan.replace("_", " ").title()


def parse_window(w: object) -> Window:
    if not isinstance(w, dict):
        raise ProviderError(FORMAT_CHANGED)
    minutes = w.get("windowDurationMins")
    if isinstance(minutes, bool) or not isinstance(minutes, int) or not 0 < minutes <= MAX_WINDOW_MINUTES:
        raise ProviderError(FORMAT_CHANGED)  # 不知道是哪一種額度：不猜
    wid, label = window_label(minutes)
    resets = w.get("resetsAt")
    if resets is None or resets == 0:
        resets_at = None  # 舊端點的 0 也是「沒有重置時間」
    else:
        try:
            resets_at = parse_timestamp(resets)
        except ValueError:
            raise ProviderError(FORMAT_CHANGED) from None
    return Window(wid, label, parse_pct(w.get("usedPercent")), resets_at)


def parse_timestamp(value: object) -> datetime:
    """Unix 秒數 → UTC 時間；不是非負整數或超出範圍時丟 ValueError。"""
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError
    try:
        return datetime.fromtimestamp(value, tz=timezone.utc)
    except (OverflowError, OSError) as e:
        raise ValueError from e


def parse_reset_credits(summary: object) -> ResetCredits | None:
    """`rateLimitResetCredits` → 可用張數與各張到期時間。只留這兩項，卷的 id、標題、取得時間不保留。
    重置卷是額度之外的附加資訊：缺少（舊版 Codex CLI）或格式不對時回傳 None（不顯示），不影響額度。
    `credits` 為 null 表示後端只給了張數；明細可能有上限，張數以 `availableCount` 為準。"""
    if not isinstance(summary, dict):
        return None
    count = summary.get("availableCount")
    if isinstance(count, bool) or not isinstance(count, int) or not 0 <= count <= MAX_RESET_CREDITS:
        return None
    details = summary.get("credits")
    if details is None:
        details = []
    if not isinstance(details, list):
        return None
    expires: list[datetime | None] = []
    for credit in details:
        if not isinstance(credit, dict):
            return None
        if credit.get("status") != "available":
            continue  # 兌換中、已使用的卷不算（明細應該只有可用的）
        value = credit.get("expiresAt")
        try:
            expires.append(None if value is None else parse_timestamp(value))
        except ValueError:
            return None
    # 最早到期的在前，不會到期的放最後
    expires.sort(key=lambda e: (e is None, e or datetime.min.replace(tzinfo=timezone.utc)))
    return ResetCredits(available=count, expires_at=expires[:MAX_RESET_CREDIT_DETAILS])


def parse(result: dict) -> ProviderUsage:
    """`account/rateLimits/read` 的 result → ProviderUsage。只讀 `rateLimits`（Codex 的主要額度，
    與舊的用量端點相同）的 primary／secondary 與 planType，以及重置次數卷的張數與到期時間；
    accountId、credits（點數餘額）等欄位不讀取。"""
    snapshot = result.get("rateLimits")
    if not isinstance(snapshot, dict):
        raise ProviderError(FORMAT_CHANGED)
    windows: list[Window] = []
    for key in ("primary", "secondary"):
        if snapshot.get(key) is None:
            continue  # 沒有這個額度：與舊端點回傳 null 時相同，略過
        window = parse_window(snapshot[key])
        if any(w.id == window.id for w in windows):
            raise ProviderError(FORMAT_CHANGED)  # 兩個額度長度相同：不猜哪個才對
        windows.append(window)
    if not windows:
        raise ProviderError("Codex 回應中沒有用量資料")
    return ProviderUsage(plan=plan_name(snapshot.get("planType")), windows=windows,
                         reset_credits=parse_reset_credits(result.get("rateLimitResetCredits")))


def fetch() -> ProviderUsage:
    path = resolve_codex_path()
    if not path:
        raise ProviderError("找不到 codex 執行檔，重新執行 scripts/install-launchd.sh")
    with AppServer(path) as server:
        result_of(server.request("initialize", {
            "clientInfo": {"name": "ai_usage_monitor", "title": "AI Usage Monitor", "version": __version__},
        }), "Codex app-server 初始化失敗")
        server.send({"method": "initialized", "params": {}})
        result = result_of(server.request("account/rateLimits/read"), "Codex app-server 查詢額度失敗")
    return parse(result)
