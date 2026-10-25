#!/bin/bash
# 重新產生 iOS、手錶與 Mac 的 App 圖示 PNG（寫進三個 App 的 Assets.xcassets/AppIcon.appiconset）。
#
#   scripts/render-app-icon.sh
#
# 先把 UsageKit、UsageKitUI 編成模組，再編譯 render-app-icon.swift，
# 讓圖示直接用 App 內同一份 ClaudeIconShape、CodexIconShape。只在 macOS 上執行。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT/apple/UsageKit/Sources
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

module() {  # module <名稱> <原始碼...>
  local name=$1; shift
  swiftc -swift-version 6 -parse-as-library -O -suppress-warnings -static -emit-library -emit-module \
    -module-name "$name" -I "$TMP" -L "$TMP" \
    -emit-module-path "$TMP/$name.swiftmodule" -o "$TMP/lib$name.a" "$@"
}
module UsageKit "$SRC"/UsageKit/*.swift
module UsageKitUI "$SRC"/UsageKitUI/*.swift
swiftc -swift-version 6 -parse-as-library -I "$TMP" -L "$TMP" -lUsageKit -lUsageKitUI \
  -o "$TMP/render-app-icon" "$ROOT/scripts/render-app-icon.swift"
"$TMP/render-app-icon" "$ROOT"
