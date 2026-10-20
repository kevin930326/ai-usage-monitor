#!/bin/bash
# 安裝 launchd 排程：每 5 分鐘執行收集器（FR-4）
set -euo pipefail

LABEL="io.github.kevin930326.ai-usage-monitor"
COLLECTOR_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$COLLECTOR_DIR/launchd/$LABEL.plist.template"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/AIUsageMonitor"
PYTHON="$(command -v python3)"

mkdir -p "$LOG_DIR" "$(dirname "$TARGET")"

# 路徑可能含空白，用 | 當 sed 分隔字元
sed -e "s|__PYTHON__|$PYTHON|" \
    -e "s|__COLLECTOR_DIR__|$COLLECTOR_DIR|" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$TEMPLATE" > "$TARGET"
plutil -lint "$TARGET" >/dev/null

# 已安裝過就先卸載再重新載入
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$TARGET"

echo "已安裝：$TARGET"
echo "Python：$PYTHON"
echo "日誌：$LOG_DIR/collector.log"
echo "立即執行一次：launchctl kickstart gui/$(id -u)/$LABEL"
