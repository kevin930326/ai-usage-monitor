#!/bin/bash
# 量測瀏海面板與角色的 CPU% 與記憶體（ADR-0016 第 6 節，方法同 ADR-0010 第 3 節）。
#
#   scripts/measure-notch-perf.sh [Debug 版 AIUsageMenuBar.app] [輸出資料夾]
#
# 以 Debug 版的 AUM_DEMO_NOTCH_PERF=1 啟動：顯示真的瀏海面板（不截圖），依固定時間表在 10 秒時展開（含約 4.7 秒的過場）、22 秒時睡著（AI 閒置）、
# 32 秒時揮手、35～50 秒每 3 秒依序播點頭、歪頭、偷笑、東張西望、捏一下、表情（只記錄峰值）、55 秒時收合；
# 收著時以假的游標位置量「睡著時游標移動」「游標一直移動」「游標停住」（不移動真的游標；扣掉 App 每分鐘一次的時鐘更新），
# 147 秒時再展開、155 秒時收合；158 秒時收著完成一個 AI 回合（鼓一下、揮手），161 秒起等你下指令（每 7 秒脈動），
# 約 187 秒後結束；每秒用 ps 取樣，依 perf-mark 分段。
# 使用假資料（暫存資料夾的 usage.json 與 history.sqlite3）與獨立的 demo 設定，不讀真實資料。
# 門檻：展開待著（醒著、睡著）≤ 4%、收合後 60～90 秒與等你下指令的脈動 ≤ 0.3%、第二次收合後 RSS 不超過第一次收合後 +5 MB；任何一項未通過時以非零結束。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-$ROOT/build/verify/DerivedData/MacMenuBar/Build/Products/Debug/AIUsageMenuBar.app}
OUT=${2:-$ROOT/build/perf-notch}
BIN="$APP/Contents/MacOS/AIUsageMenuBar"
[ -x "$BIN" ] || { echo "找不到 ${BIN}（先建置 Debug 版）"; exit 2; }
mkdir -p "$OUT"
touch "$OUT/.metadata_never_index"
HOME_DIR=$(mktemp -d)
python3 "$ROOT/scripts/make-demo-history.py" "$HOME_DIR" normal

AI_USAGE_MONITOR_HOME="$HOME_DIR" AUM_TESTING=1 AUM_DEMO_NOTCH_PERF=1 "$BIN" 2>"$OUT/app.log" &
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

python3 "$ROOT/scripts/notch-perf-summary.py" "$OUT/samples.tsv" "$OUT/app.log" | tee "$OUT/summary.md"
