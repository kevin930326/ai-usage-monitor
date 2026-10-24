from __future__ import annotations

import json
from pathlib import Path

from .. import paths
from ..log import log
from . import claude, codex

# 輸出 JSON 的 key → provider 模組；新增服務只要在這裡註冊
PROVIDERS = {
    "claude": claude,
    "codex": codex,
}


def enabled_providers(config_path: Path | None = None) -> list[str]:
    """config.json 的 `enabled_providers` 列出要收集的服務（安裝腳本依登入狀態偵測後寫入）。
    沒有設定檔、沒有這個欄位或格式不對時全部啟用，維持舊版安裝的行為。
    未啟用的服務不查詢、不輸出、不寫日誌：沒有使用某個服務不是錯誤。"""
    path = config_path or paths.CONFIG_PATH
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return list(PROVIDERS)
    names = config.get("enabled_providers") if isinstance(config, dict) else None
    if names is None:
        return list(PROVIDERS)
    if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
        log(f"{path} 的 enabled_providers 應為字串陣列，改為全部啟用")
        return list(PROVIDERS)
    unknown = [n for n in names if n not in PROVIDERS]
    if unknown:
        log(f"enabled_providers 中有不認得的服務，已略過：{', '.join(unknown)}")
    # 依註冊順序，重複的名稱只算一次
    return [n for n in PROVIDERS if n in names]
