#!/bin/bash
# 移除 iOS App 重新安裝的 launchd 排程（不會刪除 config.json、狀態或日誌）
set -euo pipefail

LABEL="io.github.kevin930326.ai-usage-monitor.reinstall"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$TARGET"
echo "已移除：$TARGET"
