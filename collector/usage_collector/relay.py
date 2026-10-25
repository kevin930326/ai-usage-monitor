"""上傳快照到中繼 API（FR-5）。

- 中繼網址放在 config.json：{"relay_url": "https://...workers.dev"}
- 寫入密鑰放在 macOS Keychain，不寫進任何檔案
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .http import post_json
from .models import ProviderError
from .paths import CONFIG_PATH

KEYCHAIN_SERVICE = "AIUsageMonitor-relay-write"
KEYCHAIN_ACCOUNT = "default"


class RelayNotConfigured(Exception):
    pass


def load_relay_url(path: Path = CONFIG_PATH) -> str:
    try:
        url = json.loads(path.read_text(encoding="utf-8"))["relay_url"]
    except (FileNotFoundError, KeyError, json.JSONDecodeError):
        raise RelayNotConfigured(f"未設定中繼 API（{path}）") from None
    return url.rstrip("/")


KEYCHAIN_TIMEOUT = 10


def read_write_token() -> str:
    # Keychain 沒有回應（鎖住、等待授權對話框）時不能讓整輪卡住：launchd 在這一輪結束前不會啟動下一輪（ADR-0014 LT-09）
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
            capture_output=True, text=True, timeout=KEYCHAIN_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        raise ProviderError("讀取 Keychain 的中繼寫入密鑰逾時（Keychain 可能已鎖定），這次不上傳") from None
    except OSError:
        raise RelayNotConfigured("找不到 security 指令，無法讀取中繼寫入密鑰") from None
    if result.returncode != 0 or not result.stdout.strip():
        raise RelayNotConfigured("Keychain 中找不到中繼寫入密鑰")
    return result.stdout.strip()


def upload(snapshot: dict) -> None:
    url = load_relay_url()
    token = read_write_token()
    try:
        post_json(f"{url}/usage", {"Authorization": f"Bearer {token}"}, snapshot)
    except ProviderError as e:
        raise ProviderError(f"上傳中繼失敗：{e}") from None
