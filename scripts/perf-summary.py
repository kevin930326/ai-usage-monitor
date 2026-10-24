#!/usr/bin/env python3
"""measure-panel-perf.sh 的報表：依 App 印出的 perf-mark 把 ps 的取樣分段，印出 Markdown 表格與各項門檻
（ADR-0010 第 3 節）。任何一項未通過（含缺少標記或取樣）時以 1 結束。

用法：scripts/perf-summary.py <samples.tsv> <app.log> <情境>
samples.tsv 每行「秒數 CPU% RSS(KB)」；app.log 含「perf-mark <秒> <名稱>」。
"""
import re, sys
samples = [tuple(map(float, l.split())) for l in open(sys.argv[1]) if l.strip()]
marks = {m.group(2): float(m.group(1)) for m in re.finditer(r"perf-mark ([\d.]+) (\S+)", open(sys.argv[2]).read())}
def window(a, b):
    return [s for s in samples if a <= s[0] < b]
def avg(rows, i): return sum(r[i] for r in rows) / len(rows) if rows else float("nan")
def peak(rows, i): return max((r[i] for r in rows), default=float("nan"))
o, c = marks["panel-open"], marks["panel-close"]
base = window(o - 6, o)
rows = [("開啟前（基準）", base, "avg")]
# 骨架掃光播放 3.6 秒，靜止從開啟後 5 秒算起
rows.append(("面板開啟、靜止（開啟後 5～11 秒）", window(o + 5, o + 11), "avg"))
opening = "打開面板：圓環＋用量條＋骨架掃光" if sys.argv[3] == "fresh" else "打開面板：圓環＋用量條＋走勢"
rows.append((f"播放中：{opening}（開啟後 0～4 秒）", window(o, o + 4), "peak"))
anims = [ ("更新按鈕", "refresh"), ("額度重置光芒", "glow"),
         ("卡片收合", "collapse"), ("卡片展開", "expand"), ("切換走勢額度", "trend-next"), ("重置圓點淡出＋光芒", "departing"), ("切到深色", "appearance-dark"), ("切回淺色", "appearance-light"),
         ("統計切換服務", "stats-scope"), ("統計切換範圍", "stats-range"),
         ("服務狀態橘點呼吸", "status-pulse"), ("點通知後卡片亮一下", "highlight")]
for name, key in anims:
    rows.append((f"播放中：{name}", window(marks[key], marks[key] + 2), "peak"))
rows.append(("關閉後 60～90 秒", window(c + 60, c + 90), "avg"))
c2 = marks.get("panel-close-2")
if c2:
    rows.append(("第二次關閉後 5～18 秒", window(c2 + 5, c2 + 18), "avg"))
so, sc = marks.get("stats-open"), marks.get("stats-close")
if so and sc:
    rows.append(("播放中：打開完整統計視窗（0～3 秒）", window(so, so + 3), "peak"))
    rows.append(("完整統計視窗開啟、靜止（3～9 秒）", window(so + 3, so + 9), "avg"))
    rows.append(("完整統計視窗關閉後 5～18 秒", window(sc + 5, sc + 18), "avg"))
sc2 = marks.get("stats-close-2")
if sc2:
    rows.append(("完整統計視窗第二次關閉後 5～18 秒", window(sc2 + 5, sc2 + 18), "avg"))
print(f"情境：{sys.argv[3]}（scripts/make-demo-history.py）")
print()
print("| 階段 | 取樣數 | CPU%（平均或最大） | RSS（MB，最大） |")
print("|---|---|---|---|")
for name, r, kind in rows:
    cpu = avg(r, 1) if kind == "avg" else peak(r, 1)
    print(f"| {name} | {len(r)} | {cpu:.1f}（{'平均' if kind == 'avg' else '最大'}） | {peak(r, 2) / 1024:.1f} |")
closed = window(c + 60, c + 90)
ok_cpu = avg(closed, 1) <= 0.3
ok_static = avg(window(o + 5, o + 11), 1) <= 2
# 第一次開啟會載入 SwiftUI 與字型，RSS 不會回到開啟前；改為比較兩次關閉後，確認沒有累積
second = window(c2 + 5, c2 + 18) if c2 else []
rss_limit = peak(closed, 2) + 5 * 1024
ok_rss = bool(second) and peak(second, 2) <= rss_limit
stats_static = window(so + 3, so + 9) if so else []
stats_after = window(sc + 5, sc + 18) if sc else []
ok_stats_static = bool(stats_static) and avg(stats_static, 1) <= 2
# 關閉統計視窗後釋放資料：不超過面板第二次關閉後 +5 MB
stats_limit = (peak(second, 2) if second else peak(closed, 2)) + 5 * 1024
ok_stats_rss = bool(stats_after) and peak(stats_after, 2) <= stats_limit
print()
print(f"- 開啟靜止 ≤ 2%：{'通過' if ok_static else '未通過'}")
print(f"- 完整統計視窗靜止 ≤ 2%：{'通過' if ok_stats_static else '未通過'}")
print(f"- 完整統計視窗關閉後 RSS 不超過面板第二次關閉後 +5 MB（{stats_limit / 1024:.1f} MB）：{'通過' if ok_stats_rss else '未通過'}")
print(f"- 關閉後 1 分鐘 ≤ 0.3%：{'通過' if ok_cpu else '未通過'}")
print(f"- 第二次開關後 RSS 不超過第一次關閉後 +5 MB（{rss_limit / 1024:.1f} MB）：{'通過' if ok_rss else '未通過'}")
# 統計視窗第二次開關不累積：第二次關閉後不超過第一次關閉後 +5 MB（缺標記或取樣即未通過）
stats_after_2 = window(sc2 + 5, sc2 + 18) if sc2 else []
stats_limit_2 = peak(stats_after, 2) + 5 * 1024 if stats_after else float("nan")
ok_stats_repeat = bool(stats_after) and bool(stats_after_2) and peak(stats_after_2, 2) <= stats_limit_2
print(f"- 完整統計視窗第二次開關後 RSS 不超過第一次關閉後 +5 MB（{stats_limit_2 / 1024:.1f} MB）：{'通過' if ok_stats_repeat else '未通過'}")
# 任何一項未通過（含沒有取樣，平均為 NaN）就以非零結束
sys.exit(0 if ok_static and ok_cpu and ok_rss and ok_stats_static and ok_stats_rss and ok_stats_repeat else 1)
