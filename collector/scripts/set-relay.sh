#!/bin/bash
# 設定中繼 API：網址寫入 config.json，寫入密鑰存進 macOS Keychain
# 用法：scripts/set-relay.sh https://ai-usage-relay.<你的帳號>.workers.dev
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "用法：$0 <relay_url>" >&2
    exit 1
fi

CONFIG_DIR="${AI_USAGE_MONITOR_HOME:-$HOME/Library/Application Support/AIUsageMonitor}"
mkdir -p "$CONFIG_DIR"
# 合併寫入，保留安裝腳本寫的 claude_path 等其他設定
python3 "$(dirname "$0")/update-config.py" "$CONFIG_DIR/config.json" relay_url "${1%/}"
echo "已寫入：$CONFIG_DIR/config.json"

# -w 放最後且不給值，security 會提示輸入，密鑰不會留在 shell 歷史紀錄
echo "請貼上中繼的寫入密鑰（WRITE_TOKEN）："
security add-generic-password -U -s "AIUsageMonitor-relay-write" -a "default" -w
echo "已存入 Keychain：AIUsageMonitor-relay-write"
