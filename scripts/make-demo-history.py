#!/usr/bin/env python3
"""產生假的 usage.json 與 history.sqlite3，給 Mac 面板截圖與效能量測（不碰真實資料）。

    python3 scripts/make-demo-history.py <資料夾> [normal|few|fresh|none]

- normal：過去 7 天，每晚 01:00～08:30 Mac 睡眠（沒有紀錄）、3 天前下午關機 4 小時；
  Claude 5 小時快用完（剩 15%，用得較快）、Codex 還充足，會出現「建議接下來用」；每週額度 4 天前重置過
- few：剛安裝 15 分鐘，每個額度 3 筆
- fresh：剛安裝，每個額度只有 1 筆（走勢與額度消耗顯示骨架畫面）
- none：沒有 history.sqlite3（收集器還沒更新）
資料庫用收集器自己的 history 模組建立，schema 與實際相同。
"""
from __future__ import annotations

import json
import math
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "collector"))
from usage_collector import history  # noqa: E402

STEP = 300


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def awake(ts: float) -> bool:
    local = datetime.fromtimestamp(ts).astimezone()
    hour = local.hour + local.minute / 60
    if 1 <= hour < 8.5:
        return False  # 每晚睡眠
    days_ago = (datetime.now().astimezone().date() - local.date()).days
    return not (days_ago == 3 and 13 <= hour < 17)  # 3 天前下午關機


def activity(ts: float, phase: float) -> float:
    local = datetime.fromtimestamp(ts).astimezone()
    hour = local.hour + local.minute / 60
    return max(0.0, 0.6 + 0.5 * math.sin((hour + phase) / 24 * 2 * math.pi * 2)) + (0.4 if 20 <= hour < 23 else 0)


def series(now: float, start: float, resets: list[float], current: float, phase: float, previous_peak: float = 70) -> dict[float, float]:
    """每個 tick 的已用 %：每一輪從 0 累積，最後一輪在 now 時等於 current。"""
    ticks = [t for t in range(int(start), int(now) + 1, STEP)]
    bounds = sorted(r for r in resets if start < r <= now)
    out: dict[float, float] = {}
    cycles: list[list[float]] = []
    edges = [start, *bounds, now + 1]
    for a, b in zip(edges, edges[1:]):
        cycles.append([t for t in ticks if a <= t < b])
    for i, cycle in enumerate(cycles):
        cum, acc = [], 0.0
        for t in cycle:
            acc += activity(t, phase) if awake(t) else 0.0
            cum.append(acc)
        target = current if i == len(cycles) - 1 else previous_peak * (0.7 + 0.3 * ((i * 37) % 10) / 10)
        scale = target / cum[-1] if cum and cum[-1] > 0 else 0
        for t, c in zip(cycle, cum):
            out[t] = round(min(c * scale, 100.0), 1 if phase else 0)
    return out


def main() -> None:
    folder = Path(sys.argv[1])
    scenario = sys.argv[2] if len(sys.argv) > 2 else "normal"
    folder.mkdir(parents=True, exist_ok=True)
    now = (int(datetime.now(timezone.utc).timestamp()) // STEP) * STEP
    claude_5h_reset = now + 94 * 60
    codex_5h_reset = now + 199 * 60
    claude_week_reset = now + int(2.96 * 86400)
    codex_week_reset = now + int(5.4 * 86400)
    current = {("claude", "five_hour"): 85, ("claude", "weekly"): 62, ("codex", "five_hour"): 18, ("codex", "weekly"): 35}
    windows = {
        ("claude", "five_hour"): ("5 小時", claude_5h_reset, 5 * 3600),
        ("claude", "weekly"): ("每週", claude_week_reset, 7 * 86400),
        ("codex", "five_hour"): ("5 小時", codex_5h_reset, 5 * 3600),
        ("codex", "weekly"): ("每週", codex_week_reset, 7 * 86400),
    }
    snapshot = {"schema_version": 1, "updated_at": iso(now - 120), "providers": {
        "claude": {"plan": "Max", "error": None, "windows": []},
        "codex": {"plan": "Team", "error": None, "windows": []},
    }}
    for (provider, wid), (label, reset, _) in windows.items():
        snapshot["providers"][provider]["windows"].append(
            {"id": wid, "label": label, "used_pct": current[(provider, wid)], "resets_at": iso(reset), "hidden": False})
    (folder / "usage.json").write_text(json.dumps(snapshot, ensure_ascii=False, indent=2))

    db = folder / "history.sqlite3"
    for suffix in ("", "-wal", "-shm"):
        Path(f"{db}{suffix}").unlink(missing_ok=True)
    if scenario == "none":
        return
    conn = history.connect(db)
    if scenario in ("few", "fresh"):
        count = 3 if scenario == "few" else 1
        ticks = [now - STEP * i for i in reversed(range(count))]
        for i, t in enumerate(ticks):
            snap = json.loads(json.dumps(snapshot))
            snap["updated_at"] = iso(t)
            for p in snap["providers"].values():
                for w in p["windows"]:
                    w["used_pct"] = max(w["used_pct"] - (count - 1 - i), 0)
            history.write_samples(conn, snap)
        conn.close()
        return
    start = now - 7 * 86400
    rows, runs = [], []
    data = {}
    for (provider, wid), (label, reset, duration) in windows.items():
        resets = [reset - k * duration for k in range(1, 400) if reset - k * duration > start]
        phase = 0.0 if provider == "claude" else 3.0
        data[(provider, wid)] = (series(now, start, resets, current[(provider, wid)], phase), reset, duration)
    for t in range(start, now + 1, STEP):
        if not awake(t):
            continue
        runs.append((t, 1, 1))
        for (provider, wid), (values, reset, duration) in data.items():
            # 這一筆所在那一輪的重置時間
            k = math.ceil((reset - t) / duration) - 1 if t < reset else 0
            rows.append((t, provider, wid, values[t], reset - max(k, 0) * duration))
    conn.executemany("INSERT OR REPLACE INTO collector_runs VALUES (?, ?, ?)", runs)
    conn.executemany("INSERT OR REPLACE INTO quota_samples VALUES (?, ?, ?, ?, ?)", rows)
    conn.close()


if __name__ == "__main__":
    main()
