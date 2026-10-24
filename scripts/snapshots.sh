#!/bin/bash
# 截圖比對：用 ImageRenderer 產生 Mac 面板、完整統計、設定、選單列圖示，以及 iPhone 小工具、
# 鎖定畫面 Live Activity、動態島（淺色、深色），和 apple/Snapshots/ 的基準比對，容許小誤差。
#
#   scripts/snapshots.sh                     # 比對（verify-all 會跑）
#   scripts/update-snapshots.sh              # 畫面有意改變時：重新產生基準（等於 snapshots.sh --update）
#   SNAPSHOT_PLATFORMS=mac scripts/snapshots.sh   # 只比 Mac（CI）
#
# - SNAPSHOT_MAC_APP／SNAPSHOT_IOS_APP：已建置的 Debug 版 .app（verify-all 傳入）；沒給就自己建置到 build/snapshots。
# - 固定時間（AUM_RENDER_NOW）、時區（Asia/Taipei）與語系，假資料用 scripts/make-demo-history.py 產生在暫存資料夾，
#   不讀真實資料。iOS 在模擬器以示範模式（AUM_DEMO）啟動，不連線中繼。
# - 字型與系統元件會隨 macOS、Xcode 與模擬器版本改變：環境和基準（apple/Snapshots/ENVIRONMENT）不同時
#   只印出比對結果與警告、不算失敗（SNAPSHOT_STRICT=1 時仍算失敗）。
# - 不符時差異圖在 build/snapshots/diff/<平台>/（不同的像素標紅）。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=$ROOT/apple/Snapshots
OUT=${SNAPSHOT_OUT:-$ROOT/build/snapshots}
MODE=compare
[ "${1:-}" = --update ] && MODE=update
PLATFORMS=${SNAPSHOT_PLATFORMS:-mac ios}
RENDER_NOW=2026-10-21T04:00:00Z
export TZ=Asia/Taipei
LANG_ARGS=(-AppleLanguages "(zh-Hant-TW)" -AppleLocale zh_TW)
MAC_SET=(panel-light panel-dark stats-window-light stats-window-dark settings-light settings-dark
         menubar-icons-light menubar-icons-dark)
IOS_SET=(widget-small-light widget-small-dark widget-medium-light widget-medium-dark widget-large-light widget-large-dark
         live-activity-light live-activity-dark island-normal)
IOS_BUNDLE=io.github.kevin930326.AIUsageMonitor

mkdir -p "$OUT"
touch "$ROOT/build/.metadata_never_index"  # 不讓 Spotlight 索引建置產物
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 基準記錄的值（key=value）
baseline_env() { [ -f "$BASE/ENVIRONMENT" ] && sed -n "s/^$1=//p" "$BASE/ENVIRONMENT" || true; }

build() {  # build <專案資料夾> <專案> <destination> <產物路徑>
  (cd "$ROOT/apple/$1" && xcodegen generate --quiet)
  xcodebuild -project "$ROOT/apple/$1/$2.xcodeproj" -scheme "$2" -configuration Debug -destination "$3" \
    -derivedDataPath "$OUT/dd-$1" build >"$OUT/build-$1.log" 2>&1 || { grep error: "$OUT/build-$1.log" | head; exit 2; }
}

render_mac() {
  local app=${SNAPSHOT_MAC_APP:-}
  if [ -z "$app" ]; then
    build MacMenuBar AIUsageMenuBar 'platform=macOS'
    app=$OUT/dd-MacMenuBar/Build/Products/Debug/AIUsageMenuBar.app
  fi
  local all=$WORK/mac-all
  AUM_RENDER_NOW=$RENDER_NOW python3 "$ROOT/scripts/make-demo-history.py" "$WORK/home" normal >/dev/null
  env AI_USAGE_MONITOR_HOME="$WORK/home" AUM_DEMO_PANEL=1 AUM_RENDER_DIR="$all" AUM_RENDER_EXIT=1 \
    AUM_RENDER_NOW=$RENDER_NOW perl -e 'alarm 600; exec @ARGV' "$app/Contents/MacOS/AIUsageMenuBar" "${LANG_ARGS[@]}" \
    >"$OUT/render-mac.log" 2>&1 || { echo "Mac 截圖失敗（$OUT/render-mac.log）"; exit 2; }
  rm -rf "$OUT/mac"; mkdir -p "$OUT/mac"
  for name in "${MAC_SET[@]}"; do cp "$all/$name.png" "$OUT/mac/" 2>/dev/null || echo "沒有產生 $name.png"; done
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
  local app=${SNAPSHOT_IOS_APP:-}
  if [ -z "$app" ]; then
    build iOSApp AIUsageMonitor 'generic/platform=iOS Simulator'
    app=$OUT/dd-iOSApp/Build/Products/Debug-iphonesimulator/AIUsageMonitor.app
  fi
  SIM_NAME=${SNAPSHOT_SIMULATOR:-$(baseline_env simulator | sed 's/ iOS-.*//')}
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
  SIMCTL_CHILD_AUM_RENDER=1 SIMCTL_CHILD_AUM_DEMO=normal SIMCTL_CHILD_AUM_RENDER_NOW=$RENDER_NOW SIMCTL_CHILD_TZ=$TZ \
    xcrun simctl launch --terminate-running-process "$udid" "$IOS_BUNDLE" "${LANG_ARGS[@]}" >/dev/null
  for _ in $(seq 120); do [ -f "$docs/island-sizes.json" ] && break; sleep 1; done
  xcrun simctl terminate "$udid" "$IOS_BUNDLE" 2>/dev/null || true
  [ "$booted_here" = 1 ] && xcrun simctl shutdown "$udid"
  [ -f "$docs/island-sizes.json" ] || { echo "iOS 截圖逾時"; exit 2; }
  rm -rf "$OUT/ios"; mkdir -p "$OUT/ios"
  for name in "${IOS_SET[@]}"; do cp "$docs/$name.png" "$OUT/ios/" 2>/dev/null || echo "沒有產生 $name.png"; done
}

fingerprint() {
  echo "macos=$(sw_vers -productVersion | cut -d. -f1-2)"
  echo "xcode=$(xcodebuild -version | head -1 | awk '{print $2}')"
  [ -z "${SIM_DESC:-}" ] || echo "simulator=$SIM_DESC"
}

SIM_DESC=
for platform in $PLATFORMS; do "render_$platform"; done

if [ "$MODE" = update ]; then
  for platform in $PLATFORMS; do
    mkdir -p "$BASE/$platform"
    cp "$OUT/$platform"/*.png "$BASE/$platform/"
  done
  # 只更新這次產生的平台那幾行，保留其他平台的紀錄
  { fingerprint; [ -f "$BASE/ENVIRONMENT" ] && grep -v -E "^($(fingerprint | cut -d= -f1 | paste -sd'|' -))=" "$BASE/ENVIRONMENT" || true; } \
    | sort >"$WORK/env" && mv "$WORK/env" "$BASE/ENVIRONMENT"
  echo "基準已更新：apple/Snapshots/（$(cat "$BASE/ENVIRONMENT" | paste -sd' ' -)）"
  exit 0
fi

COMPARE=$OUT/compare-snapshots
if [ ! -x "$COMPARE" ] || [ "$ROOT/scripts/compare-snapshots.swift" -nt "$COMPARE" ]; then
  swiftc -O "$ROOT/scripts/compare-snapshots.swift" -o "$COMPARE"
fi
fail=0
for platform in $PLATFORMS; do
  echo "== $platform"
  "$COMPARE" "$BASE/$platform" "$OUT/$platform" "$OUT/diff/$platform" || fail=1
done

mismatch=$(fingerprint | while IFS= read -r line; do
  key=${line%%=*}; [ "$(baseline_env "$key")" = "${line#*=}" ] || echo "${key}：基準 $(baseline_env "$key")，這裡 ${line#*=}"
done)
if [ "$fail" = 1 ] && [ -n "$mismatch" ] && [ "${SNAPSHOT_STRICT:-0}" != 1 ]; then
  echo "⚠️ 環境和基準不同，比對結果只供參考、不算失敗："
  echo "$mismatch"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::截圖比對：環境和基準不同（$(echo "$mismatch" | paste -sd' ' -)），差異只供參考"
  exit 0
fi
[ "$fail" = 0 ] && echo "snapshots: 全部相符" || echo "snapshots: 有截圖和基準不符（差異圖：${OUT#$ROOT/}/diff/）；畫面是有意改變時執行 scripts/update-snapshots.sh"
exit $fail
