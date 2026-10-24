from __future__ import annotations

import json
import os
import shutil
import sys
from collections.abc import Container, Iterable, Mapping
from pathlib import Path

from . import system

TESTING_ENV = "AUM_TESTING"


class TestHomeNotSet(RuntimeError):
    """測試環境沒有指定 `AI_USAGE_MONITOR_HOME`：不得退回真的資料夾。"""


def is_testing(environ: Mapping[str, str] = os.environ, modules: Container[str] = sys.modules) -> bool:
    """`AUM_TESTING` 有值，或已載入 unittest／pytest（收集器本身不會載入它們）。"""
    return bool(environ.get(TESTING_ENV)) or "unittest" in modules or "pytest" in modules


def resolve_home(environ: Mapping[str, str] = os.environ, modules: Container[str] = sys.modules) -> Path:
    """資料夾位置，規則與 UsageKit 的 UsageFileLocator 相同：
    `AI_USAGE_MONITOR_HOME` 有值才採用（空字串視為未設定，避免寫到目前目錄），
    否則為 ~/Library/Application Support/AIUsageMonitor（Windows：%LOCALAPPDATA%\\AIUsageMonitor）。
    測試環境（`is_testing`）沒有指定時丟出 `TestHomeNotSet`，不使用預設資料夾。"""
    custom = environ.get("AI_USAGE_MONITOR_HOME")
    if custom:
        return Path(custom)
    if is_testing(environ, modules):
        raise TestHomeNotSet(
            "測試環境沒有設定 AI_USAGE_MONITOR_HOME，不使用真的資料夾。"
            "請在 collector 資料夾執行 `python3 -m unittest`（tests/__init__.py 會指到暫存位置）")
    return system.default_home(environ)


# Mac 選單列 App 也從這裡讀取（FR-20）；測試時可用環境變數改位置
APP_SUPPORT_DIR = resolve_home()
LOCAL_SNAPSHOT_PATH = APP_SUPPORT_DIR / "usage.json"
CONFIG_PATH = APP_SUPPORT_DIR / "config.json"


def resolve_executable(config_key: str, name: str, fallbacks: Iterable[str] | None = None,
                       config_path: Path | None = None) -> str | None:
    """安裝腳本把偵測到的完整路徑寫進 config.json 的 `config_key`（launchd 的 PATH 只有系統目錄）；
    沒有設定時退回 PATH，再退回 `fallbacks`（沒給時用這個平台的常見安裝位置，system.executable_fallbacks）。
    找不到或不能執行時回傳 None。"""
    try:
        path = json.loads((config_path or CONFIG_PATH).read_text(encoding="utf-8")).get(config_key)
    except (FileNotFoundError, json.JSONDecodeError, AttributeError):
        path = None
    if not isinstance(path, str):
        path = None  # config.json 被改成別的型別時當成沒設定，不讓 is_launchable 丟 TypeError
    if fallbacks is None:
        fallbacks = system.executable_fallbacks(name)
    for candidate in (path, shutil.which(name), *fallbacks):
        if candidate and system.is_launchable(candidate):
            # 絕對路徑：provider 在暫存資料夾執行，相對路徑會指到別的地方
            return os.path.abspath(candidate)
    return None
