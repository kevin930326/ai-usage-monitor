"""服務狀態（FR-45、ADR-0008 第 2 節第 8 項）：讀 Anthropic 與 OpenAI 的公開狀態頁，寫入本機 `service-status.json`。

- 只讀公開的狀態頁 `summary.json` 與事故清單（ADR-0018 第 4 節），不帶任何密鑰或 cookie、不跟隨到其他主機的重新導向。
- 結果寫在本機（0600）；Mac App 讀這個檔案，App 本身不連網。進行中事故的精簡版（名稱、等級、連結、開始時間）
  另外由 `annotate` 放進 usage.json 的 `providers.*.incidents`，Windows 與 iPhone 也看得到（狀態頁是公開資訊）。
- 收集器每 5 分鐘執行一次；按「更新」可能更頻繁，兩次抓取至少間隔 `MIN_INTERVAL` 秒。
- 只保留畫面需要的欄位（整體狀態、異常的元件名稱、進行中的事件名稱），長度與數量都有上限；失敗只記錯誤類別。
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

from . import http, local_store
from .log import log
from .models import ProviderError, iso_utc, parse_iso
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
# 事故清單：Claude（Statuspage）有 unresolved.json；OpenAI（incident.io）沒有，summary.json 也沒有事故，
# 只能讀最近的事故（含已解決）自己篩
INCIDENTS = {
    "claude": "/api/v2/incidents/unresolved.json",
    "codex": "/api/v2/incidents.json",
}
# Claude 的事故只算影響這些元件的（名稱包含其中一個字串；沒列元件的也算）
INCIDENT_COMPONENTS = {
    "claude": ("Claude Code", "Claude API", "claude.ai"),
}
# OpenAI 的事故沒有元件資訊（2026-10-29 實查），只算名稱提到 Codex、API 或 Responses 的；
# 其他（廣告、客服、ChatGPT 的連線器等）不讓 Codex 角色生病
INCIDENT_NAME = {
    "codex": re.compile(r"\b(codex|apis?|responses)\b", re.IGNORECASE),
}
# 放進 usage.json 的事故數量上限、新鮮度（上一次查詢超過這麼久就不放）
SNAPSHOT_INCIDENTS = 3
SNAPSHOT_MAX_AGE = 15 * 60
# 與這個工具相關的元件（名稱包含其中一個字串時，異常會標示「可能影響」）
RELATED = {
    "claude": ("Claude Code", "Claude API"),
    "codex": ("Codex", "Responses"),
}
INDICATORS = ("none", "minor", "major", "critical", "maintenance")
COMPONENT_STATUSES = ("operational", "degraded_performance", "partial_outage", "major_outage", "under_maintenance")
MAX_ITEMS = 8
# 狀態頁的回應上限（平常幾十 KB）
MAX_RESPONSE = 1_000_000
MAX_TEXT = 120


def _text(value: object) -> str | None:
    """只收短的單行文字（狀態頁的名稱與說明）；去掉控制字元與格式字元（NUL、RLO 之類的方向控制、零寬字元）"""
    if not isinstance(value, str):
        return None
    value = "".join(" " if c.isspace() else c for c in value if unicodedata.category(c) not in ("Cc", "Cf") or c.isspace())
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


def _incident_id(value: object) -> str | None:
    """事故 ID 只收英數字、底線與連字號（組成事故頁網址用）"""
    if isinstance(value, str) and 0 < len(value) <= 64 and all(c.isascii() and (c.isalnum() or c in "_-") for c in value):
        return value
    return None


def _aware(value: object) -> datetime | None:
    """有時區的 ISO 8601 時間；沒有時區或格式不符為 None"""
    try:
        dt = parse_iso(value) if isinstance(value, str) else None
    except ValueError:
        return None
    return dt if dt is not None and dt.tzinfo is not None else None


def _aware_iso(value: object) -> str | None:
    dt = _aware(value)
    return iso_utc(dt) if dt else None


def parse_incidents(provider: str, data: dict) -> list[dict]:
    """事故清單縮成 `[{name, impact, url, started_at}]`：只留進行中的、相關的；格式不符的項目略過。"""
    if not isinstance(data, dict) or not isinstance(data.get("incidents"), list):
        raise ProviderError("事故清單格式不符")
    related = INCIDENT_COMPONENTS.get(provider)
    result: list[dict] = []
    for i in data["incidents"]:
        if not isinstance(i, dict) or i.get("status") in ("resolved", "postmortem") or i.get("resolved_at"):
            continue
        components = [c["name"] for c in _items(i.get("components"))
                      if isinstance(c, dict) and isinstance(c.get("name"), str)]
        if related and components and not any(key in name for name in components for key in related):
            continue
        name = _text(i.get("name"))
        if not name or len(result) >= MAX_ITEMS:
            continue
        pattern = INCIDENT_NAME.get(provider)
        if pattern and not pattern.search(name):
            continue
        impact = i.get("impact") if i.get("impact") in INDICATORS else "none"
        incident_id = _incident_id(i.get("id"))
        started_at = _aware_iso(i.get("started_at")) or _aware_iso(i.get("created_at"))
        result.append({"name": name, "impact": impact,
                       "url": f"{PAGES[provider]}/incidents/{incident_id}" if incident_id else None,
                       "started_at": started_at})
    return result


def fetch(provider: str) -> dict:
    """抓一個服務的狀態頁與事故清單。任何失敗（網路、讀取逾時、格式）只影響這個服務，錯誤只記固定訊息或類別。
    事故清單失敗時保留 summary.json 的結果，`incidents_checked` 為 False（不放進 usage.json）。"""
    try:
        summary = http.request_json(f"{PAGES[provider]}/api/v2/summary.json", {}, timeout=TIMEOUT, max_bytes=MAX_RESPONSE)
        result = parse(provider, summary)
        try:
            incidents = http.request_json(f"{PAGES[provider]}{INCIDENTS[provider]}", {}, timeout=TIMEOUT, max_bytes=MAX_RESPONSE)
            result["incidents"] = parse_incidents(provider, incidents)
            result["incidents_checked"] = True
        except Exception:  # noqa: BLE001 — 事故清單是附加資訊；不記例外內容
            result["incidents_checked"] = False
        return result
    except ProviderError as e:
        error = str(e)[:MAX_TEXT]  # 收集器自己的訊息，不含回應內容
    except Exception as e:  # noqa: BLE001 — 例如讀取回應時 TimeoutError；不記例外內容
        error = f"狀態頁讀取失敗（{type(e).__name__}）"
    return {"indicator": None, "description": None, "components": [], "incidents": [], "page": PAGES[provider],
            "error": error, "incidents_checked": False}


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


def annotate(snapshot: dict, path: Path = STATUS_PATH, now: datetime | None = None) -> None:
    """把上一次查到的進行中事故放進快照每個服務的 `incidents`（最多 3 筆）。查詢失敗、太舊或讀不到時不加這個欄位
    （不是空陣列），App 照舊。狀態頁在收集的最後才查（不拖慢 usage.json），所以事故最多晚一次收集出現。"""
    now = now or datetime.now(timezone.utc)
    data = _read(path)
    if not data:
        return
    updated = _aware(data.get("updated_at"))
    if updated is None or not 0 <= (now - updated).total_seconds() <= SNAPSHOT_MAX_AGE:
        return
    for name, p in (snapshot.get("providers") or {}).items():
        status = (data.get("providers") or {}).get(name)
        if not isinstance(status, dict) or status.get("error") is not None or status.get("incidents_checked") is not True:
            continue
        incidents = []
        for i in _items(status.get("incidents"))[:SNAPSHOT_INCIDENTS]:
            if isinstance(i, dict) and _text(i.get("name")):
                entry = {"name": _text(i["name"]), "impact": i.get("impact") if i.get("impact") in INDICATORS else "none"}
                if isinstance(i.get("url"), str) and i["url"].startswith(PAGES[name] + "/incidents/"):
                    entry["url"] = i["url"]
                if _aware_iso(i.get("started_at")):
                    entry["started_at"] = _aware_iso(i.get("started_at"))
                incidents.append(entry)
        p["incidents"] = incidents


def annotate_safely(snapshot: dict, path: Path = STATUS_PATH) -> None:
    try:
        annotate(snapshot, path)
    except Exception as e:  # noqa: BLE001 — 事故是附加資訊
        log(f"略過服務事故（{type(e).__name__}）")
