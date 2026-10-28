#!/bin/bash
# 量測角色外觀特效的 CPU%（ADR-0021，方法同 ADR-0010 第 3 節）：每個外觀各啟動一次 Debug 版，
# 以 AUM_DEMO_LOOK_PERF=<代號> 顯示真的瀏海面板，收著時 AI 工作中 30 秒、睡著 30 秒、閒置 30 秒、展開 15 秒，每秒用 ps 取樣。
#
#   scripts/measure-look-perf.sh [Debug 版 AIUsageMenuBar.app] [輸出資料夾] [代號 …]
#
# 代號預設是 none（跟著服務）、每個會動的特效、像素與一個漸層。使用假資料與獨立的 demo 設定，不讀真實資料。
# 門檻（每段開始後 5～28 秒的平均）：收合工作中 ≤ 1%、收合睡著 ≤ 0.5%、收合閒置 ≤ 0.3%；未通過時以非零結束。
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
  python3 - "$OUT/$LOOK.tsv" "$OUT/$LOOK.log" "$LOOK" <<'PY' || STATUS=1
import re, sys
samples = [tuple(map(float, l.split())) for l in open(sys.argv[1]) if l.strip()]
log = open(sys.argv[2]).read()
marks = {m.group(2): float(m.group(1)) for m in re.finditer(r"perf-mark ([\d.]+) (\S+)", log)}
ticks = [float(t) for t in re.findall(r"perf-mark ([\d.]+) minute-tick", log)]
def avg(a, b):
    rows = [s[1] for s in samples if a <= s[0] < b and not any(t <= s[0] < t + 2 for t in ticks)]
    return sum(rows) / len(rows) if rows else float("nan")
try:
    w, s, i, o = marks["look-work"], marks["look-sleep"], marks["look-idle"], marks["look-open"]
except KeyError as missing:
    print(f"| {sys.argv[3]} | 缺少標記 {missing} | | | |")
    sys.exit(1)
work, sleep, idle, opened = avg(w + 5, w + 28), avg(s + 5, s + 28), avg(i + 5, i + 28), avg(o + 5, o + 14)
ok = work <= 1.0 and sleep <= 0.5 and idle <= 0.3
mark = lambda v, limit: f"{v:.2f}%" + ("" if v <= limit else " ❌")
print(f"| {sys.argv[3]} | {mark(work, 1.0)} | {mark(sleep, 0.5)} | {mark(idle, 0.3)} | {opened:.2f}% |")
sys.exit(0 if ok else 1)
PY
done
exit $STATUS
