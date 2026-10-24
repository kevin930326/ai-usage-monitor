#!/usr/bin/env python3
"""量測額度歷史讓每次收集增加的時間（ADR-0009 第 7 節：一般情況 < 1 秒）。

    python3 scripts/measure-history.py

在暫存資料夾建立三種資料庫（剛安裝、35 天、一年），各量測一般執行與「每天第一次」（含清理）
的時間，取 20 次的中位數與最大值。不碰真實的 history.sqlite3。
"""
from __future__ import annotations

import statistics
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from usage_collector import history  # noqa: E402

DAY, HOUR = 86400, 3600
WINDOWS = [(p, w) for p in ("claude", "codex") for w in ("five_hour", "weekly")]


def snapshot(ts: int) -> dict:
    def iso(t: int) -> str:
        return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"updated_at": iso(ts), "providers": {
        p: {"error": None, "windows": [
            {"id": w, "used_pct": 12.0, "resets_at": iso(ts + HOUR)} for q, w in WINDOWS if q == p]}
        for p in ("claude", "codex")}}


def build(path: Path, now: int, days: int, steady: bool = True) -> None:
    conn = history.connect(path)
    runs, rows = [], []
    start = now - days * DAY
    for ts in range(start, now - 35 * DAY, HOUR):
        runs.append((ts, 12, 12))
        rows += [(ts, p, w, 10.0, ts + HOUR) for p, w in WINDOWS]
    for ts in range(max(start, now - 35 * DAY), now, 300):
        runs.append((ts, 1, 1))
        rows += [(ts, p, w, 10.0, ts + HOUR) for p, w in WINDOWS]
    conn.executemany("INSERT INTO collector_runs VALUES (?, ?, ?)", runs)
    conn.executemany("INSERT INTO quota_samples VALUES (?, ?, ?, ?, ?)", rows)
    conn.execute("INSERT OR REPLACE INTO meta VALUES ('last_cleanup_day', ?)",
                 (datetime.fromtimestamp(now).astimezone().date().isoformat(),))
    # 平常的狀態：前一天已經降採樣過（升級後第一次清理會看全部，只發生一次，另外量）
    if steady:
        conn.execute("INSERT OR REPLACE INTO meta VALUES ('downsampled_before', ?)",
                     (str((now - 35 * DAY) // HOUR * HOUR),))
    conn.close()


def measure(days: int, daily_cleanup: bool, repeat: int = 20, steady: bool = True) -> tuple[float, float, int]:
    times = []
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "history.sqlite3"
        now = int(time.time())
        build(path, now, days, steady)
        for i in range(repeat):
            ts = now + (i + 1) * 300
            when = datetime.fromtimestamp(ts + (i + 1) * DAY if daily_cleanup else ts, timezone.utc)
            start = time.perf_counter()
            history.record(snapshot(ts), path, now=when)
            times.append(time.perf_counter() - start)
        size = sum(p.stat().st_size for p in Path(d).iterdir())
    return statistics.median(times), max(times), size


def main() -> None:
    print("| 資料庫 | 情況 | 中位數 | 最大 | 檔案大小 |")
    print("|---|---|---|---|---|")
    for label, days in (("剛安裝（0 天）", 0), ("35 天", 35), ("一年", 365)):
        for case, cleanup in (("一般執行", False), ("每天第一次（含清理）", True)):
            med, mx, size = measure(days, cleanup)
            print(f"| {label} | {case} | {med * 1000:.1f} ms | {mx * 1000:.1f} ms | {size / 1e6:.1f} MB |")
    med, mx, size = measure(365, True, repeat=1, steady=False)
    print(f"| 一年（沒有降採樣進度） | 第一次清理（只發生一次） | {med * 1000:.1f} ms | {mx * 1000:.1f} ms"
          f" | {size / 1e6:.1f} MB |")


if __name__ == "__main__":
    main()
