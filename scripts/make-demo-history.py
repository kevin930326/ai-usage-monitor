#!/usr/bin/env python3
"""產生假的 usage.json 與 history.sqlite3，給 Mac 面板截圖與效能量測（不碰真實資料）。

    python3 scripts/make-demo-history.py <資料夾> [normal|few|fresh|none]

- normal：過去 7 天，每晚 01:00～08:30 Mac 睡眠（沒有紀錄）、3 天前下午關機 4 小時；
  Claude 5 小時快用完（剩 15%，用得較快）、Codex 還充足，會出現「建議接下來用」；每週額度 4 天前重置過；
  Token 統計有一年的每日資料（Codex 約 200 天）、90 天的每小時資料，目前連續 9 天（新紀錄）；
  服務狀態：Claude 有一個示範用的事件（影響 Claude Code）、Codex 正常
- few：剛安裝 15 分鐘，每個額度 3 筆；Token 統計只有最近 3 天
- fresh：剛安裝，每個額度只有 1 筆（走勢與額度消耗顯示骨架畫面）；Token 統計首次掃描 37%
- none：沒有 history.sqlite3（收集器還沒更新）
- normal 以外的服務狀態都正常；服務狀態的名稱都是編的，標「示範」
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


def write_tokens(conn, now: int, scenario: str) -> None:
    """假的 Token 統計（第三階段面板與完整統計視窗）：一年的每日資料、90 天的每小時資料、個人紀錄。
    normal：兩個服務都有、目前連續 9 天（是新紀錄）；few：剛完成首次掃描、只有最近 3 天；fresh：首次掃描 37%。"""
    if scenario == "fresh":
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('first_scan_progress', '37')")
        conn.commit()
        return
    device = history.meta(conn, "device_id") or ""
    today = datetime.fromtimestamp(now).astimezone().date()
    days = 3 if scenario == "few" else 365
    daily, hourly, record_days = [], [], {}
    models = {"claude": ["claude-opus-5-5", "claude-sonnet-5-5"], "codex": ["gpt-6.1-sol", "gpt-6.1-sol-mini"]}
    for back in range(days):
        day = today - timedelta(days=back)
        key = day.isoformat()
        # 目前連續 9 天；更早每週休息一到兩天、每 5 週休一週
        if scenario == "normal" and back >= 9 and (back == 9 or day.weekday() == 6 or (back // 7) % 5 == 4 or (back * 7) % 11 == 0):
            continue
        season = 0.6 + 0.4 * math.sin(back / 365 * 2 * math.pi) + (0.3 if back < 60 else 0)
        for provider, phase in (("claude", 0.0), ("codex", 2.0)):
            if provider == "codex" and back > 200:
                continue  # Codex 大約半年前才開始用
            base = 2_400_000 if provider == "claude" else 900_000
            amount = int(base * season * (0.5 + 0.5 * abs(math.sin(back * 1.7 + phase))))
            for m, model in enumerate(models[provider]):
                share = 0.75 if m == 0 else 0.25
                inp, cw, out = int(amount * share * 0.35), int(amount * share * 0.45), int(amount * share * 0.2)
                cr = int(amount * share * 6)
                longest = int(600 + 5400 * abs(math.sin(back * 0.9 + m))) if m == 0 else 0
                daily.append((device, key, provider, model, inp, cw, cr, out, out // 5, 6 if m == 0 else 0,
                              longest * 3, longest, now))
                record_days.setdefault((key, provider), 0)
                record_days[(key, provider)] += inp + cw + out
                if back < 90:
                    for hour in range(9, 24):
                        weight = 1 + math.sin((hour - 9) / 14 * math.pi) + (0.6 if hour >= 20 else 0)
                        f = weight / 26
                        hourly.append((device, key, hour, provider, model, int(inp * f), int(cw * f), int(cr * f),
                                       int(out * f), int(out * f) // 5, 0, 0, 0, now))
    conn.executemany(f"INSERT OR REPLACE INTO daily_tokens VALUES ({', '.join('?' * 13)})", daily)
    conn.executemany(f"INSERT OR REPLACE INTO hourly_tokens VALUES ({', '.join('?' * 14)})", hourly)
    conn.executemany("INSERT OR REPLACE INTO record_days VALUES (?, ?, ?)", [(d, p, v) for (d, p), v in record_days.items()])
    records = []
    for suffix, provs in (("", ("claude", "codex")), (":claude", ("claude",)), (":codex", ("codex",))):
        per_day = {}
        for (d, p), v in record_days.items():
            if p in provs:
                per_day[d] = per_day.get(d, 0) + v
        if not per_day:
            continue
        best = max(per_day.items(), key=lambda kv: (kv[1], [-ord(c) for c in kv[0]]))
        longest = max(((r[11], r[1]) for r in daily if r[2] in provs), default=(0, None))
        records += [(f"best_day_tokens{suffix}", best[1], best[0]), (f"total_tokens{suffix}", sum(per_day.values()) + 1_234_567, None),
                    (f"longest_task_seconds{suffix}", longest[0], longest[1]),
                    (f"longest_streak_days{suffix}", 9 if scenario == "normal" else 3, today.isoformat())]
    conn.executemany("INSERT OR REPLACE INTO records VALUES (?, ?, ?)", records)
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('first_scan_done', '1')")
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('first_scan_progress', '100')")
    conn.commit()


def write_service_status(folder: Path, now: int, scenario: str) -> None:
    """與收集器 service_status.py 相同格式的 service-status.json（FR-45）"""
    def page(url: str) -> dict:
        return {"indicator": "none", "description": "All Systems Operational", "components": [], "incidents": [],
                "page": url, "error": None}
    providers = {"claude": page("https://status.claude.com"), "codex": page("https://status.openai.com")}
    if scenario == "normal":
        providers["claude"].update(
            indicator="minor", description="Minor Service Outage",
            components=[{"name": "Claude Code", "status": "degraded_performance", "related": True}],
            incidents=[{"name": "示範：Claude Code 回應變慢", "impact": "minor"}])
    data = {"schema_version": 1, "updated_at": iso(now - 60), "providers": providers}
    (folder / "service-status.json").write_text(json.dumps(data, ensure_ascii=False, indent=2))


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
    write_service_status(folder, now, scenario)

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
        write_tokens(conn, now, scenario)
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
    write_tokens(conn, now, scenario)
    conn.close()


if __name__ == "__main__":
    main()
