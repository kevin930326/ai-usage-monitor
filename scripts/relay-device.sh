#!/bin/bash
# 第二層的裝置管理（ADR-0011 第 2 節、docs/tier2-setup.md）：每台電腦一把寫入密鑰，可單獨撤銷。
#
#   scripts/relay-device.sh add <名稱>                 新增裝置，印出一次它的寫入密鑰（中繼只存雜湊）
#   scripts/relay-device.sh list                        列出裝置與最後上傳時間
#   scripts/relay-device.sh rotate <device_id>          換新密鑰（舊的立即失效，資料與 device_id 不變）
#   scripts/relay-device.sh revoke <device_id> [--delete-data]   撤銷；加 --delete-data 一併刪除它的資料
#
# 中繼網址：--url <網址>、環境變數 AUM_RELAY_URL，或 config.json 的 relay_url（scripts/set-relay.sh 寫入的）。
# 管理密鑰（中繼的 ADMIN_TOKEN）：環境變數 AUM_ADMIN_TOKEN，沒有就提示輸入；不寫進任何檔案，
# 以標準輸入交給 curl（不出現在指令列，ps 看不到）。
set -euo pipefail

usage() {
    sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

URL=${AUM_RELAY_URL:-}
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --url) [ $# -ge 2 ] || usage; URL=$2; shift 2 ;;
        --url=*) URL=${1#--url=}; shift ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
[ ${#ARGS[@]} -ge 1 ] || usage
COMMAND=${ARGS[0]}

if [ -z "$URL" ]; then
    CONFIG="${AI_USAGE_MONITOR_HOME:-$HOME/Library/Application Support/AIUsageMonitor}/config.json"
    URL=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("relay_url") or "")
except (OSError, ValueError):
    print("")' "$CONFIG")
fi
URL=${URL%/}
case "$URL" in
    https://*) ;;
    http://localhost*|http://127.0.0.1*) ;;  # wrangler dev
    "") echo "找不到中繼網址：加上 --url，或先執行 collector/scripts/set-relay.sh" >&2; exit 2 ;;
    *) echo "中繼網址必須是 https://（避免管理密鑰以明文傳送）" >&2; exit 2 ;;
esac

DEVICE_ID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
METHOD=
REQUEST_PATH=
BODY=
case "$COMMAND" in
    add)
        [ ${#ARGS[@]} -eq 2 ] || usage
        METHOD=POST REQUEST_PATH=/devices
        BODY=$(python3 -c 'import json, sys; print(json.dumps({"name": sys.argv[1]}, ensure_ascii=False))' "${ARGS[1]}")
        ;;
    list)
        [ ${#ARGS[@]} -eq 1 ] || usage
        METHOD=GET REQUEST_PATH=/devices
        ;;
    rotate|revoke)
        [ ${#ARGS[@]} -ge 2 ] || usage
        [[ ${ARGS[1]} =~ $DEVICE_ID_RE ]] || { echo "device_id 格式不對（用 list 查）" >&2; exit 2; }
        METHOD=POST REQUEST_PATH="/devices/${ARGS[1]}/$COMMAND" BODY='{}'
        if [ "$COMMAND" = revoke ]; then
            case "${ARGS[2]:-}" in
                "") ;;
                --delete-data) BODY='{"delete_data": true}' ;;
                *) usage ;;
            esac
            [ ${#ARGS[@]} -le 3 ] || usage
        else
            [ ${#ARGS[@]} -eq 2 ] || usage
        fi
        ;;
    *) usage ;;
esac

TOKEN=${AUM_ADMIN_TOKEN:-}
if [ -z "$TOKEN" ]; then
    printf '中繼的管理密鑰（ADMIN_TOKEN）：' >&2
    IFS= read -rs TOKEN
    echo >&2
fi
[ -n "$TOKEN" ] || { echo "沒有管理密鑰" >&2; exit 2; }

RESPONSE=$(mktemp)
trap 'rm -f "$RESPONSE"' EXIT
CURL_ARGS=(-sS --max-time 30 -o "$RESPONSE" -w '%{http_code}' -X "$METHOD" -H @- "$URL$REQUEST_PATH")
if [ -n "$BODY" ]; then
    CURL_ARGS+=(-H "Content-Type: application/json" --data-binary "$BODY")
fi
STATUS=$(printf 'Authorization: Bearer %s\n' "$TOKEN" | curl "${CURL_ARGS[@]}") || {
    echo "連不上中繼（$URL）" >&2
    exit 1
}

python3 - "$COMMAND" "$STATUS" "$RESPONSE" <<'PY'
import json
import sys

command, status, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    data = {}
if status >= 300:
    reason = data.get("error") if isinstance(data, dict) else None
    hint = {401: "管理密鑰不對", 503: "中繼還沒設定第二層（D1 綁定或 ADMIN_TOKEN）", 404: "找不到"}.get(status, "")
    print(f"失敗（HTTP {status}）：{reason or hint}", file=sys.stderr)
    sys.exit(1)
if command == "list":
    devices = data.get("devices", [])
    if not devices:
        print("還沒有裝置")
    for d in devices:
        state = "已撤銷" if d.get("revoked") else "使用中"
        print(f"{d['device_id']}  {d['name']}  {state}  最後上傳：{d.get('last_upload_at') or '尚未上傳'}")
elif command in ("add", "rotate"):
    print(f"裝置：{data.get('name', '')}（{data['device_id']}）")
    print("寫入密鑰（只顯示這一次，中繼只存雜湊；遺失時用 rotate 換新的）：")
    print(data["key"])
    print("在那台電腦上執行設定（docs/tier2-setup.md）：Mac 用 collector/scripts/set-tier2.sh，PC 用 windows\\set-tier2.ps1")
else:
    print(f"已撤銷：{data['device_id']}" + ("，資料已刪除" if data.get("deleted_data") else "（資料保留）"))
PY
