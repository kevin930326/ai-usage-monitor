#!/bin/bash
# 安裝 launchd 排程：每 20 分鐘檢查，滿 6 天後在捷徑自動化前的時段重新簽署並安裝 iOS App（scripts/reinstall-ios.sh）
set -euo pipefail

LABEL="io.github.kevin930326.ai-usage-monitor.reinstall"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO/scripts/launchd/$LABEL.plist.template"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/AIUsageMonitor"
PYTHON="$(command -v python3)"

XCODEGEN="$(command -v xcodegen || true)"
if [ -z "$XCODEGEN" ]; then
    echo "找不到 xcodegen，請先執行 brew install xcodegen" >&2
    exit 1
fi
LAUNCH_PATH="$(dirname "$XCODEGEN"):/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$LOG_DIR" "$(dirname "$TARGET")"

# 路徑可能含空白，用 | 當 sed 分隔字元
sed -e "s|__REPO__|$REPO|g" \
    -e "s|__PATH__|$LAUNCH_PATH|" \
    -e "s|__PYTHON__|$PYTHON|" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$TEMPLATE" > "$TARGET"
plutil -lint "$TARGET" >/dev/null

# 已安裝過就先卸載再重新載入
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$TARGET"

echo "已安裝：$TARGET"
echo "執行的 repo：$REPO"
echo "Python：${PYTHON}（需與收集器相同，才能讀取 ~/Documents）"
echo "日誌：$LOG_DIR/reinstall.log"
echo "立即檢查一次（未滿 6 天不會重新安裝）：launchctl kickstart gui/$(id -u)/$LABEL"
