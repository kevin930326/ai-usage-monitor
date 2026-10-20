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
        url = json.loads(path.read_text())["relay_url"]
    except (FileNotFoundError, KeyError, json.JSONDecodeError):
        raise RelayNotConfigured(f"未設定中繼 API（{path}）") from None
    return url.rstrip("/")


def read_write_token() -> str:
    result = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
        capture_output=True, text=True,
    )
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
