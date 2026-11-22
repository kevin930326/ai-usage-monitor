"""Gemini provider（ADR-0022）。

Google AI Pro／Ultra 寫程式用的額度在 Antigravity。Antigravity 開著時，本機有一個官方的 `language_server`
（Antigravity 自己的介面也靠它取得額度），它把連線資訊寫在 `~/.gemini/antigravity/daemon/hub_<port>.json`：
`pid`、`httpPort`（只聽 127.0.0.1）與 `csrfToken`（只用來呼叫這個本機服務，不是 Google 帳號的 token）。

收集器只呼叫 `RetrieveUserQuotaSummary` 一個方法（帶 `forceRefresh`，否則會拿到一天以上的舊快取）：
不開對話、不呼叫模型、不消耗額度。Google 帳號的登入與 API 呼叫都由 Antigravity 自己完成，
收集器不讀取 Antigravity 的登入資訊，也不直接連 Google；不呼叫會回傳 email 與姓名的 `GetUserStatus`，
所以不顯示方案名稱。

這是沒有公開文件的介面，只取認得的欄位：Gemini 模型這一組的 5 小時與每週額度是主要額度，
Claude／GPT 與 Argon 兩組列為次要額度（`hidden`），其他認不得的額度略過。csrfToken 不會進入日誌、
錯誤訊息或快照；回應的錯誤訊息也不帶出去。
"""
from __future__ import annotations

import json
import math
import os
import re
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

from .. import system
from ..models import ProviderError, ProviderUsage, Window, parse_iso, parse_pct

METHOD = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
TIMEOUT = 15  # 秒；正常約 0.5 秒（forceRefresh 會讓 language server 向 Google 重新取得）
MAX_OUTPUT = 1024 * 1024
MAX_DAEMON_FILE = 64 * 1024

FORMAT_CHANGED = "Antigravity 的回應格式已改變，請更新收集器"
NOT_RUNNING = "Antigravity 沒有開啟，開啟後才會更新 Gemini 額度"

# bucketId 的開頭 → (額度 id 的後綴, 名稱的後綴, 是否為次要額度)；依序比對，第一個符合的為準
GROUPS = (
    ("gemini-argon", "_argon", " Argon", True),
    ("gemini-", "", "", False),
    ("3p-", "_claude_gpt", " Claude／GPT", True),
)
WINDOWS = {"5h": ("five_hour", "5 小時"), "weekly": ("weekly", "每週")}
FRACTION_RE = re.compile(r"\.(\d+)")


def daemon_dir() -> Path:
    return Path.home() / ".gemini" / "antigravity" / "daemon"


def pid_alive(pid: int) -> bool:
    if system.IS_WINDOWS:
        return True  # Windows 的 os.kill(pid, 0) 會送 CTRL_C_EVENT：不檢查，連不上時一樣報沒有開啟
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def find_server(directory: Path | None = None) -> tuple[int, str]:
    """回傳 (httpPort, csrfToken)：最近修改、程序還在的 `hub_*.json`。都沒有時丟 NOT_RUNNING。"""
    directory = directory or daemon_dir()
    try:
        files = sorted(directory.glob("hub_*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        files = []
    for path in files:
        try:
            if path.stat().st_size > MAX_DAEMON_FILE:
                continue
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        pid, port, token = data.get("pid"), data.get("httpPort"), data.get("csrfToken")
        if (isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0
                or isinstance(port, bool) or not isinstance(port, int) or not 0 < port < 65536
                or not isinstance(token, str) or not token):
            continue
        if pid_alive(pid):
            return port, token
    raise ProviderError(NOT_RUNNING)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """不跟隨重新導向：預設的處理會把 csrfToken 標頭一起帶到導向的網址（可能不在本機，審查 C-01）。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ProviderError("Antigravity 回應了重新導向，沒有跟隨")


def request(port: int, token: str) -> dict:
    """呼叫本機 language server。代理伺服器一律不用、不跟隨重新導向：請求（含 csrfToken）只送到 127.0.0.1。"""
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{METHOD}", data=json.dumps({"forceRefresh": True}).encode(), method="POST",
        headers={"Content-Type": "application/json", "Connect-Protocol-Version": "1",
                 "x-codeium-csrf-token": token})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(req, timeout=TIMEOUT) as response:
            body = response.read(MAX_OUTPUT + 1)
    except urllib.error.HTTPError as e:
        raise ProviderError(http_error(e)) from None
    except (urllib.error.URLError, ConnectionError):
        raise ProviderError(NOT_RUNNING) from None
    except TimeoutError:
        raise ProviderError(f"Antigravity 回應逾時（{TIMEOUT:g} 秒）") from None
    if len(body) > MAX_OUTPUT:
        raise ProviderError(FORMAT_CHANGED)
    try:
        data = json.loads(body)
    except ValueError:
        raise ProviderError(FORMAT_CHANGED) from None
    if not isinstance(data, dict):
        raise ProviderError(FORMAT_CHANGED)
    return data


def http_error(e: urllib.error.HTTPError) -> str:
    """只看 Connect 的錯誤代碼（固定的英文字），訊息本身可能含帳號資料，不帶出去。"""
    try:
        code = json.loads(e.read(64 * 1024)).get("code")
    except (OSError, ValueError, AttributeError):
        code = None
    if code == "unauthenticated":
        return "尚未登入 Antigravity，請開啟 Antigravity 登入 Google 帳號"
    if e.code in (401, 403):
        return "Antigravity 拒絕連線，請重新開啟 Antigravity"
    return f"Antigravity 查詢額度失敗（HTTP {e.code}）"


def parse_reset(value: object) -> datetime:
    """`2026-11-28T09:00:02Z`（可能帶小數秒）→ UTC 時間；格式不對時丟 ProviderError。"""
    if not isinstance(value, str) or len(value) > 40:
        raise ProviderError(FORMAT_CHANGED)
    try:
        dt = parse_iso(FRACTION_RE.sub("", value, count=1))
    except ValueError:
        raise ProviderError(FORMAT_CHANGED) from None
    if dt.tzinfo is None:
        raise ProviderError(FORMAT_CHANGED)
    return dt


def parse_bucket(bucket: object) -> Window | None:
    """一個額度 → Window；不是認得的分組或長度時回傳 None（略過）。"""
    if not isinstance(bucket, dict):
        raise ProviderError(FORMAT_CHANGED)
    bucket_id, window = bucket.get("bucketId"), bucket.get("window")
    if not isinstance(bucket_id, str) or not isinstance(window, str):
        raise ProviderError(FORMAT_CHANGED)
    group = next((g for g in GROUPS if bucket_id.startswith(g[0])), None)
    if group is None or window not in WINDOWS:
        return None
    _, id_suffix, label_suffix, hidden = group
    base_id, base_label = WINDOWS[window]
    # protobuf 的 JSON 省略 0：沒有 remainingFraction 就是用完了
    fraction = bucket.get("remainingFraction", 0)
    if isinstance(fraction, bool) or not isinstance(fraction, (int, float)) or not math.isfinite(fraction) \
            or not 0 <= fraction <= 1:
        raise ProviderError(FORMAT_CHANGED)
    # 還沒用的額度，resetTime 是「現在＋額度長度」，每次查都往後移：當成還沒開始計時
    resets_at = None if fraction >= 1 or "resetTime" not in bucket else parse_reset(bucket["resetTime"])
    return Window(base_id + id_suffix, base_label + label_suffix, parse_pct((1 - fraction) * 100), resets_at, hidden)


def parse(data: dict) -> ProviderUsage:
    response = data.get("response")
    groups = response.get("groups") if isinstance(response, dict) else None
    if not isinstance(groups, list):
        raise ProviderError(FORMAT_CHANGED)
    windows: list[Window] = []
    for group in groups:
        buckets = group.get("buckets") if isinstance(group, dict) else None
        if not isinstance(buckets, list):
            raise ProviderError(FORMAT_CHANGED)
        for bucket in buckets:
            window = parse_bucket(bucket)
            if window is None:
                continue
            if any(w.id == window.id for w in windows):
                raise ProviderError(FORMAT_CHANGED)  # 同一種額度出現兩次：不猜哪個才對
            windows.append(window)
    if not any(not w.hidden for w in windows):
        raise ProviderError("Antigravity 回應中沒有 Gemini 額度")
    # 主要額度在前（5 小時、每週），次要額度依原本的順序
    windows.sort(key=lambda w: (w.hidden, 0 if w.hidden else ("five_hour", "weekly").index(w.id)))
    return ProviderUsage(plan=None, windows=windows)


def fetch() -> ProviderUsage:
    port, token = find_server()
    return parse(request(port, token))
