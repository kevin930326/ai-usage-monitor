from __future__ import annotations

import json
import os
import shutil
from pathlib import Path
from typing import Iterable, Mapping


def resolve_home(environ: Mapping[str, str] = os.environ) -> Path:
    """資料夾位置，規則與 UsageKit 的 UsageFileLocator 相同：
    `AI_USAGE_MONITOR_HOME` 有值才採用（空字串視為未設定，避免寫到目前目錄），
    否則為 ~/Library/Application Support/AIUsageMonitor。"""
    custom = environ.get("AI_USAGE_MONITOR_HOME")
    if custom:
        return Path(custom)
    return Path.home() / "Library" / "Application Support" / "AIUsageMonitor"


# Mac 選單列 App 也從這裡讀取（FR-20）；測試時可用環境變數改位置
APP_SUPPORT_DIR = resolve_home()
LOCAL_SNAPSHOT_PATH = APP_SUPPORT_DIR / "usage.json"
CONFIG_PATH = APP_SUPPORT_DIR / "config.json"


def resolve_executable(config_key: str, name: str, fallbacks: Iterable[str] = (),
                       config_path: Path | None = None) -> str | None:
    """安裝腳本把偵測到的完整路徑寫進 config.json 的 `config_key`（launchd 的 PATH 只有系統目錄）；
    沒有設定時退回 PATH，再退回 `fallbacks` 列出的常見安裝位置。找不到或不能執行時回傳 None。"""
    try:
        path = json.loads((config_path or CONFIG_PATH).read_text()).get(config_key)
    except (FileNotFoundError, json.JSONDecodeError, AttributeError):
        path = None
    if not isinstance(path, str):
        path = None  # config.json 被改成別的型別時當成沒設定，不讓 os.access 丟 TypeError
    for candidate in (path, shutil.which(name), *fallbacks):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return None
