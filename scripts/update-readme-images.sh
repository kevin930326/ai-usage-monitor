#!/bin/bash
# 重新產生 README 的截圖（docs/images/），依 docs/images/SOURCES.tsv 的來源與寬度。
#
#   scripts/update-readme-images.sh                       # Mac、iPhone、手錶
#   README_IMAGES_PLATFORMS=mac scripts/update-readme-images.sh   # 只更新 Mac 的
#
# - 與 scripts/snapshots.sh 相同的固定時間、時區、語系與假資料（scripts/make-demo-history.py，暫存資料夾），不讀真實資料。
# - Mac：Debug 版以 ImageRenderer 輸出（AUM_RENDER_DIR），統計切換的 GIF 是 AUM_RENDER_ANIMS=stats-tour。
# - iPhone：模擬器以示範模式（AUM_DEMO）輸出 Live Activity 與動態島（ImageRenderer），設定畫面是模擬器截圖
#   App 主畫面與設定畫面（AUM_DEMO_ACTION=settings：設定畫面一律顯示示範網址與假密鑰，不顯示模擬器裡存的設定）是模擬器截圖，
#   暫時切換模擬器的外觀與狀態列，結束後還原。
#   Live Activity 卡片與小工具不放：ImageRenderer 把 ProgressView 畫成黃色佔位符。手錶：模擬器截圖（示範模式）。
# - README_IMAGES_MAC_APP／README_IMAGES_IOS_APP／README_IMAGES_WATCH_APP：已建置的 Debug 版 .app；沒給就自己建置到 build/readme-images。
# - SOURCES.tsv 第 5 欄「後製」（可省略）：crop=<y>:<高>（裁切，原圖像素）、frame=<圓角半徑>（圓角與細邊框，縮放後的像素），
#   由 scripts/readme-image-post.swift 處理，順序固定為裁切 → 縮放（第 4 欄）→ 加框。
# - 畫面改變並以 scripts/update-snapshots.sh 更新基準後執行；scripts/check-readme-images.py 會提醒比基準舊的截圖。
# 執行後逐張檢查 git diff 中的圖再提交。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/ios-render-launch.sh
source "$ROOT/scripts/ios-render-launch.sh"
IMAGES=$ROOT/docs/images
SOURCES=$IMAGES/SOURCES.tsv
OUT=${README_IMAGES_OUT:-$ROOT/build/readme-images}
PLATFORMS=${README_IMAGES_PLATFORMS:-mac ios watch}
RENDER_NOW=2026-10-21T04:00:00Z
export TZ=Asia/Taipei
LANG_ARGS=(-AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW)
IOS_BUNDLE=io.github.kevin930326.AIUsageMonitor
WATCH_BUNDLE=io.github.kevin930326.AIUsageMonitor.watchkitapp

mkdir -p "$OUT"
touch "$ROOT/build/.metadata_never_index"  # 不讓 Spotlight 索引建置產物
WORK=$(mktemp -d)
CLEANUP=()
cleanup() {  # 後加的先做：先還原外觀與狀態列，最後才關模擬器
  local i
  for ((i = ${#CLEANUP[@]} - 1; i >= 0; i--)); do eval "${CLEANUP[$i]}" || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

build() {  # build <專案資料夾> <專案> <destination>
  (cd "$ROOT/apple/$1" && xcodegen generate --quiet)
  xcodebuild -project "$ROOT/apple/$1/$2.xcodeproj" -scheme "$2" -configuration Debug -destination "$3" \
    -derivedDataPath "$OUT/dd-$1" build >"$OUT/build-$1.log" 2>&1 || { grep error: "$OUT/build-$1.log" | head; exit 2; }
}

# 依名稱找模擬器（同名時用最新的 runtime），印出 UDID
find_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
found = [(rt, d["udid"]) for rt, ds in json.load(sys.stdin)["devices"].items() for d in ds if d["name"] == sys.argv[1]]
if found:
    print(max(found)[1])
' "$1"
}

boot() {  # boot <UDID>：沒開機就開，結束時再關掉
  if ! xcrun simctl list devices | grep -q "$1) (Booted)"; then
    xcrun simctl boot "$1"
    CLEANUP+=("xcrun simctl shutdown $1")
  fi
  xcrun simctl bootstatus "$1" -b >/dev/null
}

POST=$OUT/readme-image-post
if [ ! -x "$POST" ] || [ "$ROOT/scripts/readme-image-post.swift" -nt "$POST" ]; then
  swiftc -O "$ROOT/scripts/readme-image-post.swift" -o "$POST"
fi

# 依 SOURCES.tsv 把 <前綴>: 開頭的來源從 <資料夾> 複製到 docs/images，再裁切、縮放、加框
place() {  # place <前綴> <資料夾>
  local image src baseline width post missing=0
  while IFS=$'\t' read -r image src baseline width post; do
    case "$image" in ''|'#'*) continue ;; esac
    [ "${src%%:*}" = "$1" ] || continue
    local from=$2/${src#*:}
    case "$1" in ios-screen|watch-screen) from=$from.png ;; esac
    if [ ! -f "$from" ]; then echo "沒有產生 ${src}"; missing=1; continue; fi
    cp "$from" "$IMAGES/$image"
    local ops=""
    [ "$width" = - ] || ops="width=$width"
    [ "${post:--}" = - ] || ops="$ops $post"
    # shellcheck disable=SC2086  # ops 是以空白分隔的參數（crop=…、width=…、frame=…，本身不含空白）
    if [ -n "$ops" ]; then "$POST" "$IMAGES/$image" $ops; fi
    echo "  $image"
  done <"$SOURCES"
  [ "$missing" = 0 ] || exit 2
}

render_mac() {
  local app=${README_IMAGES_MAC_APP:-}
  if [ -z "$app" ]; then
    build MacMenuBar AIUsageMenuBar 'platform=macOS'
    app=$OUT/dd-MacMenuBar/Build/Products/Debug/AIUsageMenuBar.app
  fi
  AUM_RENDER_NOW=$RENDER_NOW python3 "$ROOT/scripts/make-demo-history.py" "$WORK/home" normal >/dev/null
  env AI_USAGE_MONITOR_HOME="$WORK/home" AUM_TESTING=1 AUM_DEMO_PANEL=1 AUM_RENDER_DIR="$WORK/mac" AUM_RENDER_EXIT=1 \
    AUM_RENDER_FRAMES=1 AUM_RENDER_ANIMS=stats-tour AUM_RENDER_NOW=$RENDER_NOW \
    perl -e 'alarm 600; exec @ARGV' "$app/Contents/MacOS/AIUsageMenuBar" "${LANG_ARGS[@]}" \
    >"$OUT/render-mac.log" 2>&1 || { echo "Mac 截圖失敗（$OUT/render-mac.log）"; exit 2; }
  echo "Mac："
  place mac "$WORK/mac"
}

render_ios() {
  local app=${README_IMAGES_IOS_APP:-}
  if [ -z "$app" ]; then
    build iOSApp AIUsageMonitor 'generic/platform=iOS Simulator'
    app=$OUT/dd-iOSApp/Build/Products/Debug-iphonesimulator/AIUsageMonitor.app
  fi
  local name udid docs
  name=$(sed -n 's/^simulator=//p' "$ROOT/apple/Snapshots/ios/ENVIRONMENT" | sed 's/ iOS-.*//')
  name=${README_IMAGES_SIMULATOR:-${name:-iPhone 18 Pro}}
  udid=$(find_simulator "$name")
  [ -n "$udid" ] || { echo "找不到模擬器「${name}」（README_IMAGES_SIMULATOR 可指定）"; exit 2; }
  boot "$udid"
  xcrun simctl install "$udid" "$app"
  docs=$(xcrun simctl get_app_container "$udid" "$IOS_BUNDLE" data)/Documents
  mkdir -p "$docs"
  rm -f "$docs"/*.png "$docs/island-sizes.json"
  # 剛開機後的第一次啟動常常不出畫面，launch_ios_render 會重新啟動一次（scripts/ios-render-launch.sh）
  SIMCTL_CHILD_AUM_RENDER=1 SIMCTL_CHILD_AUM_DEMO=normal SIMCTL_CHILD_AUM_RENDER_NOW=$RENDER_NOW SIMCTL_CHILD_TZ=$TZ \
    launch_ios_render "$udid" "$IOS_BUNDLE" "$docs" "${LANG_ARGS[@]}" || true
  [ -f "$docs/island-sizes.json" ] || { echo "iOS 截圖逾時"; exit 2; }
  mkdir -p "$WORK/ios"
  cp "$docs"/*.png "$WORK/ios/"

  # 設定畫面：模擬器的外觀與狀態列暫時改掉，結束後還原
  local original
  original=$(xcrun simctl ui "$udid" appearance)
  CLEANUP+=("xcrun simctl ui $udid appearance $original" "xcrun simctl status_bar $udid clear")
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
  for scheme in light dark; do
    xcrun simctl ui "$udid" appearance "$scheme"
    for screen in home settings; do
      local action=
      [ "$screen" = settings ] && action=settings
      # 不固定時間：App 畫面有些地方用真實時間，固定成過去的時間會全部變成「已重置」。示範資料以啟動當下產生
      SIMCTL_CHILD_AUM_DEMO=normal SIMCTL_CHILD_AUM_DEMO_ACTION=$action SIMCTL_CHILD_TZ=$TZ \
        xcrun simctl launch --terminate-running-process "$udid" "$IOS_BUNDLE" "${LANG_ARGS[@]}" >/dev/null
      sleep 6  # 等畫面的出現動畫結束
      xcrun simctl io "$udid" screenshot --type=png "$WORK/ios/$screen-$scheme.png" >/dev/null 2>&1
    done
  done
  xcrun simctl terminate "$udid" "$IOS_BUNDLE" 2>/dev/null || true
  echo "iPhone："
  place ios "$WORK/ios"
  place ios-screen "$WORK/ios"
}

render_watch() {
  local app=${README_IMAGES_WATCH_APP:-}
  if [ -z "$app" ]; then
    build WatchApp AIUsageWatch 'generic/platform=watchOS Simulator'
    app=$OUT/dd-WatchApp/Build/Products/Debug-watchsimulator/AIUsageWatch.app
  fi
  local name=${README_IMAGES_WATCH_SIMULATOR:-Apple Watch Series 12 (46mm)} udid
  udid=$(find_simulator "$name")
  [ -n "$udid" ] || { echo "找不到模擬器「${name}」（README_IMAGES_WATCH_SIMULATOR 可指定）"; exit 2; }
  boot "$udid"
  xcrun simctl install "$udid" "$app"
  CLEANUP+=("xcrun simctl status_bar $udid clear >/dev/null 2>&1")
  xcrun simctl status_bar "$udid" override --time 9:41 >/dev/null 2>&1 || true  # watchOS 不支援時略過
  SIMCTL_CHILD_AUM_DEMO=normal SIMCTL_CHILD_TZ=$TZ \
    xcrun simctl launch --terminate-running-process "$udid" "$WATCH_BUNDLE" "${LANG_ARGS[@]}" >/dev/null
  sleep 6
  mkdir -p "$WORK/watch"
  xcrun simctl io "$udid" screenshot --type=png "$WORK/watch/app.png" >/dev/null 2>&1
  xcrun simctl terminate "$udid" "$WATCH_BUNDLE" 2>/dev/null || true
  echo "手錶："
  place watch-screen "$WORK/watch"
}

for platform in $PLATFORMS; do "render_$platform"; done
echo "已更新 docs/images/。逐張檢查 git diff 中的圖再提交。"
