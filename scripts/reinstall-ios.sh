#!/bin/bash
# 重新簽署並透過網路把 iOS App 安裝到 iPhone。
# 免費 Apple ID（Personal Team）簽署的 App 7 天後失效。launchd 每 20 分鐘呼叫一次 --if-due
# （見 scripts/install-reinstall-launchd.sh），由 reinstall_ios_helper.py plan 決定要不要裝：
#   - 未滿 6 天：不做事
#   - 滿 6 天：只在捷徑自動化前的時段（SHORTCUT_TIMES 前 25～5 分鐘）安裝，裝完不打開 App，
#     重新安裝結束的鎖定畫面卡片由接著執行的捷徑「重新啟動用量監看」開回來
#   - 滿 6.5 天（快到期）或從未成功：不挑時間，裝完打開 App 把卡片開回來
#
#   scripts/reinstall-ios.sh            # 立即建置並安裝，裝完打開 App
#   scripts/reinstall-ios.sh --if-due   # launchd 用
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
# launchd 經由 reinstall_ios_helper.py scheduled 執行時，AUM_PYTHON 是 plist 指定的 Python（與收集器相同）；
# 全程沿用它，不再依 PATH 找 python3（launchd 的 PATH 不一定含那個資料夾）
PYTHON="${AUM_PYTHON:-python3}"
HELPER=("$PYTHON" "$REPO/scripts/reinstall_ios_helper.py")
UPDATE_CONFIG=("$PYTHON" "$REPO/collector/scripts/update-config.py" "$CONFIG")
INTERVAL_DAYS=6
OVERDUE_DAYS=6.5
# 要與 iPhone 捷徑 App 的定時自動化相同（apple/iOSApp/README.md「捷徑：讓卡片整天顯示」）
SHORTCUT_TIMES="07:00,15:00,23:00"
LEAD_MINUTES=25    # 時段從捷徑前 25 分鐘開始
WINDOW_MINUTES=20  # 寬 20 分鐘，與檢查間隔相同，Mac 醒著時每個時段剛好檢查一次；留 5 分鐘給建置與安裝
NOTIFY_AFTER_HOURS=24
TITLE="AI 用量"
BUNDLE_ID="io.github.kevin930326.AIUsageMonitor"

mkdir -p "$LOG_DIR" "$CONFIG_DIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"; echo "$*"; }
notify() {  # 用參數傳文字，避免引號被當成 AppleScript
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
              -e 'end run' "$1" "$TITLE" >/dev/null 2>&1 || true
}
config_get() {
    "$PYTHON" -c 'import json,sys
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

MODE=manual
if [ "${1:-}" = "--if-due" ]; then
    PLAN=$("${HELPER[@]}" plan "$STATE" "$INTERVAL_DAYS" "$OVERDUE_DAYS" "$SHORTCUT_TIMES" \
        "$LEAD_MINUTES" "$WINDOW_MINUTES") || exit 4
    MODE=${PLAN%%$'\t'*}
    [ "$MODE" = skip ] && exit 0
    NEXT_SHORTCUT=${PLAN##*$'\t'}
fi

# 同時只跑一個（手動與 launchd 可能重疊）。鎖是資料夾，裡面記 PID。
# kill -9、當機或斷電時 EXIT trap 不會執行，鎖會留下來：持有的程序已不存在、
# 舊版腳本留下沒有 PID 的鎖，或超過最長執行時間（PID 可能已被重用）時視為殘留，接手後繼續。
LOCK="$CONFIG_DIR/.reinstall.lock"
LOCK_MAX_MINUTES=120  # 建置數分鐘、安裝最多 5 分鐘，遠低於此
lock_is_stale() {  # lock_is_stale <鎖內的 PID，可能為空>
    if [ -z "$1" ]; then
        # 剛建立、還沒寫入 PID 的鎖不算；沒有 PID 超過 1 分鐘就是殘留
        [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]
        return
    fi
    ! kill -0 "$1" 2>/dev/null || [ -n "$(find "$LOCK/pid" -mmin +"$LOCK_MAX_MINUTES" 2>/dev/null)" ]
}
acquire_lock() {
    if mkdir "$LOCK" 2>/dev/null; then
        echo $$ >"$LOCK/pid"
        return 0
    fi
    local pid stale
    pid=$(cat "$LOCK/pid" 2>/dev/null)
    lock_is_stale "$pid" || return 1
    # 先改名再刪，兩個程序同時接手時只有一個改名成功；改到的若已不是剛才看到的鎖就放回去。
    # 放回時以 mkdir 重建鎖再搬 pid（mv 到已存在的資料夾會搬進它裡面）；這段時間又有人建立了鎖
    # 而放不回去時，保留改名後的資料夾、不刪：它是別人正在用的鎖
    stale="$LOCK.stale.$$"
    mv "$LOCK" "$stale" 2>/dev/null || return 1
    if [ "$(cat "$stale/pid" 2>/dev/null)" != "$pid" ]; then
        if mkdir "$LOCK" 2>/dev/null && mv "$stale/pid" "$LOCK/pid" 2>/dev/null; then
            rmdir "$stale" 2>/dev/null
        else
            log "無法放回鎖，保留為 ${stale##*/}"
        fi
        return 1
    fi
    rm -rf "$stale"
    log "清除殘留的鎖（PID ${pid:-未記錄}）"
    mkdir "$LOCK" 2>/dev/null || return 1
    echo $$ >"$LOCK/pid"
}
if ! acquire_lock; then
    echo "另一個重新安裝正在執行（${LOCK}）" >&2
    exit 0
fi
trap 'rm -rf "$LOCK"' EXIT

log "開始重新安裝（${MODE}，$REPO @ $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)）"

# 1. Team ID：config.json 優先，沒有就偵測後寫入
TEAM=$(config_get development_team)
if [ -z "$TEAM" ]; then
    TEAM=$("${HELPER[@]}" team 2>>"$LOG") || fail 4 "偵測不到 Team ID"
    "${UPDATE_CONFIG[@]}" development_team "$TEAM" || fail 4 "無法寫入 config.json"
    log "偵測到 Team ID 並寫入 config.json"
fi

# 2. iPhone：config.json 優先；沒有時若只連過一台 iPhone 就寫入
DEVICES_JSON=$(mktemp)
trap 'rm -rf "$LOCK"; rm -f "$DEVICES_JSON"' EXIT
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
DEVICE=$(grep "^$UDID"$'\t' <<<"$IPHONES") || fail 2 "devicectl 清單中沒有 config.json 的 iPhone（${UDID}）"
log "iPhone：$(cut -f2 <<<"$DEVICE")，連線方式 $(cut -f3 <<<"$DEVICE")"

# 3. 產生專案並建置（Release：不含示範模式與截圖工具）
cd "$REPO/apple/iOSApp" || fail 1 "找不到 apple/iOSApp"
DEVELOPMENT_TEAM="$TEAM" xcodegen generate --quiet >>"$BUILD_LOG" 2>&1 || fail 1 "xcodegen generate 失敗"
log "建置中（完整輸出：${BUILD_LOG}）"
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
log "安裝成功，簽署約在 ${EXPIRES} 到期"

# 5. 重新安裝會結束鎖定畫面的 Live Activity。
#    捷徑前的時段：幾分鐘後的捷徑自動化會把卡片開回來，不打開 App 以免打擾。
#    其他情況：打開 App 並帶參數，讓 App 在前景把卡片開回來。手機鎖定時打不開；
#    簽署已經更新，仍算成功，卡片等下一次捷徑自動化重開。
if [ "$MODE" = window ]; then
    log "鎖定畫面卡片會由 ${NEXT_SHORTCUT} 的捷徑自動化開回來"
    notify "已重新安裝 iPhone App（簽署約在 ${EXPIRES} 到期），鎖定畫面卡片會在 ${NEXT_SHORTCUT} 回來"
elif xcrun devicectl device process launch --device "$UDID" --terminate-existing --timeout 60 \
        "$BUNDLE_ID" -- --start-live-activity >>"$LOG" 2>&1; then
    log "已打開 App 並重開鎖定畫面卡片"
    notify "已重新安裝 iPhone App，簽署約在 ${EXPIRES} 到期"
else
    log "無法打開 App（手機可能鎖定），鎖定畫面卡片要等捷徑自動化或手動打開 App 才會出現"
    notify "已重新安裝 iPhone App（簽署約在 ${EXPIRES} 到期），但手機鎖定中，請打開 App 重開鎖定畫面卡片"
fi
exit 0
