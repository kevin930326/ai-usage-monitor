#!/usr/bin/env python3
"""measure-notch-perf.sh 的報表：依 perf-mark 把 ps 的取樣分段，印出 Markdown 表格與門檻（ADR-0016 第 6 節）。
任何一項未通過（含缺少標記或取樣）時以 1 結束。

用法：scripts/notch-perf-summary.py <samples.tsv> <app.log>
"""
import re, sys
samples = [tuple(map(float, l.split())) for l in open(sys.argv[1]) if l.strip()]
log = open(sys.argv[2]).read()
marks = {m.group(2): float(m.group(1)) for m in re.finditer(r"perf-mark ([\d.]+) (\S+)", log)}
# App 每分鐘一次的時鐘更新（UsageStore.tick）：成本算在「收合後 60～90 秒」；看滑鼠的兩項要量的是不重畫，扣掉更新後 2 秒內的取樣
ticks = [float(t) for t in re.findall(r"perf-mark ([\d.]+) minute-tick", log)]
# 看滑鼠時角色圖層每一秒實際畫了幾格（螢幕關閉或鎖定時 display link 每秒只叫一次，CPU 會量成假的 0）
frames = [(float(m.group(1)), int(m.group(2)), m.group(3)) for m in re.finditer(r"perf-fps ([\d.]+) (\d+) (\w+)", log)]
# 其中真的重畫的格數（畫出來和上一格看不出差別的不重畫；舊的紀錄沒有這一欄）
drawn = [(float(m.group(1)), int(m.group(3)), m.group(2)) for m in re.finditer(r"perf-fps ([\d.]+) \d+ (\w+) (\d+)", log)]
def window(a, b): return [s for s in samples if a <= s[0] < b]
def without_ticks(rows): return [s for s in rows if not any(t <= s[0] < t + 2 for t in ticks)]
def avg(rows, i): return sum(r[i] for r in rows) / len(rows) if rows else float("nan")
def peak(rows, i): return max((r[i] for r in rows), default=float("nan"))
NEW_ANIMATIONS = ["nod", "tilt", "giggle", "look", "pinch", "face"]
try:
    o, z, w, c, c2 = marks["notch-open"], marks["notch-sleep"], marks["notch-wave"], marks["notch-close"], marks["notch-close-2"]
    ga, g, gs = marks["gaze-move-asleep"], marks["gaze-move"], marks["gaze-still"]
    ch, wp = marks["agent-cheer"], marks["waiting-pulse"]
    ra, lo, rao, loo = marks["agent-raise"], marks["agent-lower"], marks["agent-raise-open"], marks["agent-lower-open"]
    extra = {name: marks[f"notch-{name}"] for name in NEW_ANIMATIONS}
    th = marks["collapsed-think"]
    go, gso = marks["gaze-move-open"], marks["gaze-still-open"]
except KeyError as missing:
    print(f"缺少標記 {missing}")
    sys.exit(1)
rows = [
    ("展開前（收合、靜止）", window(o - 6, o), "avg"),
    ("播放中：展開＋過場（0～5 秒）", window(o, o + 5), "peak"),
    # 過場約 4.7 秒；睡覺由 AI 閒置決定（時間表直接設定），醒著與睡著分開看
    ("展開待著、醒著（展開後 5～10 秒）", window(o + 5, o + 10), "avg"),
    ("展開待著、睡著（睡著後 2～10 秒，呼吸）", window(z + 2, z + 10), "avg"),
    ("播放中：揮手（0～2 秒）", window(w, w + 2), "peak"),
    # 第二輪新增的動畫：只記錄峰值（ADR-0010 第 3 節「每個動畫都要做」）
    *[(f"播放中：{name}（0～2.5 秒）", window(t, t + 2.5), "peak") for name, t in extra.items()],
    ("收合、睡著、游標移動（不重畫，扣掉每分鐘更新）", without_ticks(window(ga + 2, ga + 10)), "avg"),
    ("收合、醒著、游標一直移動（看滑鼠）", window(g + 2, g + 15), "avg"),
    ("收合、游標停住（停止重畫，扣掉每分鐘更新）", without_ticks(window(gs + 3, gs + 20)), "avg"),
    ("收合後 60～90 秒", window(c + 60, c + 90), "avg"),
    ("第二次收合後 5～18 秒", window(c2 + 5, c2 + 18), "avg"),
    # AI 狀態（mascot2 第 2 部分）：收著時完成的鼓一下與揮手只記峰值；等你下指令的脈動和收合靜止同一個門檻
    ("播放中：收著時完成（0～2 秒）", window(ch, ch + 2), "peak"),
    ("收合、等你下指令（每 7 秒脈動，扣掉每分鐘更新）", without_ticks(window(wp + 2, wp + 23)), "avg"),
    # 需要你：舉手與放下只記峰值；舉著手靜止時，收著和收合靜止、展開和展開待著同一個門檻（Codex C-05）
    ("播放中：收著時舉手（0～2 秒）", window(ra, ra + 2), "peak"),
    ("收合、舉著手（扣掉每分鐘更新）", without_ticks(window(ra + 3, ra + 19)), "avg"),
    ("播放中：收著時放下（0～2 秒）", window(lo, lo + 2), "peak"),
    ("播放中：展開時舉手（0～2 秒）", window(rao, rao + 2), "peak"),
    ("展開、舉著手", window(rao + 3, rao + 14), "avg"),
    ("播放中：展開時放下（0～2 秒）", window(loo, loo + 2), "peak"),
    # 背景執行中（ADR-0017 第 7 節）：收著時的循環交給 Core Animation，和收合靜止同一個門檻
    ("收合、背景執行中（呼吸＋慢速泡泡，扣掉每分鐘更新）", without_ticks(window(th + 3, th + 19)), "avg"),
    # 看滑鼠的高幀率（icons 第 4 部分）：展開時游標一直移動、停下後（停掉 display link、只剩眨眼）
    ("展開、游標一直移動（看滑鼠，跟著螢幕更新率）", window(go + 2, go + 15), "avg"),
    ("展開、游標停下後（2～10 秒）", window(gso + 2, gso + 10), "avg"),
]
print("| 階段 | 取樣數 | CPU%（平均或最大） | RSS（MB，最大） |")
print("|---|---|---|---|")
for name, r, kind in rows:
    cpu = avg(r, 1) if kind == "avg" else peak(r, 1)
    print(f"| {name} | {len(r)} | {cpu:.1f}（{'平均' if kind == 'avg' else '最大'}） | {peak(r, 2) / 1024:.1f} |")
by_name = {name: r for name, r, _ in rows}
awake, asleep = by_name["展開待著、醒著（展開後 5～10 秒）"], by_name["展開待著、睡著（睡著後 2～10 秒，呼吸）"]
closed, second = by_name["收合後 60～90 秒"], by_name["第二次收合後 5～18 秒"]
pulsing = by_name["收合、等你下指令（每 7 秒脈動，扣掉每分鐘更新）"]
raised, raised_open = by_name["收合、舉著手（扣掉每分鐘更新）"], by_name["展開、舉著手"]
gaze_asleep = by_name["收合、睡著、游標移動（不重畫，扣掉每分鐘更新）"]
gaze_moving, gaze_still = by_name["收合、醒著、游標一直移動（看滑鼠）"], by_name["收合、游標停住（停止重畫，扣掉每分鐘更新）"]
gaze_open, gaze_open_still = by_name["展開、游標一直移動（看滑鼠，跟著螢幕更新率）"], by_name["展開、游標停下後（2～10 秒）"]
# 看滑鼠時實際每秒畫了幾格：收合每秒 30 格、展開跟著螢幕（至少 60）；不到八成就是螢幕關著或鎖著，CPU 不準。
# 約每秒記一筆：窗口裡那一側（收合／展開）的紀錄前後相隔都不超過 1.6 秒才算數（只有一筆、中途停掉重畫都會被抓到，
# Codex C-02），取中位數：眨眼的約 0.3 秒改由 SwiftUI 畫、不算在圖層的格數裡，那一秒會少幾格（Codex 第二輪 C-01）
def slowest_fps(a, b, side):
    got = sorted((t, n) for t, n, s in frames if a - 1 <= t < b + 1 and s == side)
    times = [a] + [t for t, _ in got] + [b]
    inside = [n for t, n in got if a <= t < b]
    if not inside or max(y - x for x, y in zip(times, times[1:])) > 1.6:
        return 0
    inside.sort()
    return inside[len(inside) // 2]
fps_collapsed, fps_open = slowest_fps(g + 2, g + 15, "collapsed"), slowest_fps(go + 2, go + 15, "open")
print()
print(f"看滑鼠時實際每秒畫的格數（中位數）：收合 {fps_collapsed}、展開 {fps_open}")
if drawn:
    def median_drawn(a, b, side):
        got = sorted(n for t, n, s in drawn if a <= t < b and s == side)
        return got[len(got) // 2] if got else 0
    print(f"其中真的重畫（看得出差別）的：收合 {median_drawn(g + 2, g + 15, 'collapsed')}、展開 {median_drawn(go + 2, go + 15, 'open')}")
# 每個階段都要有取樣（ps 每秒一筆）：播放中至少 2 筆、平均的至少 4 筆，缺了就算失敗（Codex C-07）
missing = [name for name, r, kind in rows if len(r) < (2 if kind == "peak" else 4)]
checks = [
    ("每個階段都有取樣" + (f"（缺：{'、'.join(missing)}）" if missing else ""), not missing),
    ("展開待著（醒著、睡著）≤ 4%", bool(awake) and bool(asleep) and avg(awake, 1) <= 4 and avg(asleep, 1) <= 4),
    ("收合後 1 分鐘 ≤ 0.3%", bool(closed) and avg(closed, 1) <= 0.3),
    # 看滑鼠：游標一直動時和展開待著同一個門檻；游標停住或睡著時和收合靜止同一個門檻
    ("收合、游標一直移動 ≤ 1%", bool(gaze_moving) and avg(gaze_moving, 1) <= 1),
    ("收合、游標停住或睡著 ≤ 0.3%", bool(gaze_still) and bool(gaze_asleep) and avg(gaze_still, 1) <= 0.3 and avg(gaze_asleep, 1) <= 0.3),
    ("收合、等你下指令的脈動 ≤ 0.3%", bool(pulsing) and avg(pulsing, 1) <= 0.3),
    ("收合、舉著手 ≤ 0.3%；展開、舉著手 ≤ 4%", bool(raised) and bool(raised_open) and avg(raised, 1) <= 0.3
     and avg(raised_open, 1) <= 4),
    ("收合、背景執行中 ≤ 0.3%", bool(by_name["收合、背景執行中（呼吸＋慢速泡泡，扣掉每分鐘更新）"])
     and avg(by_name["收合、背景執行中（呼吸＋慢速泡泡，扣掉每分鐘更新）"], 1) <= 0.3),
    # 看滑鼠的高幀率（icons 第 4 部分）：角色由 CoreGraphics 的圖層畫，展開跟著螢幕更新率、收合每秒 30 格。
    # 停下約 1 秒後高幀率要停：停了約 0.1%，沒停就和移動時差不多，所以門檻 1%（Codex C-02）
    ("看滑鼠時真的照頻率重畫（收合 ≥ 24、展開 ≥ 48 格／秒）", fps_collapsed >= 24 and fps_open >= 48),
    ("展開、游標一直移動 ≤ 2%；停下後 ≤ 1%", bool(gaze_open) and bool(gaze_open_still) and avg(gaze_open, 1) <= 2
     and avg(gaze_open_still, 1) <= 1),
    ("第二次收合後 RSS ≤ 第一次收合後 +5 MB", bool(second) and bool(closed) and peak(second, 2) <= peak(closed, 2) + 5 * 1024),
]
print()
for name, ok in checks:
    print(f"- {'✅' if ok else '❌'} {name}")
sys.exit(0 if all(ok for _, ok in checks) else 1)
