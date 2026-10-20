"""Claude provider。

token 來源：Claude Code CLI 登入後存在 macOS Keychain 的 "Claude Code-credentials"。
用量來源：Claude Code `/usage` 使用的非公開 OAuth 端點。
"""
from __future__ import annotations

import json
import subprocess
import time
from datetime import datetime

from ..http import get_json
from ..models import ProviderError, ProviderUsage, Window

KEYCHAIN_SERVICE = "Claude Code-credentials"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

# API 欄位 → 顯示名稱；不在表內的欄位不顯示
WINDOW_LABELS = {
    "five_hour": "5 小時",
    "seven_day": "每週",
    "seven_day_opus": "每週 Opus",
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
    # 不自行刷新 token，避免和 Claude Code 互搶；過期就等 Claude Code 下次啟動時續期
    if oauth.get("expiresAt") and oauth["expiresAt"] / 1000 < time.time():
        raise ProviderError("token 已過期，開一次 Claude Code 即可自動續期")
    return oauth


def parse(body: dict, plan: str | None) -> ProviderUsage:
    windows = []
    for key, label in WINDOW_LABELS.items():
        w = body.get(key)
        if not w:
            continue
        resets_at = datetime.fromisoformat(w["resets_at"]) if w.get("resets_at") else None
        windows.append(Window(key, label, float(w.get("utilization") or 0), resets_at))
    if not windows:
        raise ProviderError("回應中沒有用量資料，API 可能已變更")
    return ProviderUsage(plan=plan, windows=windows)


def fetch() -> ProviderUsage:
    oauth = read_credentials()
    body = get_json(USAGE_URL, {
        "Authorization": f"Bearer {oauth['accessToken']}",
        "anthropic-beta": "oauth-2025-04-20",
    })
    plan = oauth.get("subscriptionType")
    return parse(body, plan.title() if plan else None)
