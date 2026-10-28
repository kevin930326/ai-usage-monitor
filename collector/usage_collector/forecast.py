"""額度預測（ADR-0018 第 1、2 節）：照近期速度推算「約幾點幾分用完」，以及比過去 7 天同時段快幾倍。

- 規則同 UsageKit 的 QuotaForecast.swift、UsageCore 的 QuotaForecast.cs；`fixtures/forecast/` 三邊跑同一份 golden。
- iPhone 沒有歷史，所以收集器寫 usage.json 前算好，寫進每個額度的選填欄位 `forecast`；Mac 與 Windows App 自己算。
- 資料不足時不輸出（不退回平均速度）。
- 讀 history.sqlite3 只讀、最多等 1 秒；任何失敗都只是不輸出預測，不影響 usage.json 與上傳。
"""
from __future__ import annotations

import math
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .log import log
from .models import iso_utc, parse_iso

URGENT_WITHIN = 3600
FASTER_THRESHOLD = 1.5
BASELINE_DAYS = 7
BASELINE_MINIMUM_DAYS = 3
RECENT_MINIMUM_SAMPLES = 4
RESET_TOLERANCE = 10 * 60
READ_TIMEOUT = 1.0


@dataclass(frozen=True)
class Sample:
    ts: float  # Unix 秒
    used_pct: float
    resets_at: float | None


def recent_lookback(window_id: str) -> float | None:
    """近期速度要看多久：5 小時額度 60 分鐘、每週額度 24 小時；其他長度不用（ADR-0009 第 4 節）"""
    if window_id == "five_hour":
        return 3600.0
    if window_id == "weekly" or window_id.startswith("weekly_"):
        return 86400.0
    return None


def recent_minimum_span(window_id: str) -> float:
    return 30 * 60.0 if window_id == "five_hour" else 12 * 3600.0


def is_reset(a: Sample, b: Sample) -> bool:
    """相鄰兩筆之間是否重置：resets_at 改變超過 10 分鐘（或一筆有、一筆沒有），或已用 % 降到一半以下"""
    if (a.resets_at is None) != (b.resets_at is None):
        return True
    if a.resets_at is not None and b.resets_at is not None and abs(b.resets_at - a.resets_at) > RESET_TOLERANCE:
        return True
    return b.used_pct < a.used_pct and b.used_pct <= a.used_pct / 2


def current_cycle(samples: list[Sample]) -> list[Sample]:
    for i in range(len(samples) - 1, 0, -1):
        if is_reset(samples[i - 1], samples[i]):
            return samples[i:]
    return samples


def recent_rate(samples: list[Sample], window_id: str, now: float) -> float | None:
    """近期速度（每秒的百分點）：同一輪、回看範圍內至少 4 筆、跨度足夠；相鄰兩筆正差值的總和除以時間"""
    lookback = recent_lookback(window_id)
    if lookback is None:
        return None
    recent = [s for s in current_cycle(samples) if now - lookback <= s.ts <= now]
    if len(recent) < RECENT_MINIMUM_SAMPLES:
        return None
    span = recent[-1].ts - recent[0].ts
    if span < recent_minimum_span(window_id):
        return None
    used_sum = 0.0
    for a, b in zip(recent, recent[1:]):
        used_sum += max(b.used_pct - a.used_pct, 0)
    return used_sum / span


def usual_rate(samples: list[Sample], window_id: str, now: float) -> float | None:
    """平常的速度：過去 7 天每一天同一段回看範圍的速度（門檻同近期速度）；至少 3 天有資料時取中位數。
    跨過重置的那一段不算消耗。"""
    lookback = recent_lookback(window_id)
    if lookback is None:
        return None
    rates: list[float] = []
    for day in range(1, BASELINE_DAYS + 1):
        end = now - day * 86400
        span = [s for s in samples if end - lookback <= s.ts <= end]
        if len(span) < RECENT_MINIMUM_SAMPLES:
            continue
        seconds = span[-1].ts - span[0].ts
        if seconds < recent_minimum_span(window_id):
            continue
        used_sum = 0.0
        for a, b in zip(span, span[1:]):
            if not is_reset(a, b):
                used_sum += max(b.used_pct - a.used_pct, 0)
        rates.append(used_sum / seconds)
    if len(rates) < BASELINE_MINIMUM_DAYS:
        return None
    rates.sort()
    mid = len(rates) // 2
    return rates[mid] if len(rates) % 2 == 1 else (rates[mid - 1] + rates[mid]) / 2


def forecast(window_id: str, used_pct: float, resets_at: float | None, hidden: bool, stale: bool,
             samples: list[Sample], now: float) -> dict | None:
    """一個額度的預測：`{"exhausts_at": 秒, "urgent": bool, "faster": float | None}`；條件不符為 None。
    `samples` 依時間排序。"""
    if stale or hidden or resets_at is None or resets_at <= now or recent_lookback(window_id) is None:
        return None
    used = min(max(used_pct, 0.0), 100.0)
    if used >= 100:
        return None
    rate = recent_rate(samples, window_id, now)
    if rate is None or rate <= 0:
        return None
    at = now + (100 - used) / rate
    if at >= resets_at:
        return None
    faster = None
    usual = usual_rate(samples, window_id, now)
    if usual is not None and usual > 0:
        ratio = math.floor(rate / usual * 10) / 10
        if ratio >= FASTER_THRESHOLD:
            faster = ratio
    return {"exhausts_at": at, "urgent": at - now < URGENT_WITHIN, "faster": faster}


def _read_samples(path: Path, since: int) -> dict[tuple[str, str], list[Sample]]:
    """唯讀打開 history.sqlite3（不建立、不 migrate），讀 since 之後的樣本。"""
    if not path.exists():
        return {}
    uri = path.resolve().as_uri() + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=READ_TIMEOUT)
    try:
        rows = conn.execute(
            "SELECT provider, window_id, ts, used_pct, resets_at FROM quota_samples WHERE ts >= ? ORDER BY ts",
            (since,)).fetchall()
    finally:
        conn.close()
    result: dict[tuple[str, str], list[Sample]] = {}
    for provider, window_id, ts, used, resets in rows:
        result.setdefault((provider, window_id), []).append(Sample(float(ts), float(used), None if resets is None else float(resets)))
    return result


def annotate(snapshot: dict, path: Path, now: datetime | None = None) -> int:
    """在快照每個額度加上 `forecast`（有預測時才加）。這次收集的值也算進近期速度（歷史在之後才寫入）。
    回傳加了幾個。"""
    now_dt = now or parse_iso(snapshot["updated_at"])
    now_s = now_dt.timestamp()
    lookback = max(recent_lookback("five_hour") or 0, recent_lookback("weekly") or 0)
    stored = _read_samples(path, int(now_s - BASELINE_DAYS * 86400 - lookback - 60))
    count = 0
    for name, p in (snapshot.get("providers") or {}).items():
        if p.get("error") is not None:
            continue
        for w in p.get("windows") or []:
            resets = parse_iso(w["resets_at"]).timestamp() if w.get("resets_at") else None
            samples = [s for s in stored.get((name, w["id"]), []) if s.ts < now_s]
            samples.append(Sample(now_s, float(w["used_pct"]), resets))
            result = forecast(w["id"], float(w["used_pct"]), resets, bool(w.get("hidden")), False, samples, now_s)
            if result is None:
                continue
            out: dict[str, object] = {"exhausts_at": iso_utc(datetime.fromtimestamp(result["exhausts_at"], timezone.utc)),
                                      "urgent": result["urgent"]}
            if result["faster"] is not None:
                out["faster"] = result["faster"]
            w["forecast"] = out
            count += 1
    return count


def annotate_safely(snapshot: dict, path: Path) -> None:
    """失敗只記錯誤類別（sqlite 的訊息可能帶出路徑），快照照常寫出與上傳。"""
    try:
        annotate(snapshot, path)
    except Exception as e:  # noqa: BLE001 — 預測是附加資訊
        log(f"略過額度預測（{type(e).__name__}）")

