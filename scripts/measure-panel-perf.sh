#!/bin/bash
# 量測 Mac 面板動畫的 CPU% 與記憶體（NFR-10、ADR-0010 第 3 節）。
#
#   scripts/measure-panel-perf.sh [Debug 版 AIUsageMenuBar.app] [輸出資料夾]
#   AUM_PERF_SCENARIO=fresh scripts/measure-panel-perf.sh …   # 歷史只有 1 筆：量測骨架掃光
#
# 以 Debug 版的 AUM_DEMO_PANEL=1 AUM_DEMO_PERF=1 啟動（面板放在一般視窗，依固定時間表觸發動畫、
# 64 秒時關閉面板，156 秒時再開關一次，184 秒打開完整統計視窗、194 秒關閉，214 秒再開、224 秒再關，244 秒打開設定精靈、254 秒關閉，274 秒再開、284 秒再關，約 309 秒後結束），
# 每秒用 ps 取樣，依 App 印出的 perf-mark 分段計算（scripts/perf-summary.py）。
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

AI_USAGE_MONITOR_HOME="$HOME_DIR" AUM_TESTING=1 AUM_DEMO_PANEL=1 AUM_DEMO_PERF=1 "$BIN" 2>"$OUT/app.log" &
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

python3 "$ROOT/scripts/perf-summary.py" "$OUT/samples.tsv" "$OUT/app.log" "$SCENARIO" | tee "$OUT/summary.md"
