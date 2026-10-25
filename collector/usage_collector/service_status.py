"""服務狀態（FR-45、ADR-0008 第 2 節第 8 項）：讀 Anthropic 與 OpenAI 的公開狀態頁，寫入本機 `service-status.json`。

- 只讀公開的 Statuspage `summary.json`，不帶任何密鑰或 cookie、不跟隨到其他主機的重新導向。
- 結果只存在本機（0600），不放進快照、不上傳；Mac App 讀這個檔案，App 本身不連網。
- 收集器每 5 分鐘執行一次；按「更新」可能更頻繁，兩次抓取至少間隔 `MIN_INTERVAL` 秒。
- 只保留畫面需要的欄位（整體狀態、異常的元件名稱、進行中的事件名稱），長度與數量都有上限；失敗只記錯誤類別。
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from . import http, local_store
from .log import log
from .models import ProviderError, iso_utc
from .paths import APP_SUPPORT_DIR

STATUS_PATH = APP_SUPPORT_DIR / "service-status.json"
SCHEMA_VERSION = 1
MIN_INTERVAL = 240
TIMEOUT = 8

# 各服務的公開狀態頁（Atlassian Statuspage 相容格式）
PAGES = {
    "claude": "https://status.claude.com",
    "codex": "https://status.openai.com",
}
# 與這個工具相關的元件（名稱包含其中一個字串時，異常會標示「可能影響」）
RELATED = {
    "claude": ("Claude Code", "Claude API"),
    "codex": ("Codex", "Responses"),
}
INDICATORS = ("none", "minor", "major", "critical", "maintenance")
COMPONENT_STATUSES = ("operational", "degraded_performance", "partial_outage", "major_outage", "under_maintenance")
MAX_ITEMS = 8
MAX_TEXT = 120


def _text(value: object) -> str | None:
    """只收短的單行文字（狀態頁的名稱與說明）"""
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:MAX_TEXT] if value else None


def _items(value: object) -> list:
    """格式不符（不是陣列）時當成沒有項目"""
    return value if isinstance(value, list) else []


def parse(provider: str, summary: dict) -> dict:
    """把 summary.json 縮成畫面需要的欄位。格式不符的項目略過，不丟例外。"""
    status = summary.get("status") if isinstance(summary, dict) else None
    if not isinstance(status, dict) or status.get("indicator") not in INDICATORS:
        raise ProviderError("狀態頁格式不符")
    indicator = status["indicator"]
    components: list[dict] = []
    for c in _items(summary.get("components")):
        if not isinstance(c, dict) or c.get("group") is True:
            continue
        name, state = _text(c.get("name")), c.get("status")
        if name and state in COMPONENT_STATUSES and state != "operational" and len(components) < MAX_ITEMS:
            components.append({"name": name, "status": state,
                               "related": any(key in name for key in RELATED[provider])})
    incidents: list[dict] = []
    for i in _items(summary.get("incidents")):
        if not isinstance(i, dict) or i.get("status") in ("resolved", "postmortem"):
            continue
        name = _text(i.get("name"))
        if name and len(incidents) < MAX_ITEMS:
            impact = i.get("impact") if i.get("impact") in ("none", "minor", "major", "critical", "maintenance") else "none"
            incidents.append({"name": name, "impact": impact})
    return {
        "indicator": indicator,
        "description": _text(status.get("description")),
        "components": components,
        "incidents": incidents,
        "page": PAGES[provider],
        "error": None,
    }


def fetch(provider: str) -> dict:
    """抓一個服務的狀態頁。任何失敗（網路、讀取逾時、格式）只影響這個服務，錯誤只記固定訊息或類別。"""
    try:
        return parse(provider, http.request_json(f"{PAGES[provider]}/api/v2/summary.json", {}, timeout=TIMEOUT))
    except ProviderError as e:
        error = str(e)[:MAX_TEXT]  # 收集器自己的訊息，不含回應內容
    except Exception as e:  # noqa: BLE001 — 例如讀取回應時 TimeoutError；不記例外內容
        error = f"狀態頁讀取失敗（{type(e).__name__}）"
    return {"indicator": None, "description": None, "components": [], "incidents": [], "page": PAGES[provider],
            "error": error}


def _read(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def _write(data: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    local_store.remove_stale_temp(path.parent, ".service-status-")
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".service-status-", suffix=".json")
    try:
        if sys.platform != "win32":  # Windows 的 Python 3.12 沒有 fchmod；%LOCALAPPDATA% 本來就只有使用者本人能讀
            os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def update(providers: list[str], path: Path = STATUS_PATH, now: datetime | None = None) -> bool:
    """抓取並寫入；距離上次寫入不到 MIN_INTERVAL 秒、且服務清單相同時略過。回傳是否有抓取。"""
    now = now or datetime.now(timezone.utc)
    providers = [p for p in providers if p in PAGES]
    previous = _read(path)
    if previous and sorted((previous.get("providers") or {}).keys()) == sorted(providers):
        try:
            last = datetime.fromisoformat(str(previous.get("updated_at")).replace("Z", "+00:00"))
            if 0 <= (now - last).total_seconds() < MIN_INTERVAL:
                return False
        except ValueError:
            pass
    data = {"schema_version": SCHEMA_VERSION, "updated_at": iso_utc(now),
            "providers": {p: fetch(p) for p in providers}}
    _write(data, path)
    return True


def update_safely(providers: list[str], path: Path = STATUS_PATH) -> None:
    """失敗只記錯誤類別，不影響 usage.json、上傳與結束碼。"""
    try:
        update(providers, path)
    except Exception as e:  # noqa: BLE001 — 服務狀態是附加資訊
        log(f"略過服務狀態（{type(e).__name__}）")
