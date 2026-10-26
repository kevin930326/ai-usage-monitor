#!/bin/bash
# 第二層（多裝置 Token 合併，ADR-0011 第 2 節、docs/tier2-setup.md）：在這台 Mac 開啟或關閉上傳。
#
#   collector/scripts/set-tier2.sh               存入這台 Mac 的寫入密鑰與中繼的讀取密鑰，開啟上傳
#   collector/scripts/set-tier2.sh --no-read-key 只存寫入密鑰（只上傳；移除之前存的讀取密鑰，面板不顯示其他電腦）
#   collector/scripts/set-tier2.sh --disable     關閉上傳與下載（密鑰留在 Keychain；刪除本機的其他電腦資料）
#
# 先用 scripts/relay-device.sh add <名稱> 為這台 Mac 產生寫入密鑰；中繼網址用 set-relay.sh 設定過的 relay_url。
# 密鑰以不顯示的提示輸入，先檢查格式（去掉前後空白與換行；寫入密鑰要 aumd_ 開頭、48 字元），不對就重新提示；
# 再經 security -i 的標準輸入存進 Keychain（不經過指令列、不留在 shell 歷史紀錄、不寫檔）。
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

# 讀入一把密鑰、檢查格式後存進 Keychain：$1＝credentials 的名稱、$2＝Keychain service、$3＝提示。
# 密鑰只在這個 shell 的變數與 printf（內建指令）的輸出裡，不會出現在任何程序的參數（ps 看不到）
store_key() {
    local name=$1 service=$2 prompt=$3 raw key tries=0
    while :; do
        echo "$prompt"
        IFS= read -rs raw || raw=""
        [ -t 0 ] && echo
        if key=$(printf '%s\n' "$raw" | (cd "$COLLECTOR" && python3 -m usage_collector.credentials check "$name")); then
            break
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 3 ]; then
            echo "沒有存入密鑰（格式不對）。" >&2
            exit 1
        fi
        echo "請重新貼上。" >&2
    done
    # security -i 從標準輸入讀指令；check 已確認密鑰只有英數與 + / = _ . ~ -，不必處理引號
    printf 'add-generic-password -U -s %s -a default -w %s\n' "$service" "$key" | security -i >/dev/null
    # security -i 的結束碼不反映指令是否成功：讀回來確認（不加 -w，不印出密鑰）
    if ! security find-generic-password -s "$service" -a default >/dev/null 2>&1; then
        echo "無法存入 Keychain（${service}）。" >&2
        exit 1
    fi
}

store_key device-key AIUsageMonitor-device-key "請貼上這台 Mac 的寫入密鑰（scripts/relay-device.sh add 印出的 aumd_…，不會顯示）："
if [ "$READ_KEY" = 1 ]; then
    store_key relay-read AIUsageMonitor-relay-read "請貼上中繼的讀取密鑰（READ_TOKEN，和 iPhone App 用的相同，不會顯示）："
else
    # 只上傳：之前存過的讀取密鑰也要移除，收集器才不會繼續下載（沒有這個項目時忽略）
    security delete-generic-password -s "AIUsageMonitor-relay-read" -a "default" >/dev/null 2>&1 || true
fi

python3 "$COLLECTOR/scripts/update-config.py" --json "$CONFIG" token_sync true
# 清除「密鑰失效」等狀態，下一輪立即上傳
(cd "$COLLECTOR" && python3 -m usage_collector.token_sync reset)
if [ "$READ_KEY" = 0 ]; then
    (cd "$COLLECTOR" && python3 -m usage_collector.token_sync forget)  # 面板回到「這台 Mac」
fi
echo "已開啟第二層。收集器下一輪（5 分鐘內）上傳；確認：(cd collector && python3 -m usage_collector.token_sync status)"
