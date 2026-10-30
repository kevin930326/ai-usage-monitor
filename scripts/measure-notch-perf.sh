#!/bin/bash
# 量測瀏海面板與角色的 CPU% 與記憶體（ADR-0016 第 6 節，方法同 ADR-0010 第 3 節）。
#
#   scripts/measure-notch-perf.sh [Debug 版 AIUsageMenuBar.app] [輸出資料夾]
#
# 以 Debug 版的 AUM_DEMO_NOTCH_PERF=1 啟動：顯示真的瀏海面板（不截圖），依固定時間表在 10 秒時展開（含約 4.7 秒的過場）、22 秒時睡著（AI 閒置）、
# 32 秒時揮手、35～50 秒每 3 秒依序播點頭、歪頭、偷笑、東張西望、捏一下、表情（只記錄峰值）、55 秒時收合；
# 收著時以假的游標位置量「睡著時游標移動」「游標一直移動」「游標停住」（不移動真的游標；扣掉 App 每分鐘一次的時鐘更新），
# 147 秒時再展開、155 秒時收合；158 秒時收著完成一個 AI 回合（鼓一下、揮手），161 秒起等你下指令（每 7 秒脈動），
# 185 秒收著時需要你（舉手）、205 秒放下，208 秒展開、215 秒展開時舉手、230 秒放下，233 秒收合、235 秒起背景執行中 20 秒，
# 257 秒展開、260～275 秒游標一直移動（看滑鼠的高幀率）、之後停下，約 285 秒後結束；每秒用 ps 取樣，依 perf-mark 分段。
# 使用假資料（暫存資料夾的 usage.json 與 history.sqlite3）與獨立的 demo 設定，不讀真實資料。
# 門檻：展開待著（醒著、睡著）、展開時舉著手 ≤ 4%、展開時游標一直移動 ≤ 2%、停下後 ≤ 1%、收合時游標一直移動 ≤ 1%、收合後 60～90 秒、等你下指令的脈動、收著時舉著手與背景執行中 ≤ 0.3%、第二次收合後 RSS 不超過第一次收合後 +5 MB；任何一項未通過時以非零結束。
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
# PERF_SAMPLE=1：游標一直移動的兩段各用 sample 取 8 秒的呼叫堆疊（找每格的 CPU 花在哪裡；只有假資料，CI 用）
if [ "${PERF_SAMPLE:-}" = 1 ]; then
  (
    for mark in gaze-move gaze-move-open; do
      until grep -q "perf-mark [0-9.]* $mark\$" "$OUT/app.log" 2>/dev/null; do kill -0 "$PID" 2>/dev/null || exit 0; sleep 0.5; done
      sleep 2
      sample "$PID" 8 -file "$OUT/sample-$mark.txt" >/dev/null 2>&1 || true
    done
  ) &
fi
: > "$OUT/samples.tsv"
# 每秒整點取一次（一個 python 跑到 App 結束）：以前每一輪都另開兩個 python，CI 上一輪超過 1 秒，2 秒的播放中只取到 1 筆
python3 - "$PID" "$START" "$OUT/samples.tsv" <<'PY'
import os, subprocess, sys, time
pid, start, out = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
n = 0
with open(out, "a") as f:
    while True:
        try:
            os.kill(pid, 0)
        except OSError:
            break
        line = subprocess.run(["ps", "-o", "%cpu=,rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        if line:
            f.write(f"{time.time() - start:.1f} {line}\n")
            f.flush()
        n += 1
        time.sleep(max(0.0, start + n - time.time()))
PY
rm -rf "$HOME_DIR"

python3 "$ROOT/scripts/notch-perf-summary.py" "$OUT/samples.tsv" "$OUT/app.log" | tee "$OUT/summary.md"
