"""委派 Claude Code 續期 token（ADR-0005）。

收集器自己不發送刷新請求、不寫入憑證。token 已過期或快過期時執行一次
`claude -p /usage`，讓 Claude Code 用它自己的流程（含鎖）續期並寫回 Keychain，
之後由呼叫端重新讀取。這依賴 Claude Code 未寫入文件的行為：`-p` 啟動時會續期快過期的 token。
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Callable

from .log import log
from .models import ProviderError
from .paths import CLAUDE_REFRESH_STATE_PATH, CONFIG_PATH

# /usage 在 -p 模式是本機指令，不呼叫模型；--safe-mode 略過 hooks、外掛與 MCP，啟動更快也不會觸發使用者的自訂流程
REFRESH_ARGS = ("-p", "/usage", "--safe-mode", "--no-session-persistence")
REFRESH_TIMEOUT = 30          # 秒；正常約 1.5 秒
REFRESH_MARGIN = 5 * 60       # 距離 expiresAt 不到 5 分鐘就續期（Claude Code 啟動時也用類似門檻）
ATTEMPT_INTERVAL = 30 * 60    # 續期嘗試最多每 30 分鐘一次，避免用量端點限流
NOTIFY_AFTER = 30 * 60        # 過期且續期失敗超過 30 分鐘才通知

_UNSET = object()


def seconds_left(oauth: dict, now: float) -> float | None:
    expires_at = oauth.get("expiresAt")
    return expires_at / 1000 - now if expires_at else None


def is_expired(oauth: dict, now: float) -> bool:
    left = seconds_left(oauth, now)
    return left is not None and left <= 0


def needs_refresh(oauth: dict, now: float) -> bool:
    left = seconds_left(oauth, now)
    return left is not None and left < REFRESH_MARGIN


def resolve_claude_path(config_path: Path = CONFIG_PATH) -> str | None:
    """安裝腳本把偵測到的完整路徑寫進 config.json 的 claude_path（launchd 的 PATH 找不到 claude）；
    手動執行時退回 PATH。都找不到就回傳 None，略過續期。"""
    try:
        path = json.loads(config_path.read_text()).get("claude_path")
    except (FileNotFoundError, json.JSONDecodeError, AttributeError):
        path = None
    path = path or shutil.which("claude")
    return path if path and os.access(path, os.X_OK) else None


def run_claude(path: str, timeout: float = REFRESH_TIMEOUT) -> str:
    """回傳 "completed"、"failed" 或 "timed_out"。輸出全部丟棄，不會進日誌。"""
    with tempfile.TemporaryDirectory(prefix="aum-claude-") as cwd:
        try:
            # stdin 關閉：-p 在 stdin 是開著的管線時會等待輸入
            result = subprocess.run([path, *REFRESH_ARGS], cwd=cwd, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
        except subprocess.TimeoutExpired:
            return "timed_out"
        except OSError:
            return "failed"
    return "completed" if result.returncode == 0 else "failed"


def notify(message: str, title: str = "AI Usage Monitor") -> None:
    # 用 argv 傳字串，不必處理 AppleScript 的跳脫
    script = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)",
              "-e", "end run"]
    try:
        subprocess.run(["osascript", *script, message, title], capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        log("claude: 無法發送 macOS 通知")


def load_state(path: Path) -> dict:
    try:
        state = json.loads(path.read_text())
        return state if isinstance(state, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(state: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def ensure_fresh(
    oauth: dict,
    reload: Callable[[], dict],
    *,
    now: float | None = None,
    claude_path: str | None | object = _UNSET,
    state_path: Path = CLAUDE_REFRESH_STATE_PATH,
    run: Callable[[str], str] = run_claude,
    send_notification: Callable[[str], None] = notify,
) -> dict:
    """回傳可用的登入資訊；token 已過期且無法續期時丟出 ProviderError。"""
    now = time.time() if now is None else now
    state = load_state(state_path)
    original = dict(state)

    if needs_refresh(oauth, now) and now - state.get("last_attempt_at", 0) >= ATTEMPT_INTERVAL:
        path = resolve_claude_path() if claude_path is _UNSET else claude_path
        state["last_attempt_at"] = now
        save_state(state, state_path)  # 先記錄，續期中途當掉也不會每 5 分鐘重試
        if path:
            outcome = run(path)
            log(f"claude: token {'已過期' if is_expired(oauth, now) else '即將過期'}，"
                f"已委派 Claude Code 續期（{outcome}）")
            oauth = reload()
        else:
            log("claude: 找不到 claude 執行檔，略過自動續期")

    if not is_expired(oauth, now):
        # 續期成功（或還沒過期）：結束這次過期的失敗紀錄
        state.pop("failing_since", None)
        state.pop("notified_expires_at", None)
        if state != original:
            save_state(state, state_path)
        return oauth

    failing_since = state.setdefault("failing_since", now)
    if now - failing_since >= NOTIFY_AFTER and state.get("notified_expires_at") != oauth.get("expiresAt"):
        # 同一次過期（同一個 expiresAt）只通知一次
        send_notification("Claude token 已過期且無法自動續期，請開一次 Claude Code。")
        state["notified_expires_at"] = oauth.get("expiresAt")
    if state != original:
        save_state(state, state_path)
    raise ProviderError("token 已過期，自動續期未成功，開一次 Claude Code 即可續期")
