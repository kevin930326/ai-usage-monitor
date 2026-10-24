#!/bin/bash
# 第二層（多裝置 Token 合併，ADR-0011 第 2 節、docs/tier2-setup.md）：在這台 Mac 開啟或關閉上傳。
#
#   collector/scripts/set-tier2.sh               存入這台 Mac 的寫入密鑰與中繼的讀取密鑰，開啟上傳
#   collector/scripts/set-tier2.sh --no-read-key 只存寫入密鑰（只上傳，面板不顯示其他電腦）
#   collector/scripts/set-tier2.sh --disable     關閉上傳與下載（密鑰留在 Keychain；刪除本機的其他電腦資料）
#
# 先用 scripts/relay-device.sh add <名稱> 為這台 Mac 產生寫入密鑰；中繼網址用 set-relay.sh 設定過的 relay_url。
# 密鑰以 security 的提示輸入（不經過指令列、不留在 shell 歷史紀錄），只存在 Keychain。
set -euo pipefail

READ_KEY=1
case "${1:-}" in
    "") ;;
    --no-read-key) READ_KEY=0 ;;
    --disable) READ_KEY=-1 ;;
    *) sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

COLLECTOR=$(cd "$(dirname "$0")/.." && pwd)
CONFIG_DIR="${AI_USAGE_MONITOR_HOME:-$HOME/Library/Application Support/AIUsageMonitor}"
CONFIG="$CONFIG_DIR/config.json"

if [ "$READ_KEY" = -1 ]; then
    python3 "$COLLECTOR/scripts/update-config.py" --json "$CONFIG" token_sync false
    # 面板回到「這台 Mac」：刪除本機的其他電腦資料（中繼上的資料不動）
    (cd "$COLLECTOR" && python3 -m usage_collector.token_sync forget)
    echo "已關閉第二層：不再上傳與下載（Keychain 的密鑰保留；要移除：security delete-generic-password -s AIUsageMonitor-device-key）"
    exit 0
fi

URL=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("relay_url") or "")
except (OSError, ValueError):
    print("")' "$CONFIG")
case "$URL" in
    https://*) ;;
    *) echo "config.json 沒有 https:// 的 relay_url：先執行 collector/scripts/set-relay.sh <網址>" >&2; exit 1 ;;
esac

echo "請貼上這台 Mac 的寫入密鑰（scripts/relay-device.sh add 印出的 aumd_…）："
security add-generic-password -U -s "AIUsageMonitor-device-key" -a "default" -w
if [ "$READ_KEY" = 1 ]; then
    echo "請貼上中繼的讀取密鑰（READ_TOKEN，和 iPhone App 用的相同）："
    security add-generic-password -U -s "AIUsageMonitor-relay-read" -a "default" -w
fi

python3 "$COLLECTOR/scripts/update-config.py" --json "$CONFIG" token_sync true
# 清除「密鑰失效」等狀態，下一輪立即上傳
(cd "$COLLECTOR" && python3 -m usage_collector.token_sync reset)
echo "已開啟第二層。收集器下一輪（5 分鐘內）上傳；確認：(cd collector && python3 -m usage_collector.token_sync status)"
