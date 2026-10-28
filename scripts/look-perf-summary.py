#!/usr/bin/env python3
"""角色外觀的 CPU 報表（ADR-0021 第 7 節，方法同 ADR-0010 第 3 節）：讀 measure-look-perf.sh 的取樣與 App 的 perf-mark，印一列表格。

    look-perf-summary.py <取樣 tsv> <App 日誌> <代號>

每段開始後 5～28 秒（展開 5～14 秒）的平均，包含 UsageStore 每分鐘的更新（Codex C-03）。
門檻：收合工作中 ≤ 1%、收合睡著 ≤ 0.5%、收合閒置 ≤ 0.3%；未通過、缺標記或某段沒有取樣時以 1 結束。
"""
import math
import re
import sys

samples = [tuple(map(float, line.split())) for line in open(sys.argv[1]) if line.strip()]
log = open(sys.argv[2]).read()
name = sys.argv[3]
marks = {m.group(2): float(m.group(1)) for m in re.finditer(r"perf-mark ([\d.]+) (\S+)", log)}


def avg(a, b):
    rows = [s[1] for s in samples if a <= s[0] < b]
    return sum(rows) / len(rows) if rows else float("nan")


try:
    w, s, i, o = marks["look-work"], marks["look-sleep"], marks["look-idle"], marks["look-open"]
except KeyError as missing:
    print(f"| {name} | 缺少標記 {missing} | | | |")
    sys.exit(1)

work, sleep, idle, opened = avg(w + 5, w + 28), avg(s + 5, s + 28), avg(i + 5, i + 28), avg(o + 5, o + 14)


def cell(value, limit=None):
    if math.isnan(value):
        return "缺取樣 ❌"
    return f"{value:.2f}%" + ("" if limit is None or value <= limit else " ❌")


ok = all(not math.isnan(v) and v <= limit for v, limit in [(work, 1.0), (sleep, 0.5), (idle, 0.3)])
print(f"| {name} | {cell(work, 1.0)} | {cell(sleep, 0.5)} | {cell(idle, 0.3)} | {cell(opened)} |")
sys.exit(0 if ok else 1)
