#!/bin/bash
# SMAppService 最小原型（ADR-0013 第 3 節）：建置 ad-hoc 簽署的 Probe.app，註冊內建的 LaunchAgent，
# 等它執行兩次，再解除註冊。只寫入 <輸出資料夾>（預設 mktemp），不碰 AI 用量的資料與收集器。
#
#   scripts/prototypes/smappservice/build-and-run.sh [輸出資料夾]
#
# 會在「系統設定 › 一般 › 登入項目」短暫出現「AUMProbe」，結束時（含錯誤與 Ctrl-C）解除註冊。
# 註冊失敗、agent 沒有執行至少兩次、解除後仍留在 launchd 時以非 0 結束。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$(mktemp -d)}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)  # agent 由 launchd 執行，工作目錄不是這裡：一律用絕對路徑
APP=$OUT/AUMProbe.app
LABEL=io.github.kevin930326.AUMProbe.agent
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents" "$OUT/agent-output"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.kevin930326.AUMProbe</string>
  <key>CFBundleName</key><string>AUMProbe</string>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# agent：BundleProgram 是 App 內的相對路徑（App 搬到別處也找得到）；輸出的絕對路徑在建置時寫入
cat > "$APP/Contents/Resources/agent.sh" <<SH
#!/bin/sh
date -u +%Y-%m-%dT%H:%M:%SZ >> "$OUT/agent-output/runs.txt"
SH
chmod +x "$APP/Contents/Resources/agent.sh"
cat > "$APP/Contents/Library/LaunchAgents/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>BundleProgram</key><string>Contents/Resources/agent.sh</string>
  <key>StartInterval</key><integer>10</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST

swiftc -O -o "$APP/Contents/MacOS/Probe" "$HERE/Probe.swift"
codesign --force --deep -s - "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Signature|TeamIdentifier|flags"

PROBE=$APP/Contents/MacOS/Probe
RUNS=$OUT/agent-output/runs.txt
registered=0
# 不論正常結束、失敗或中斷都解除註冊，不留下每 10 秒執行一次的背景工作
cleanup() {
  [ "$registered" = 1 ] || return 0
  registered=0
  "$PROBE" unregister || echo "解除註冊失敗：到「系統設定 › 一般 › 登入項目」移除 AUMProbe" >&2
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$PROBE" status
: > "$RUNS"
"$PROBE" register || { echo "註冊失敗" >&2; exit 1; }
registered=1
sleep 25 & wait $!  # 背景 sleep＋wait：收到訊號時馬上處理（前景 sleep 會讓 trap 等到睡完）
runs=$(wc -l < "$RUNS" | tr -d ' ')
echo "agent 執行次數：$runs"
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|program|runs" | head -5 || echo "launchctl 找不到 $LABEL"
cleanup
sleep 2
fail=0
if [ "$runs" -lt 2 ]; then echo "agent 在 25 秒內執行不到兩次" >&2; fail=1; fi
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then echo "解除後仍在 launchd" >&2; fail=1; else echo "解除後已不在 launchd"; fi
echo "輸出：$OUT"
exit $fail
