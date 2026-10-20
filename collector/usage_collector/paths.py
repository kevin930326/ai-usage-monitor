from __future__ import annotations

import os
from pathlib import Path

# Mac 選單列 App 也從這裡讀取（FR-20）；測試時可用環境變數改位置
APP_SUPPORT_DIR = Path(os.environ.get(
    "AI_USAGE_MONITOR_HOME",
    Path.home() / "Library" / "Application Support" / "AIUsageMonitor",
))
LOCAL_SNAPSHOT_PATH = APP_SUPPORT_DIR / "usage.json"
CONFIG_PATH = APP_SUPPORT_DIR / "config.json"
