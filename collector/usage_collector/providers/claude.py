"""Claude provider。

token 來源：Claude Code CLI 登入後存在 macOS Keychain 的 "Claude Code-credentials"。
用量來源：Claude Code `/usage` 使用的非公開 OAuth 端點。
"""
from __future__ import annotations

import json
import subprocess

from .. import claude_refresh
from ..http import get_json
from ..models import ProviderError, ProviderUsage, Window, parse_iso, parse_pct

KEYCHAIN_SERVICE = "Claude Code-credentials"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

# API 欄位 → (統一 id, 顯示名稱)
WINDOWS = {
    "five_hour": ("five_hour", "5 小時"),
    "seven_day": ("weekly", "每週"),
}


def read_credentials() -> dict:
    result = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise ProviderError("找不到 Claude Code 登入資訊")
    try:
        oauth = json.loads(result.stdout)["claudeAiOauth"]
    except (json.JSONDecodeError, KeyError):
        raise ProviderError("尚未在終端機登入 Claude Code") from None
    return oauth


def parse(body: dict, plan: str | None) -> ProviderUsage:
    windows = []
    for key, (wid, label) in WINDOWS.items():
        w = body.get(key)
        if not w:
            continue
        resets_at = parse_iso(w["resets_at"]) if w.get("resets_at") else None
        windows.append(Window(wid, label, parse_pct(w.get("utilization")), resets_at))
    if not windows:
        raise ProviderError("回應中沒有用量資料，API 可能已變更")
    windows.extend(parse_scoped_limits(body.get("limits") or []))
    return ProviderUsage(plan=plan, windows=windows)


def parse_scoped_limits(limits: list) -> list[Window]:
    """各模型的每週額度（FR-14），列為 hidden。"""
    windows = []
    for item in limits:
        if item.get("kind") != "weekly_scoped":
            continue
        name = (((item.get("scope") or {}).get("model") or {}).get("display_name"))
        if not name:
            continue
        try:
            pct = parse_pct(item.get("percent"))
        except ProviderError:
            continue  # 隱藏的次要額度格式不對時只略過這一項，不讓整個服務失敗
        resets_at = parse_iso(item["resets_at"]) if item.get("resets_at") else None
        windows.append(Window(f"weekly_{name.lower()}", f"每週 {name}", pct, resets_at, hidden=True))
    return windows


def fetch() -> ProviderUsage:
    # 不自行刷新 token，避免和 Claude Code 互搶；快過期時委派 Claude Code 續期後重新讀取（ADR-0005）
    oauth = claude_refresh.ensure_fresh(read_credentials(), read_credentials)
    body = get_json(USAGE_URL, {
        "Authorization": f"Bearer {oauth['accessToken']}",
        "anthropic-beta": "oauth-2025-04-20",
    })
    plan = oauth.get("subscriptionType")
    return parse(body, plan.title() if plan else None)
