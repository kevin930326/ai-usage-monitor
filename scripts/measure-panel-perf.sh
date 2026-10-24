#!/bin/bash
# 量測 Mac 面板動畫的 CPU% 與記憶體（NFR-10、ADR-0010 第 3 節）。
#
#   scripts/measure-panel-perf.sh [Debug 版 AIUsageMenuBar.app] [輸出資料夾]
#   AUM_PERF_SCENARIO=fresh scripts/measure-panel-perf.sh …   # 歷史只有 1 筆：量測骨架掃光
#
# 以 Debug 版的 AUM_DEMO_PANEL=1 AUM_DEMO_PERF=1 啟動（面板放在一般視窗，依固定時間表觸發動畫、
# 64 秒時關閉面板，156 秒時再開關一次，184 秒打開完整統計視窗、194 秒關閉，約 214 秒後結束），
# 每秒用 ps 取樣，依 App 印出的 perf-mark 分段計算。
# Debug 版比 Release 慢，用 Debug 量測是較保守的結果（觸發用的環境變數只在 Debug 版）。
# 使用假資料（暫存資料夾的 usage.json 與 history.sqlite3），不讀真實資料；設定也用獨立的 demo 設定。
# 任何一項門檻未通過時以非零結束。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-$ROOT/build/verify/DerivedData/MacMenuBar/Build/Products/Debug/AIUsageMenuBar.app}
OUT=${2:-$ROOT/build/perf}
BIN="$APP/Contents/MacOS/AIUsageMenuBar"
[ -x "$BIN" ] || { echo "找不到 ${BIN}（先建置 Debug 版）"; exit 2; }
mkdir -p "$OUT"
touch "$OUT/.metadata_never_index"  # 不讓 Spotlight 索引量測紀錄
HOME_DIR=$(mktemp -d)
# 假的 usage.json 與 7 天的 history.sqlite3（含睡眠空檔與重置），讓走勢、額度消耗等區塊都有東西畫
# AUM_PERF_SCENARIO=fresh 時每個額度只有 1 筆，走勢與額度消耗顯示骨架畫面（打開面板時掃光三次）
SCENARIO=${AUM_PERF_SCENARIO:-normal}
python3 "$ROOT/scripts/make-demo-history.py" "$HOME_DIR" "$SCENARIO"

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

python3 - "$OUT/samples.tsv" "$OUT/app.log" "$SCENARIO" <<'PY' | tee "$OUT/summary.md"
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
# 參考（不設門檻）：統計視窗第二次關閉與第一次關閉的差，確認關閉後的 RSS 是一次性的成本、不是累積
stats_after_2 = window(sc2 + 5, sc2 + 18) if sc2 else []
if stats_after and stats_after_2:
    grow = (peak(stats_after_2, 2) - peak(stats_after, 2)) / 1024
    print(f"- （參考）完整統計視窗第二次關閉後比第一次：{grow:+.1f} MB")
# 任何一項未通過（含沒有取樣，平均為 NaN）就以非零結束
sys.exit(0 if ok_static and ok_cpu and ok_rss and ok_stats_static and ok_stats_rss else 1)
PY
