#!/bin/bash
# 安裝 launchd 排程：每 5 分鐘執行收集器（FR-4）
set -euo pipefail

LABEL="io.github.kevin930326.ai-usage-monitor"
COLLECTOR_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$COLLECTOR_DIR/launchd/$LABEL.plist.template"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/AIUsageMonitor"
PYTHON="$(command -v python3)"
CONFIG_DIR="${AI_USAGE_MONITOR_HOME:-$HOME/Library/Application Support/AIUsageMonitor}"

mkdir -p "$LOG_DIR" "$(dirname "$TARGET")"

# launchd 的 PATH 只有系統目錄，先在這裡找到 claude 的完整路徑寫進 config.json，
# 收集器在 token 快過期時用它委派 Claude Code 續期（ADR-0005）；找不到就略過
CLAUDE=""
for candidate in "$(command -v claude || true)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
                 /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then CLAUDE="$candidate"; break; fi
done
if [ -n "$CLAUDE" ]; then
    mkdir -p "$CONFIG_DIR"
    "$PYTHON" "$COLLECTOR_DIR/scripts/update-config.py" "$CONFIG_DIR/config.json" claude_path "$CLAUDE"
fi

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
echo "Claude：${CLAUDE:-找不到，token 過期時不會自動續期}"
echo "日誌：$LOG_DIR/collector.log"
echo "立即執行一次：launchctl kickstart gui/$(id -u)/$LABEL"
