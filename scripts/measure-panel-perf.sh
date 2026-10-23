#!/bin/bash
# 量測 Mac 面板動畫的 CPU% 與記憶體（NFR-10、ADR-0010 第 3 節）。
#
#   scripts/measure-panel-perf.sh [Debug 版 AIUsageMenuBar.app] [輸出資料夾]
#
# 以 Debug 版的 AUM_DEMO_PANEL=1 AUM_DEMO_PERF=1 啟動（面板放在一般視窗，依固定時間表觸發動畫、
# 46 秒時關閉面板，138 秒時再開關一次，約 166 秒後結束），每秒用 ps 取樣，依 App 印出的 perf-mark 分段計算。
# Debug 版比 Release 慢，用 Debug 量測是較保守的結果（觸發用的環境變數只在 Debug 版）。
# 使用假資料（暫存資料夾的 usage.json），不讀真實的 usage.json；設定也用獨立的 demo 設定。
# 任何一項門檻未通過時以非零結束。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-$ROOT/build/verify/DerivedData/MacMenuBar/Build/Products/Debug/AIUsageMenuBar.app}
OUT=${2:-$ROOT/build/perf}
BIN="$APP/Contents/MacOS/AIUsageMenuBar"
[ -x "$BIN" ] || { echo "找不到 $BIN（先建置 Debug 版）"; exit 2; }
mkdir -p "$OUT"
HOME_DIR=$(mktemp -d)
python3 - "$HOME_DIR/usage.json" <<'PY'
import json, sys, datetime as d
now = d.datetime.now(d.timezone.utc).replace(microsecond=0)
f = lambda m: (now + d.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%SZ")
w = lambda i, l, u, m: {"id": i, "label": l, "used_pct": u, "resets_at": f(m), "hidden": False}
json.dump({"schema_version": 1, "updated_at": f(-2), "providers": {
    "claude": {"plan": "Max", "error": None, "windows": [w("five_hour", "5 小時", 73, 120), w("weekly", "每週", 41, 71 * 60)]},
    "codex": {"plan": "Team", "error": None, "windows": [w("five_hour", "5 小時", 18, 199), w("weekly", "每週", 35, 119 * 60)]},
}}, open(sys.argv[1], "w"), ensure_ascii=False)
PY

AI_USAGE_MONITOR_HOME="$HOME_DIR" AUM_DEMO_PANEL=1 AUM_DEMO_PERF=1 "$BIN" 2>"$OUT/app.log" &
PID=$!
START=$(python3 -c 'import time; print(time.time())')
: > "$OUT/samples.tsv"
while kill -0 "$PID" 2>/dev/null; do
  NOW=$(python3 -c "import time; print(f'{time.time() - $START:.1f}')")
  LINE=$(ps -o %cpu=,rss= -p "$PID" 2>/dev/null || true)
  [ -n "$LINE" ] && echo "$NOW $LINE" >> "$OUT/samples.tsv"
  sleep 1
done
rm -rf "$HOME_DIR"

python3 - "$OUT/samples.tsv" "$OUT/app.log" <<'PY' | tee "$OUT/summary.md"
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
rows.append(("面板開啟、靜止（開啟後 3～11 秒）", window(o + 3, o + 11), "avg"))
anims = [("打開面板：圓環＋用量條", "panel-open"), ("更新按鈕", "refresh"), ("額度重置光芒", "glow"),
         ("卡片收合", "collapse"), ("卡片展開", "expand"), ("切到深色", "appearance-dark"), ("切回淺色", "appearance-light")]
for name, key in anims:
    rows.append((f"播放中：{name}", window(marks[key], marks[key] + 2), "peak"))
rows.append(("關閉後 60～90 秒", window(c + 60, c + 90), "avg"))
c2 = marks.get("panel-close-2")
if c2:
    rows.append(("第二次關閉後 5～18 秒", window(c2 + 5, c2 + 18), "avg"))
print("| 階段 | 取樣數 | CPU%（平均或最大） | RSS（MB，最大） |")
print("|---|---|---|---|")
for name, r, kind in rows:
    cpu = avg(r, 1) if kind == "avg" else peak(r, 1)
    print(f"| {name} | {len(r)} | {cpu:.1f}（{'平均' if kind == 'avg' else '最大'}） | {peak(r, 2) / 1024:.1f} |")
closed = window(c + 60, c + 90)
ok_cpu = avg(closed, 1) <= 0.3
ok_static = avg(window(o + 3, o + 11), 1) <= 2
# 第一次開啟會載入 SwiftUI 與字型，RSS 不會回到開啟前；改為比較兩次關閉後，確認沒有累積
second = window(c2 + 5, c2 + 18) if c2 else []
rss_limit = peak(closed, 2) + 5 * 1024
ok_rss = bool(second) and peak(second, 2) <= rss_limit
print()
print(f"- 開啟靜止 ≤ 2%：{'通過' if ok_static else '未通過'}")
print(f"- 關閉後 1 分鐘 ≤ 0.3%：{'通過' if ok_cpu else '未通過'}")
print(f"- 第二次開關後 RSS 不超過第一次關閉後 +5 MB（{rss_limit / 1024:.1f} MB）：{'通過' if ok_rss else '未通過'}")
# 任何一項未通過（含沒有取樣，平均為 NaN）就以非零結束
sys.exit(0 if ok_static and ok_cpu and ok_rss else 1)
PY
