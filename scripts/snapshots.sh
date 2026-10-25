#!/bin/bash
# 截圖比對：用 ImageRenderer 產生 Mac 面板、完整統計、設定、選單列圖示、第二層統計卡片（撤銷的電腦），以及 iPhone 小工具、
# 鎖定畫面 Live Activity、動態島（淺色、深色），和 apple/Snapshots/ 的基準比對，容許小誤差。
#
#   scripts/snapshots.sh                     # 比對（verify-all 會跑）
#   scripts/update-snapshots.sh              # 畫面有意改變時：重新產生基準（等於 snapshots.sh --update）
#   SNAPSHOT_PLATFORMS=mac scripts/snapshots.sh   # 只比 Mac（CI）
#
# - SNAPSHOT_MAC_APP／SNAPSHOT_IOS_APP：已建置的 Debug 版 .app（verify-all 傳入）；沒給就自己建置到 build/snapshots。
# - 固定時間（AUM_RENDER_NOW）、時區（Asia/Taipei）與語系，假資料用 scripts/make-demo-history.py 產生在暫存資料夾，
#   不讀真實資料。iOS 在模擬器以示範模式（AUM_DEMO）啟動，不連線中繼。
# - 字型與系統元件會隨 macOS、Xcode 與模擬器版本改變：某個平台的環境和它的基準（apple/Snapshots/<平台>/ENVIRONMENT）
#   不同時，該平台的畫面差異只印警告、不算失敗（SNAPSHOT_STRICT=1 時仍算失敗）；缺圖或讀不到圖一律失敗。
# - SNAPSHOT_FROM=<資料夾>：測試用，不產生截圖，改用 <資料夾>/<平台>/ 下現成的圖。
# - 不符時差異圖在 build/snapshots/diff/<平台>/（不同的像素標紅）。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/ios-render-launch.sh
source "$ROOT/scripts/ios-render-launch.sh"
BASE=$ROOT/apple/Snapshots
OUT=${SNAPSHOT_OUT:-$ROOT/build/snapshots}
MODE=compare
[ "${1:-}" = --update ] && MODE=update
PLATFORMS=${SNAPSHOT_PLATFORMS:-mac ios}
RENDER_NOW=2026-10-21T04:00:00Z
export TZ=Asia/Taipei
LANG_ARGS=(-AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW)
MAC_SET=(panel-light panel-dark stats-window-light stats-window-dark settings-light settings-dark
         menubar-icons-light menubar-icons-dark wizard-light wizard-dark
         tier2-card-revoked-device-light tier2-card-revoked-device-dark tier2-card-deleted-device-light tier2-card-deleted-device-dark)
IOS_SET=(widget-small-light widget-small-dark widget-medium-light widget-medium-dark widget-large-light widget-large-dark
         live-activity-light live-activity-dark island-normal)
IOS_BUNDLE=io.github.kevin930326.AIUsageMonitor

mkdir -p "$OUT"
touch "$ROOT/build/.metadata_never_index"  # 不讓 Spotlight 索引建置產物
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 基準記錄的產生環境（各平台一份：apple/Snapshots/<平台>/ENVIRONMENT，key=value）
baseline_env() { [ -f "$BASE/$1/ENVIRONMENT" ] && sed -n "s/^$2=//p" "$BASE/$1/ENVIRONMENT" || true; }

build() {  # build <專案資料夾> <專案> <destination>
  (cd "$ROOT/apple/$1" && xcodegen generate --quiet)
  xcodebuild -project "$ROOT/apple/$1/$2.xcodeproj" -scheme "$2" -configuration Debug -destination "$3" \
    -derivedDataPath "$OUT/dd-$1" build >"$OUT/build-$1.log" 2>&1 || { grep error: "$OUT/build-$1.log" | head; exit 2; }
}

# 把這個平台應有的每一張截圖從 <來源> 複製到 build/snapshots/<平台>/；少任何一張都算失敗（不論環境）
collect() {  # collect <平台> <來源資料夾> <檔名...>
  local platform=$1 src=$2 missing=0; shift 2
  rm -rf "${OUT:?}/$platform"; mkdir -p "$OUT/$platform"
  for name in "$@"; do
    cp "$src/$name.png" "$OUT/$platform/" 2>/dev/null || { echo "沒有產生 ${name}.png"; missing=1; }
  done
  [ "$missing" = 0 ] || { echo "$platform 的截圖不齊全"; exit 2; }
}

render_mac() {
  if [ -n "${SNAPSHOT_FROM:-}" ]; then collect mac "$SNAPSHOT_FROM/mac" "${MAC_SET[@]}"; return; fi  # 測試用：不產生，用現成的圖
  local app=${SNAPSHOT_MAC_APP:-}
  if [ -z "$app" ]; then
    build MacMenuBar AIUsageMenuBar 'platform=macOS'
    app=$OUT/dd-MacMenuBar/Build/Products/Debug/AIUsageMenuBar.app
  fi
  local all=$WORK/mac-all
  AUM_RENDER_NOW=$RENDER_NOW python3 "$ROOT/scripts/make-demo-history.py" "$WORK/home" normal >/dev/null
  env AI_USAGE_MONITOR_HOME="$WORK/home" AUM_TESTING=1 AUM_DEMO_PANEL=1 AUM_RENDER_DIR="$all" AUM_RENDER_EXIT=1 \
    AUM_RENDER_NOW=$RENDER_NOW perl -e 'alarm 600; exec @ARGV' "$app/Contents/MacOS/AIUsageMenuBar" "${LANG_ARGS[@]}" \
    >"$OUT/render-mac.log" 2>&1 || { echo "Mac 截圖失敗（$OUT/render-mac.log）"; exit 2; }
  collect mac "$all" "${MAC_SET[@]}"
}

# 依名稱找模擬器（同名時用最新的 runtime），印出「UDID runtime」
find_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
found = [(rt, d["udid"]) for rt, ds in json.load(sys.stdin)["devices"].items() for d in ds if d["name"] == name]
if found:
    rt, udid = max(found)
    print(udid, rt.rsplit(".", 1)[-1])
' "$1"
}

render_ios() {
  if [ -n "${SNAPSHOT_FROM:-}" ]; then
    SIM_DESC=${SNAPSHOT_SIM_DESC:-test}
    collect ios "$SNAPSHOT_FROM/ios" "${IOS_SET[@]}"
    return
  fi
  local app=${SNAPSHOT_IOS_APP:-}
  if [ -z "$app" ]; then
    build iOSApp AIUsageMonitor 'generic/platform=iOS Simulator'
    app=$OUT/dd-iOSApp/Build/Products/Debug-iphonesimulator/AIUsageMonitor.app
  fi
  SIM_NAME=${SNAPSHOT_SIMULATOR:-$(baseline_env ios simulator | sed 's/ iOS-.*//')}
  SIM_NAME=${SIM_NAME:-iPhone 18 Pro}
  read -r udid runtime < <(find_simulator "$SIM_NAME") || true
  [ -n "${udid:-}" ] || { echo "找不到模擬器「${SIM_NAME}」（SNAPSHOT_SIMULATOR 可指定）"; exit 2; }
  SIM_DESC="$SIM_NAME $runtime"
  local booted_here=0
  if ! xcrun simctl list devices | grep -q "$udid) (Booted)"; then
    xcrun simctl boot "$udid"
    booted_here=1
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl install "$udid" "$app"
  local docs
  docs=$(xcrun simctl get_app_container "$udid" "$IOS_BUNDLE" data)/Documents
  mkdir -p "$docs"
  rm -f "$docs"/*.png "$docs/island-sizes.json"
  # 剛開機後的第一次啟動常常不出畫面，launch_ios_render 會重新啟動一次（scripts/ios-render-launch.sh）
  SIMCTL_CHILD_AUM_RENDER=1 SIMCTL_CHILD_AUM_DEMO=normal SIMCTL_CHILD_AUM_RENDER_NOW=$RENDER_NOW SIMCTL_CHILD_TZ=$TZ \
    launch_ios_render "$udid" "$IOS_BUNDLE" "$docs" "${LANG_ARGS[@]}" || true
  xcrun simctl terminate "$udid" "$IOS_BUNDLE" 2>/dev/null || true
  [ "$booted_here" = 1 ] && xcrun simctl shutdown "$udid"
  [ -f "$docs/island-sizes.json" ] || { echo "iOS 截圖逾時"; exit 2; }
  collect ios "$docs" "${IOS_SET[@]}"
}

# 影響畫面的環境：Mac 看 macOS 與 Xcode，iPhone 看 Xcode（SDK）與模擬器的 runtime
fingerprint() {  # fingerprint <平台>
  [ "$1" = ios ] || echo "macos=$(sw_vers -productVersion | cut -d. -f1-2)"
  echo "xcode=$(xcodebuild -version | head -1 | awk '{print $2}')"
  [ "$1" != ios ] || echo "simulator=$SIM_DESC"
}

SIM_DESC=
for platform in $PLATFORMS; do "render_$platform"; done

if [ "$MODE" = update ]; then
  # 到這裡每個平台的截圖都已齊全（collect 少一張就結束）；整個資料夾一起換，不留下新舊混合的基準
  for platform in $PLATFORMS; do
    staged=$WORK/base-$platform
    mkdir -p "$staged"
    cp "$OUT/$platform"/*.png "$staged/"
    fingerprint "$platform" >"$staged/ENVIRONMENT"
    rm -rf "${BASE:?}/$platform"
    mkdir -p "$BASE"
    mv "$staged" "$BASE/$platform"
    echo "基準已更新：apple/Snapshots/${platform}（$(paste -sd' ' - <"$BASE/$platform/ENVIRONMENT")）"
  done
  exit 0
fi

COMPARE=$OUT/compare-snapshots
if [ ! -x "$COMPARE" ] || [ "$ROOT/scripts/compare-snapshots.swift" -nt "$COMPARE" ]; then
  swiftc -O "$ROOT/scripts/compare-snapshots.swift" -o "$COMPARE"
fi
fail=0
for platform in $PLATFORMS; do
  echo "== $platform"
  code=0
  "$COMPARE" "$BASE/$platform" "$OUT/$platform" "$OUT/diff/$platform" || code=$?
  [ "$code" = 0 ] && continue
  if [ "$code" != 1 ]; then
    echo "❌ ${platform}：基準或截圖缺少、無法讀取（不論環境都算失敗）"
    fail=1
    continue
  fi
  # 只有畫面差異：這個平台的環境和基準不同時只警告
  mismatch=$(fingerprint "$platform" | while IFS= read -r line; do
    key=${line%%=*}
    [ "$(baseline_env "$platform" "$key")" = "${line#*=}" ] || echo "${key}：基準 $(baseline_env "$platform" "$key")，這裡 ${line#*=}"
  done)
  if [ -n "$mismatch" ] && [ "${SNAPSHOT_STRICT:-0}" != 1 ]; then
    echo "⚠️ $platform 的環境和基準不同，畫面差異只供參考、不算失敗："
    echo "$mismatch"
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning::截圖比對（${platform}）：環境和基準不同（$(echo "$mismatch" | paste -sd' ' -)），差異只供參考"
  else
    fail=1
  fi
done
[ "$fail" = 0 ] && echo "snapshots: 通過" || echo "snapshots: 有截圖和基準不符（差異圖：${OUT#"$ROOT"/}/diff/）；畫面是有意改變時執行 scripts/update-snapshots.sh"
exit $fail
