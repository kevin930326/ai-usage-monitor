#!/bin/bash
# 安裝 launchd 排程：每 5 分鐘執行收集器（FR-4）
set -euo pipefail

LABEL="io.github.kevin930326.ai-usage-monitor"
COLLECTOR_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$COLLECTOR_DIR/launchd/$LABEL.plist.template"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
# AI 狀態同步（ADR-0019 第 2 節）：沒有排程，App 寫了 agent-state.json 後以 launchctl kickstart 觸發
SYNC_LABEL="$LABEL.agent-sync"
SYNC_TEMPLATE="$COLLECTOR_DIR/launchd/$SYNC_LABEL.plist.template"
SYNC_TARGET="$HOME/Library/LaunchAgents/$SYNC_LABEL.plist"
LOG_DIR="$HOME/Library/Logs/AIUsageMonitor"
PYTHON="$(command -v python3)"
CONFIG_DIR="${AI_USAGE_MONITOR_HOME:-$HOME/Library/Application Support/AIUsageMonitor}"

mkdir -p "$LOG_DIR" "$(dirname "$TARGET")" "$CONFIG_DIR"

# App 內建的收集器（ADR-0013 第 3 節）已註冊時提示：兩個不會重複執行（內建的看到這個排程就略過），但通常只需要一個
if launchctl print "gui/$(id -u)/io.github.kevin930326.AIUsageMenuBar.collector" >/dev/null 2>&1; then
    echo "提示：App 內建的收集器已啟用。安裝這個排程後內建的會自動停止收集；要繼續用內建的，到 App 的設定 › 背景收集器，不用執行這個腳本"
fi

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

# Codex 同理：收集器執行 `codex app-server` 取得 Codex 用量（ADR-0007）。ChatGPT.app 也內附一份 codex。
# AUM_CODEX_FALLBACKS 只給測試用，換掉 PATH 以外的候選位置（這台 Mac 裝了 ChatGPT.app 也能測「找不到」）
CODEX=""
CODEX_FALLBACKS="${AUM_CODEX_FALLBACKS-/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
$HOME/.local/bin/codex
$HOME/.npm-global/bin/codex
/opt/homebrew/bin/codex
/usr/local/bin/codex}"
while IFS= read -r candidate; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then CODEX="$candidate"; break; fi
done <<< "$(command -v codex || true)
$CODEX_FALLBACKS"
if [ -n "$CODEX" ]; then
    "$PYTHON" "$COLLECTOR_DIR/scripts/update-config.py" "$CONFIG_DIR/config.json" codex_path "$CODEX"
fi

# Token 統計讀對話紀錄的資料夾（ADR-0009 第 3 節）：launchd 不會傳入 shell 的環境變數，
# 所以在這裡把 CLAUDE_CONFIG_DIR／CODEX_HOME 寫進 config.json；沒有設定時寫 null（用預設的 ~/.claude、~/.codex）
for pair in "claude_config_dir:${CLAUDE_CONFIG_DIR:-}" "codex_home:${CODEX_HOME:-}"; do
    key="${pair%%:*}"
    value="${pair#*:}"
    if [ -n "$value" ]; then
        "$PYTHON" "$COLLECTOR_DIR/scripts/update-config.py" "$CONFIG_DIR/config.json" "$key" "$value"
    else
        "$PYTHON" "$COLLECTOR_DIR/scripts/update-config.py" --json "$CONFIG_DIR/config.json" "$key" null
    fi
done

# 只收集這台 Mac 登入過的服務，沒用的服務不會在 App 上顯示成錯誤。
# 一個都沒偵測到時不寫入，收集器維持全部啟用，登入後不必重新安裝也能開始收集。
# 任何一個服務的登入狀態是「不知道」（裝過但找不到指令、輸出認不得）而不是「沒登入」時也不寫入，
# 不然原本啟用的服務會被悄悄關掉（收集器仍會每 5 分鐘記錄錯誤，例如「找不到 claude 執行檔」）。
RESULTS="$("$COLLECTOR_DIR/scripts/detect-providers.sh" "$CLAUDE" "$CODEX")"
DETECTED="$(printf '%s\n' "$RESULTS" | grep -v '^?' || true)"
UNKNOWN="$(printf '%s\n' "$RESULTS" | sed -n 's/^?//p')"
has_provider() { printf '%s\n' "$DETECTED" | grep -qx "$1"; }
is_unknown() { printf '%s\n' "$UNKNOWN" | grep -qx "$1"; }
if [ -n "$DETECTED" ] && [ -z "$UNKNOWN" ]; then
    ENABLED="$(printf '%s\n' "$DETECTED" | "$PYTHON" -c 'import json, sys; print(json.dumps(sys.stdin.read().split()))')"
    "$PYTHON" "$COLLECTOR_DIR/scripts/update-config.py" --json "$CONFIG_DIR/config.json" enabled_providers "$ENABLED"
fi

# 路徑可能含空白，用 | 當 sed 分隔字元
for pair in "$TEMPLATE|$TARGET|$LABEL" "$SYNC_TEMPLATE|$SYNC_TARGET|$SYNC_LABEL"; do
    IFS='|' read -r template target label <<< "$pair"
    sed -e "s|__PYTHON__|$PYTHON|" \
        -e "s|__COLLECTOR_DIR__|$COLLECTOR_DIR|" \
        -e "s|__LOG_DIR__|$LOG_DIR|g" \
        "$template" > "$target"
    plutil -lint "$target" >/dev/null
    # 已安裝過就先卸載再重新載入
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$target"
done

echo "已安裝：$TARGET"
echo "已安裝：${SYNC_TARGET}（AI 狀態同步，預設不上傳；set-tier2.sh --agent-sync 打開）"
if is_unknown claude; then
    echo
    echo "⚠️  找不到 claude 指令，無法取得 Claude 用量，也沒有更動 config.json 的 enabled_providers。"
    echo "   請把 claude 加進 PATH（或裝在 ~/.local/bin、/opt/homebrew/bin）後重新執行這個腳本。"
    echo
fi
if is_unknown codex; then
    echo
    if [ -z "$CODEX" ]; then
        echo "⚠️  找不到 codex 指令，無法取得 Codex 用量，也沒有更動 config.json 的 enabled_providers。"
        echo "   請安裝 Codex CLI（或 ChatGPT 桌面版）後重新執行這個腳本。"
    else
        echo "⚠️  無法判斷 Codex CLI 的登入狀態（codex login status 的結果認不得），沒有更動 config.json 的 enabled_providers。"
    fi
    echo
fi
if [ -z "$DETECTED" ] && [ -z "$UNKNOWN" ]; then
    echo
    echo "⚠️  沒有偵測到任何登入資訊。請先在終端機執行 claude 並 /login，或執行 codex login。"
    echo "   在那之前收集器會照常排程，但只會記錄「找不到登入資訊」；登入後下一次執行就會開始收集。"
    echo
else
    if is_unknown claude; then
        echo "Claude 用量：不確定（找不到 claude 指令，enabled_providers 維持原設定）"
    elif has_provider claude; then
        echo "Claude 用量：啟用（Claude Code 已登入）"
    elif [ -z "$CLAUDE" ]; then
        echo "Claude 用量：未啟用（沒有安裝 Claude Code）"
    else
        echo "Claude 用量：未啟用（Claude Code 沒有登入）"
    fi
    if is_unknown codex; then
        echo "Codex 用量：不確定（${CODEX:+無法判斷登入狀態}${CODEX:-找不到 codex 指令}，enabled_providers 維持原設定）"
    elif has_provider codex; then
        echo "Codex 用量：啟用（Codex CLI 已用 ChatGPT 登入）"
    elif [ -z "$CODEX" ]; then
        echo "Codex 用量：未啟用（沒有使用過 Codex CLI）"
    else
        echo "Codex 用量：未啟用（Codex CLI 沒有用 ChatGPT 登入）"
    fi
    echo "之後登入了另一個服務，重新執行這個腳本即可啟用。"
fi
echo "Python：$PYTHON"
if [ -z "$DETECTED" ] || has_provider claude; then
    echo "claude 指令：${CLAUDE:-找不到，無法取得 Claude 用量}"
fi
if [ -z "$DETECTED" ] || has_provider codex || is_unknown codex; then
    echo "codex 指令：${CODEX:-找不到，無法取得 Codex 用量}"
fi
echo "日誌：$LOG_DIR/collector.log"
echo "立即執行一次：launchctl kickstart gui/$(id -u)/$LABEL"
