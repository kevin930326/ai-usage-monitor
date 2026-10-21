#!/bin/bash
# 重新簽署並透過網路把 iOS App 安裝到 iPhone。
# 免費 Apple ID（Personal Team）簽署的 App 7 天後失效，launchd 每 6 天執行一次（見 scripts/install-reinstall-launchd.sh）。
#
#   scripts/reinstall-ios.sh            # 立即建置並安裝
#   scripts/reinstall-ios.sh --if-due   # launchd 用：距上次成功未滿 6 天就不做事
#
# 簽署使用 Xcode 已登入的 Apple ID（-allowProvisioningUpdates），腳本內不放任何帳號或密碼。
# Team ID 與 iPhone UDID 存在 config.json（不進版控）：
#   ~/Library/Application Support/AIUsageMonitor/config.json 的 development_team、iphone_udid
#
# 結束碼：0 成功或還不需要、1 建置失敗、2 找不到手機、3 安裝失敗、4 設定錯誤（Team、多台手機）
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$HOME/Library/Application Support/AIUsageMonitor"
CONFIG="$CONFIG_DIR/config.json"
STATE="$CONFIG_DIR/reinstall-state.json"
LOG_DIR="$HOME/Library/Logs/AIUsageMonitor"
LOG="$LOG_DIR/reinstall.log"
BUILD_LOG="$LOG_DIR/reinstall-build.log"
DERIVED="$HOME/Library/Caches/AIUsageMonitor/DerivedData"
HELPER=(python3 "$REPO/scripts/reinstall_ios_helper.py")
UPDATE_CONFIG=(python3 "$REPO/collector/scripts/update-config.py" "$CONFIG")
INTERVAL_DAYS=6
NOTIFY_AFTER_HOURS=24
TITLE="AI 用量"

mkdir -p "$LOG_DIR" "$CONFIG_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"; echo "$*"; }
notify() {  # 用參數傳文字，避免引號被當成 AppleScript
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
              -e 'end run' "$1" "$TITLE" >/dev/null 2>&1 || true
}
config_get() {
    python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")
except (FileNotFoundError, ValueError): print("")' "$CONFIG" "$1"
}
fail() {  # fail <結束碼> <訊息>
    log "失敗：$2"
    local line
    line=$("${HELPER[@]}" failure "$STATE" "$NOTIFY_AFTER_HOURS")
    if [[ $line == notify* ]]; then
        notify "iPhone App 已連續 ${line##*$'\t'} 小時無法重新安裝：$2"
        log "已發送失敗通知"
    fi
    exit "$1"
}

if [ "${1:-}" = "--if-due" ] && ! "${HELPER[@]}" due "$STATE" "$INTERVAL_DAYS"; then
    exit 0
fi

# 同時只跑一個（手動與 launchd 可能重疊）
LOCK="$CONFIG_DIR/.reinstall.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "另一個重新安裝正在執行（$LOCK）" >&2
    exit 0
fi
trap 'rmdir "$LOCK"' EXIT

log "開始重新安裝（$REPO @ $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)）"

# 1. Team ID：config.json 優先，沒有就偵測後寫入
TEAM=$(config_get development_team)
if [ -z "$TEAM" ]; then
    TEAM=$("${HELPER[@]}" team 2>>"$LOG") || fail 4 "偵測不到 Team ID"
    "${UPDATE_CONFIG[@]}" development_team "$TEAM" || fail 4 "無法寫入 config.json"
    log "偵測到 Team ID 並寫入 config.json"
fi

# 2. iPhone：config.json 優先；沒有時若只連過一台 iPhone 就寫入
DEVICES_JSON=$(mktemp)
trap 'rmdir "$LOCK"; rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --timeout 60 --json-output "$DEVICES_JSON" >/dev/null 2>>"$LOG" \
    || fail 2 "devicectl 無法列出裝置"
IPHONES=$("${HELPER[@]}" iphones "$DEVICES_JSON")
UDID=$(config_get iphone_udid)
if [ -z "$UDID" ]; then
    count=$(printf '%s' "$IPHONES" | grep -c . || true)
    if [ "$count" -eq 0 ]; then fail 2 "找不到 iPhone，請先用 Xcode 連線並信任這台 Mac"; fi
    if [ "$count" -gt 1 ]; then fail 4 "有 $count 台 iPhone，請把要用的 UDID 寫進 config.json 的 iphone_udid"; fi
    UDID=$(cut -f1 <<<"$IPHONES")
    "${UPDATE_CONFIG[@]}" iphone_udid "$UDID" || fail 4 "無法寫入 config.json"
    log "找到 iPhone（$(cut -f2 <<<"$IPHONES")）並寫入 config.json"
fi
DEVICE=$(grep "^$UDID"$'\t' <<<"$IPHONES") || fail 2 "devicectl 清單中沒有 config.json 的 iPhone（$UDID）"
log "iPhone：$(cut -f2 <<<"$DEVICE")，連線方式 $(cut -f3 <<<"$DEVICE")"

# 3. 產生專案並建置（Release：不含示範模式與截圖工具）
cd "$REPO/apple/iOSApp" || fail 1 "找不到 apple/iOSApp"
DEVELOPMENT_TEAM="$TEAM" xcodegen generate --quiet >>"$BUILD_LOG" 2>&1 || fail 1 "xcodegen generate 失敗"
log "建置中（完整輸出：$BUILD_LOG）"
xcodebuild -project AIUsageMonitor.xcodeproj -scheme AIUsageMonitor -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" build >"$BUILD_LOG" 2>&1 \
    || fail 1 "建置失敗（見 $BUILD_LOG 結尾）"
APP="$DERIVED/Build/Products/Release-iphoneos/AIUsageMonitor.app"
[ -d "$APP" ] || fail 1 "找不到建置結果 $APP"

# 4. 透過網路安裝（手機要醒著、與 Mac 在同一個網路）
if ! xcrun devicectl device install app --device "$UDID" --timeout 300 "$APP" >>"$LOG" 2>&1; then
    fail 3 "安裝失敗：手機可能鎖定、休眠或不在同一個網路"
fi

"${HELPER[@]}" success "$STATE"
EXPIRES=$(date -v+7d '+%m/%d')
log "安裝成功，簽署約在 $EXPIRES 到期"
notify "已重新安裝 iPhone App，簽署約在 $EXPIRES 到期"
exit 0
