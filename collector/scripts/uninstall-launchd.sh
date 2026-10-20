#!/bin/bash
# 移除 launchd 排程（不會刪除本機 usage.json、設定或日誌）
set -euo pipefail

LABEL="io.github.kevin930326.ai-usage-monitor"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$TARGET"
echo "已移除：$TARGET"
