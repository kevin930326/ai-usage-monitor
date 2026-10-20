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
python3 -c 'import json,sys; json.dump({"relay_url": sys.argv[1].rstrip("/")}, open(sys.argv[2], "w"), indent=2)' \
    "$1" "$CONFIG_DIR/config.json"
echo "已寫入：$CONFIG_DIR/config.json"

# -w 放最後且不給值，security 會提示輸入，密鑰不會留在 shell 歷史紀錄
echo "請貼上中繼的寫入密鑰（WRITE_TOKEN）："
security add-generic-password -U -s "AIUsageMonitor-relay-write" -a "default" -w
echo "已存入 Keychain：AIUsageMonitor-relay-write"
