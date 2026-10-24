#!/bin/bash
# 建置發布用的 Mac App（FR-53、ADR-0013 第 1～3 節）：Release＋內建 Python 與收集器、ad-hoc 簽署，
# 產出 zip、dmg、寫好版本與 SHA-256 的 install.sh，以及 SHA256SUMS。
#
#   scripts/build-release.sh [--version <版本>] [--out <資料夾>]
#   scripts/build-release.sh --test-home <資料夾> [--out <資料夾>]
#
# - 版本預設是 apple/MacMenuBar/project.yml 的 MARKETING_VERSION；產出預設在 build/release/<版本>/
#   AIUsageMenuBar-<版本>.zip、AIUsageMenuBar-<版本>.dmg（拖到「應用程式」）、install.sh、SHA256SUMS
# - --test-home：安裝測試版。Debug 建置、bundle ID 加上 .installtest（UserDefaults 與登入項目跟正式版分開），
#   內建收集器只讀寫該資料夾（見 scripts/bundle-collector.sh --test-home）。只給本機驗證用，不要發布。
# 只寫 build/：不上傳、不建立 tag 或 GitHub Release（發布由 .github/workflows/release.yml 建立草稿）。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_DIR=$ROOT/apple/MacMenuBar
NAME=AIUsageMenuBar
VERSION=
OUT=
TEST_HOME=
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=${2:?--version 要指定版本}; shift 2 ;;
    --out) OUT=${2:?--out 要指定資料夾}; shift 2 ;;
    --test-home) TEST_HOME=${2:?--test-home 要指定資料夾}; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "不認得的參數：$1" >&2; exit 2 ;;
  esac
done
[ -n "$VERSION" ] || VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$PROJECT_DIR/project.yml" | head -1)
VERSION=${VERSION#v}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "版本格式不對：${VERSION}（例如 1.0.0）" >&2; exit 2; }
OUT=${OUT:-$ROOT/build/release/$VERSION}

CONFIG=Release
BUNDLE_ID=io.github.kevin930326.AIUsageMenuBar
if [ -n "$TEST_HOME" ]; then
  CONFIG=Debug
  BUNDLE_ID=$BUNDLE_ID.installtest
fi

# 同一時間只允許一個建置（mkdir 是原子操作）
mkdir -p "$ROOT/build"
touch "$ROOT/build/.metadata_never_index"
LOCK=$ROOT/build/release.lock
mkdir "$LOCK" 2>/dev/null || { echo "另一個建置正在進行（${LOCK}）；確定沒有在執行的話刪除這個資料夾再試" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null || true' EXIT

command -v xcodebuild >/dev/null || { echo "找不到 xcodebuild，請先安裝 Xcode" >&2; exit 1; }
if command -v xcodegen >/dev/null; then
  (cd "$PROJECT_DIR" && xcodegen generate --quiet)
elif [ ! -d "$PROJECT_DIR/$NAME.xcodeproj" ]; then
  echo "找不到 $NAME.xcodeproj，請先 brew install xcodegen" >&2
  exit 1
fi

DERIVED=$ROOT/build/release/DerivedData
LOG=$ROOT/build/release/xcodebuild.log
mkdir -p "$(dirname "$LOG")"
echo "建置 ${CONFIG}（${VERSION}、${BUNDLE_ID}）…"
if ! xcodebuild -project "$PROJECT_DIR/$NAME.xcodeproj" -scheme "$NAME" -configuration "$CONFIG" \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20 >&2 || true
  echo "建置失敗，完整紀錄：$LOG" >&2
  exit 1
fi

APP=$TMP/$NAME.app
ditto "$DERIVED/Build/Products/$CONFIG/$NAME.app" "$APP"
if [ -n "$TEST_HOME" ]; then
  "$ROOT/scripts/bundle-collector.sh" "$APP" --test-home "$TEST_HOME"
else
  "$ROOT/scripts/bundle-collector.sh" "$APP"
fi
GOT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
GOT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[ "$GOT_ID" = "$BUNDLE_ID" ] && [ "$GOT_VERSION" = "$VERSION" ] \
  || { echo "建置出來的 App 是 ${GOT_ID} ${GOT_VERSION}，預期 ${BUNDLE_ID} ${VERSION}" >&2; exit 1; }

mkdir -p "$OUT"
ZIP=$NAME-$VERSION.zip
DMG=$NAME-$VERSION.dmg
rm -f "$OUT/$ZIP" "$OUT/$DMG" "$OUT/install.sh" "$OUT/SHA256SUMS"
# ditto 保留符號連結與權限（內嵌的 Python 有 python3 → python3.13）
ditto -c -k --keepParent "$APP" "$OUT/$ZIP"

STAGE=$TMP/dmg
mkdir "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "AI 用量 $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/$DMG"

ZIP_SHA=$(shasum -a 256 "$OUT/$ZIP" | awk '{print $1}')
# 只換掉開頭兩行的預設值；腳本後面檢查「__ 開頭＝沒有指定」的地方不受影響
python3 - "$ROOT/scripts/install.sh" "$OUT/install.sh" "$VERSION" "$ZIP_SHA" <<'PY'
import sys
src, out, version, sha = sys.argv[1:]
text = open(src).read()
for old, new in (('VERSION="__VERSION__"', f'VERSION="{version}"'), ('ZIP_SHA256="__ZIP_SHA256__"', f'ZIP_SHA256="{sha}"')):
    assert text.count(old) == 1, old
    text = text.replace(old, new)
open(out, "w").write(text)
PY
chmod 755 "$OUT/install.sh"
(cd "$OUT" && shasum -a 256 "$ZIP" "$DMG" install.sh >SHA256SUMS)

echo "產出（${OUT}）："
(cd "$OUT" && for f in "$ZIP" "$DMG" install.sh; do printf '  %-28s %6s\n' "$f" "$(du -h "$f" | awk '{print $1}')"; done)
echo "SHA-256（zip）：$ZIP_SHA"
