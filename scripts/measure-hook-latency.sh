#!/bin/bash
# 量測 aum-hook 的執行時間（ADR-0017：目標 < 50 ms）：App 在聽與沒在跑兩種情況，各執行 N 次。
#
#   scripts/measure-hook-latency.sh [Debug 版 AIUsageMenuBar.app] [次數]
#
# 使用暫存資料夾（AI_USAGE_MONITOR_HOME）與假的事件內容，不碰真的 ~/.claude、~/.codex；不連網路。
# 印出中位數與最大值；中位數超過 50 ms 或 App 在聽時一個事件都沒收到就以非零結束。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-$ROOT/build/dd/Build/Products/Debug/AIUsageMenuBar.app}
N=${2:-100}
HOOK="$APP/Contents/Helpers/aum-hook"
BIN="$APP/Contents/MacOS/AIUsageMenuBar"
[ -x "$HOOK" ] && [ -x "$BIN" ] || { echo "找不到 ${HOOK}（先建置 Debug 版）"; exit 2; }
HOME_DIR=$(mktemp -d)
trap 'kill "${PID:-0}" 2>/dev/null || true; rm -rf "$HOME_DIR"' EXIT
EVENT='{"session_id":"perf-session","hook_event_name":"PreToolUse","cwd":"/tmp/perf-project","tool_name":"Bash","tool_input":{"command":"echo hi"}}'

measure() {
  python3 - "$HOOK" "$N" "$EVENT" "$HOME_DIR" <<'EOF'
import os, subprocess, sys, time, statistics
hook, n, event, home = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode(), sys.argv[4]
env = {"PATH": "/usr/bin:/bin", "AI_USAGE_MONITOR_HOME": home}
times = []
for _ in range(n):
    start = time.perf_counter()
    r = subprocess.run([hook, "claude"], input=event, env=env, capture_output=True)
    times.append((time.perf_counter() - start) * 1000)
    if r.returncode != 0 or r.stdout or r.stderr:
        print(f"hook 不該有輸出或非零結束：{r.returncode} {r.stdout!r} {r.stderr!r}"); sys.exit(1)
print(f"{statistics.median(times):.1f} {max(times):.1f}")
EOF
}

read -r IDLE_MED IDLE_MAX < <(measure)
echo "App 沒在跑：中位數 ${IDLE_MED} ms、最大 ${IDLE_MAX} ms"

AI_USAGE_MONITOR_HOME="$HOME_DIR" AUM_TESTING=1 "$BIN" 2>"$HOME_DIR/app.log" &
PID=$!
for _ in $(seq 50); do [ -S "$HOME_DIR/agent/hook.sock" ] && break; sleep 0.2; done
[ -S "$HOME_DIR/agent/hook.sock" ] || { echo "App 沒有建立 socket"; exit 1; }
read -r LIVE_MED LIVE_MAX < <(measure)
echo "App 在聽：中位數 ${LIVE_MED} ms、最大 ${LIVE_MAX} ms"
kill "$PID"; wait "$PID" 2>/dev/null || true
[ ! -e "$HOME_DIR/agent/hook.sock" ] && echo "App 結束後 socket 已移除" || { echo "❌ App 結束後 socket 還在"; exit 1; }
# App 只記數字：每秒最多處理 40 個、其餘丟掉（ADR-0017），收到加丟掉要等於送出的次數
COUNTS=$(grep -o 'agent events received=[0-9]* dropped=[0-9]*' "$HOME_DIR/app.log" || true)
echo "App 收到：${COUNTS:-沒有紀錄}"
python3 -c '
import re, sys
m = re.search(r"received=(\d+) dropped=(\d+)", sys.argv[1])
ok = bool(m) and int(m[1]) > 0 and int(m[1]) + int(m[2]) == int(sys.argv[2])
print("✅ 每個事件都送到了" if ok else "❌ App 收到的事件數不對"); sys.exit(0 if ok else 1)
' "$COUNTS" "$N"
python3 -c "import sys; sys.exit(0 if float('$IDLE_MED') < 50 and float('$LIVE_MED') < 50 else 1)" \
  && echo "✅ 中位數 < 50 ms" || { echo "❌ 中位數超過 50 ms"; exit 1; }
