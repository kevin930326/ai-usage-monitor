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

mkdir -p "$LOG_DIR" "$(dirname "$TARGET")" "$CONFIG_DIR"

# launchd 的 PATH 只有系統目錄，先在這裡找到 claude 的完整路徑寫進 config.json，
# 收集器執行它的 `claude -p /usage` 取得 Claude 用量（ADR-0006）
CLAUDE=""
for candidate in "$(command -v claude || true)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
                 /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then CLAUDE="$candidate"; break; fi
done
if [ -n "$CLAUDE" ]; then
    "$PYTHON" "$COLLECTOR_DIR/scripts/update-config.py" "$CONFIG_DIR/config.json" claude_path "$CLAUDE"
fi

# 只收集這台 Mac 登入過的服務，沒用的服務不會在 App 上顯示成錯誤。
# 一個都沒偵測到時不寫入，收集器維持全部啟用，登入後不必重新安裝也能開始收集。
# 找不到 claude 指令時 Claude 的登入狀態是「不知道」而不是「沒登入」：也不寫入，
# 不然原本啟用的 Claude 會被悄悄關掉（收集器仍會每 5 分鐘記錄「找不到 claude 執行檔」）。
DETECTED="$("$COLLECTOR_DIR/scripts/detect-providers.sh" "$CLAUDE")"
has_provider() { printf '%s\n' "$DETECTED" | grep -qx "$1"; }
if [ -n "$DETECTED" ] && [ -n "$CLAUDE" ]; then
    ENABLED="$(printf '%s\n' "$DETECTED" | "$PYTHON" -c 'import json, sys; print(json.dumps(sys.stdin.read().split()))')"
    "$PYTHON" "$COLLECTOR_DIR/scripts/update-config.py" --json "$CONFIG_DIR/config.json" enabled_providers "$ENABLED"
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
if [ -z "$CLAUDE" ]; then
    echo
    echo "⚠️  找不到 claude 指令，無法取得 Claude 用量，也沒有更動 config.json 的 enabled_providers。"
    echo "   請把 claude 加進 PATH（或裝在 ~/.local/bin、/opt/homebrew/bin）後重新執行這個腳本。"
    echo
fi
if [ -z "$DETECTED" ]; then
    echo
    echo "⚠️  沒有偵測到任何登入資訊。請先在終端機執行 claude 並 /login，或執行 codex login。"
    echo "   在那之前收集器會照常排程，但只會記錄「找不到登入資訊」；登入後下一次執行就會開始收集。"
    echo
else
    if [ -z "$CLAUDE" ]; then
        echo "Claude 用量：不確定（找不到 claude 指令，enabled_providers 維持原設定）"
    elif has_provider claude; then
        echo "Claude 用量：啟用（Claude Code 已登入）"
    else
        echo "Claude 用量：未啟用（Claude Code 沒有登入）"
    fi
    if has_provider codex; then
        echo "Codex 用量：啟用（找到 ~/.codex/auth.json）"
    else
        echo "Codex 用量：未啟用（沒有登入過 Codex CLI）"
    fi
    echo "之後登入了另一個服務，重新執行這個腳本即可啟用。"
fi
echo "Python：$PYTHON"
if [ -z "$DETECTED" ] || has_provider claude; then
    echo "claude 指令：${CLAUDE:-找不到，無法取得 Claude 用量}"
fi
echo "日誌：$LOG_DIR/collector.log"
echo "立即執行一次：launchctl kickstart gui/$(id -u)/$LABEL"
