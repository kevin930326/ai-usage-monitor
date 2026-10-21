from __future__ import annotations

import os
from pathlib import Path
from typing import Mapping


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
