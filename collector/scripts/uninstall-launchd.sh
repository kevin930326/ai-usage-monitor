#!/bin/bash
# 移除 launchd 排程（不會刪除本機 usage.json、設定或日誌）。
# 額度歷史 history.sqlite3 會詢問是否一併刪除，預設不刪（ADR-0009 第 5 節）；
# 不是在終端機執行（沒有 stdin）時一律保留
#   AUM_DELETE_HISTORY=1 scripts/uninstall-launchd.sh   # 不詢問，直接刪除
set -euo pipefail

LABEL="io.github.kevin930326.ai-usage-monitor"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$TARGET"
echo "已移除：$TARGET"

DATA_DIR="${AI_USAGE_MONITOR_HOME:-$HOME/Library/Application Support/AIUsageMonitor}"
HISTORY="$DATA_DIR/history.sqlite3"
if [ -e "$HISTORY" ]; then
    answer="${AUM_DELETE_HISTORY:-}"
    if [ -z "$answer" ] && [ -t 0 ]; then
        read -r -p "要一併刪除額度歷史（${HISTORY}）嗎？[y/N] " answer || answer=""
    fi
    case "$answer" in
        y|Y|yes|YES|1)
            rm -f "$HISTORY" "$HISTORY-wal" "$HISTORY-shm"
            echo "已刪除額度歷史" ;;
        *)
            echo "保留額度歷史：$HISTORY" ;;
    esac
fi
