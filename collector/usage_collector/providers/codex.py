"""Codex provider。

token 來源：Codex CLI 登入後的 ~/.codex/auth.json。
用量來源：Codex 使用的 ChatGPT 非公開端點。
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from ..http import get_json
from ..models import ProviderError, ProviderUsage, Window, parse_pct

AUTH_PATH = Path.home() / ".codex" / "auth.json"
USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"

PLAN_NAMES = {"pro": "Pro", "plus": "Plus", "team": "Team", "business": "Business", "free": "Free"}


def read_tokens(path: Path = AUTH_PATH) -> dict:
    try:
        tokens = json.loads(path.read_text())["tokens"]
        return {"access_token": tokens["access_token"], "account_id": tokens["account_id"]}
    except FileNotFoundError:
        raise ProviderError("尚未登入 Codex CLI") from None
    except (json.JSONDecodeError, KeyError, TypeError):
        raise ProviderError("無法讀取 Codex 登入資訊") from None


def window_label(seconds: int) -> tuple[str, str]:
    if seconds == 7 * 24 * 3600:
        return "weekly", "每週"
    if seconds == 5 * 3600:
        return "five_hour", "5 小時"
    hours = round(seconds / 3600)
    return f"{hours}h", f"{hours} 小時"


def parse(body: dict) -> ProviderUsage:
    rate_limit = body.get("rate_limit") or {}
    windows = []
    for key in ("primary_window", "secondary_window"):
        w = rate_limit.get(key)
        if not w:
            continue
        wid, label = window_label(int(w["limit_window_seconds"]))
        resets_at = datetime.fromtimestamp(w["reset_at"], tz=timezone.utc) if w.get("reset_at") else None
        windows.append(Window(wid, label, parse_pct(w.get("used_percent")), resets_at))
    if not windows:
        raise ProviderError("回應中沒有用量資料，API 可能已變更")
    plan = body.get("plan_type")
    return ProviderUsage(plan=PLAN_NAMES.get(plan, plan), windows=windows)


def fetch() -> ProviderUsage:
    tokens = read_tokens()
    body = get_json(USAGE_URL, {
        "Authorization": f"Bearer {tokens['access_token']}",
        "ChatGPT-Account-Id": tokens["account_id"],
    })
    return parse(body)
