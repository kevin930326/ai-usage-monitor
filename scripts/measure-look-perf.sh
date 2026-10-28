#!/bin/bash
# 量測角色外觀特效的 CPU%（ADR-0021，方法同 ADR-0010 第 3 節）：每個外觀各啟動一次 Debug 版，
# 以 AUM_DEMO_LOOK_PERF=<代號> 顯示真的瀏海面板，收著時 AI 工作中 30 秒、睡著 30 秒、閒置 30 秒、展開 15 秒，每秒用 ps 取樣。
#
#   scripts/measure-look-perf.sh [Debug 版 AIUsageMenuBar.app] [輸出資料夾] [代號 …]
#
# 代號預設是 none（跟著服務）、每個會動的特效、像素與一個漸層。使用假資料與獨立的 demo 設定，不讀真實資料。
# 門檻（每段開始後 5～28 秒的平均，包含每分鐘的更新；計算在 look-perf-summary.py）：收合工作中 ≤ 1%、收合睡著 ≤ 0.5%、收合閒置 ≤ 0.3%；未通過時以非零結束。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-$ROOT/build/verify/DerivedData/MacMenuBar/Build/Products/Debug/AIUsageMenuBar.app}
OUT=${2:-$ROOT/build/perf-looks}
shift $(( $# > 2 ? 2 : $# ))
LOOKS=("$@")
[ ${#LOOKS[@]} -gt 0 ] || LOOKS=(none X9 X8 X4 X3 X10 T5)
BIN="$APP/Contents/MacOS/AIUsageMenuBar"
[ -x "$BIN" ] || { echo "找不到 ${BIN}（先建置 Debug 版）"; exit 2; }
mkdir -p "$OUT"
touch "$OUT/.metadata_never_index"
STATUS=0
echo "| 外觀 | 收合、工作中 | 收合、睡著 | 收合、閒置 | 展開待著 |"
echo "|---|---|---|---|---|"
for LOOK in "${LOOKS[@]}"; do
  HOME_DIR=$(mktemp -d)
  python3 "$ROOT/scripts/make-demo-history.py" "$HOME_DIR" normal
  AI_USAGE_MONITOR_HOME="$HOME_DIR" AUM_TESTING=1 AUM_DEMO_LOOK_PERF="$LOOK" "$BIN" 2>"$OUT/$LOOK.log" &
  PID=$!
  START=$(python3 -c 'import time; print(time.time())')
  : > "$OUT/$LOOK.tsv"
  while kill -0 "$PID" 2>/dev/null; do
    NOW=$(python3 -c "import time; print(f'{time.time() - $START:.1f}')")
    LINE=$(ps -o %cpu=,rss= -p "$PID" 2>/dev/null || true)
    [ -n "$LINE" ] && echo "$NOW $LINE" >> "$OUT/$LOOK.tsv"
    sleep 1
  done
  rm -rf "$HOME_DIR"
  python3 "$ROOT/scripts/look-perf-summary.py" "$OUT/$LOOK.tsv" "$OUT/$LOOK.log" "$LOOK" || STATUS=1
done
exit $STATUS
