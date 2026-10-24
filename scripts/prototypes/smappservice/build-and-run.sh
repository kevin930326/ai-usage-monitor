#!/bin/bash
# SMAppService 最小原型（ADR-0013 第 3 節）：建置 ad-hoc 簽署的 Probe.app，註冊內建的 LaunchAgent，
# 等它執行兩次，再解除註冊。只寫入 <輸出資料夾>（預設 mktemp），不碰 AI 用量的資料與收集器。
#
#   scripts/prototypes/smappservice/build-and-run.sh [輸出資料夾]
#
# 會在「系統設定 › 一般 › 登入項目」短暫出現「AUMProbe」，結束時解除註冊。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$(mktemp -d)}
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
"$PROBE" status
"$PROBE" register || true
sleep 25
echo "agent 執行次數：$(wc -l < "$OUT/agent-output/runs.txt" 2>/dev/null || echo 0)"
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|program|runs" | head -5 || echo "launchctl 找不到 $LABEL"
"$PROBE" unregister || true
sleep 2
launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "解除後仍在 launchd" || echo "解除後已不在 launchd"
echo "輸出：$OUT"
