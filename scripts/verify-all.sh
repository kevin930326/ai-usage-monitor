#!/bin/bash
# 一個指令跑完所有測試與建置（含 Release），最後列出每一項通過或失敗。
#
#   scripts/verify-all.sh            # 全部
#   SKIP_LINUX=1 scripts/verify-all.sh   # 沒有 Docker 時略過 Linux 的 UsageKit 測試
#
# 建置產物放在 build/verify（已在 .gitignore），完整輸出在 build/verify/logs/。
# 不連網、不讀 Keychain、不碰真實的 usage.json：收集器測試以臨時資料夾當 AI_USAGE_MONITOR_HOME。
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2
OUT=${VERIFY_OUT:-$ROOT/build/verify}
DD=$OUT/DerivedData
LOGS=$OUT/logs
mkdir -p "$LOGS"
names=()
codes=()

run() {  # run <名稱> <指令...>
  local name=$1; shift
  local log="$LOGS/$name.log"
  printf '%-28s ' "$name"
  ( "$@" ) >"$log" 2>&1
  local code=$?
  names+=("$name"); codes+=("$code")
  if [ $code -eq 0 ]; then echo "PASS"; else echo "FAIL (exit $code, log: ${log#$ROOT/})"; fi
}

xcbuild() {  # xcbuild <專案資料夾> <專案> <scheme> <Debug|Release> <destination>
  (cd "apple/$1" && xcodegen generate --quiet) || return 1
  xcodebuild -project "apple/$1/$2.xcodeproj" -scheme "$3" -configuration "$4" \
    -destination "$5" -derivedDataPath "$DD/$1" build
}

# Release 版不應含任何 DEBUG 專用的字串（示範資料、截圖工具、環境變數覆寫）
no_debug_strings() {  # no_debug_strings <bundle 路徑>
  local bundle=$1 hit=0
  [ -d "$bundle" ] || { echo "missing $bundle"; return 1; }
  while IFS= read -r bin; do
    for s in AUM_DEMO AUM_RENDER AUM_RELAY_URL AUM_READ_TOKEN activity-log.json restart-log.json DemoData DebugRender DebugTools; do
      if strings -a "$bin" | grep -q "$s"; then echo "HIT $s in ${bin#$bundle/}"; hit=1; fi
    done
  done < <(find "$bundle" -type f -perm -u+x ! -name '*.sh')
  [ $hit -eq 0 ] && echo "no debug strings in $(basename "$bundle")"
  return $hit
}

TMPHOME=$(mktemp -d)
run collector-tests  bash -c "cd collector && AI_USAGE_MONITOR_HOME='$TMPHOME' python3 -m unittest -v"
run relay-tests      bash -c "cd relay && ([ -d node_modules ] || npm ci --no-audit --no-fund) && npm test"
run usagekit-macos   bash -c "cd apple/UsageKit && swift test"
if [ "${SKIP_LINUX:-0}" != 1 ]; then
  # 掛載整個 repo：UsageKit 測試會讀 repo 根目錄的 fixtures/
  run usagekit-linux docker run --rm -v "$ROOT":/repo -w /repo/apple/UsageKit swift:6.2 \
    bash -c 'swift test --scratch-path /tmp/build'
fi

IOS_DEST='generic/platform=iOS Simulator'
MAC_DEST='platform=macOS'
WATCH_DEST='generic/platform=watchOS Simulator'
for config in Debug Release; do
  run "ios-$config"   xcbuild iOSApp      AIUsageMonitor AIUsageMonitor "$config" "$IOS_DEST"
  run "mac-$config"   xcbuild MacMenuBar  AIUsageMenuBar AIUsageMenuBar "$config" "$MAC_DEST"
  run "watch-$config" xcbuild WatchApp    AIUsageWatch   AIUsageWatch   "$config" "$WATCH_DEST"
done
run ios-appex         test -d "$DD/iOSApp/Build/Products/Release-iphonesimulator/AIUsageMonitor.app/PlugIns/UsageWidget.appex"
run mac-appex         test -d "$DD/MacMenuBar/Build/Products/Release/AIUsageMenuBar.app/Contents/PlugIns/UsageDesktopWidget.appex"
run watch-appex       test -d "$DD/WatchApp/Build/Products/Release-watchsimulator/AIUsageWatch.app/PlugIns/UsageComplications.appex"
run ios-release-clean   no_debug_strings "$DD/iOSApp/Build/Products/Release-iphonesimulator/AIUsageMonitor.app"
run mac-release-clean   no_debug_strings "$DD/MacMenuBar/Build/Products/Release/AIUsageMenuBar.app"
run watch-release-clean no_debug_strings "$DD/WatchApp/Build/Products/Release-watchsimulator/AIUsageWatch.app"

echo
fail=0
for i in "${!names[@]}"; do
  if [ "${codes[$i]}" -eq 0 ]; then echo "  ✅ ${names[$i]}"; else echo "  ❌ ${names[$i]}"; fail=1; fi
done
passed=0; for c in "${codes[@]}"; do [ "$c" -eq 0 ] && passed=$((passed+1)); done
echo "verify-all: $passed/${#codes[@]} passed ($(git rev-parse --abbrev-ref HEAD)@$(git rev-parse --short HEAD))"
exit $fail
