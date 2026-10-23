#!/bin/bash
# 建置 Mac 選單列 App（Release）並安裝到「應用程式」資料夾。
#
#   scripts/install-mac-app.sh [--no-open]
#
# 1. 用 XcodeGen 產生專案（有裝的話），以 Release、Sign to Run Locally 建置到 build/install/
# 2. 結束執行中的「AI 用量」（正式版與從 Xcode 執行的都會結束）
# 3. 舊的 /Applications/AIUsageMenuBar.app 移到垃圾桶（可以從垃圾桶放回），複製新版本
# 4. 打開新版本（--no-open 時不打開）
# 之後可在 App 的設定開啟「登入時自動打開」。只讀寫 build/、/Applications 與垃圾桶，不碰收集器與資料。
# 測試用：AUM_INSTALL_DIR=<資料夾> 改裝到該資料夾，且不結束執行中的 App、不打開。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_DIR=$ROOT/apple/MacMenuBar
DERIVED=$ROOT/build/install/DerivedData
NAME=AIUsageMenuBar
BUNDLE_ID=io.github.kevin930326.AIUsageMenuBar
DEST_DIR=${AUM_INSTALL_DIR:-/Applications}
DEST=$DEST_DIR/$NAME.app
OPEN=1
QUIT=1
[ -n "${AUM_INSTALL_DIR:-}" ] && { OPEN=0; QUIT=0; }
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "不認得的參數：${arg}（只支援 --no-open）" >&2; exit 2 ;;
  esac
done

# 同一時間只允許一個安裝（mkdir 是原子操作）；結束時才釋放
LOCK=$ROOT/build/install.lock
mkdir -p "$ROOT/build"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "另一個安裝正在進行（${LOCK}）；確定沒有在執行的話刪除這個資料夾再試" >&2
  exit 1
fi
TMP=
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT

command -v xcodebuild >/dev/null || { echo "找不到 xcodebuild，請先安裝 Xcode" >&2; exit 1; }
if command -v xcodegen >/dev/null; then
  (cd "$PROJECT_DIR" && xcodegen generate --quiet)
elif [ ! -d "$PROJECT_DIR/$NAME.xcodeproj" ]; then
  echo "找不到 $NAME.xcodeproj，請先 brew install xcodegen" >&2
  exit 1
fi

echo "建置 Release…"
LOG=$ROOT/build/install/xcodebuild.log
mkdir -p "$(dirname "$LOG")"
if ! xcodebuild -project "$PROJECT_DIR/$NAME.xcodeproj" -scheme "$NAME" -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20 >&2 || true
  echo "建置失敗，完整紀錄：$LOG" >&2
  exit 1
fi
BUILT=$DERIVED/Build/Products/Release/$NAME.app
[ -d "$BUILT" ] || { echo "找不到建置結果 $BUILT" >&2; exit 1; }

# 等 App 結束，最多 $1 秒；結束了回傳 0
wait_quit() {
  local i
  for ((i = 0; i < $1 * 2; i++)); do
    pgrep -x "$NAME" >/dev/null || return 0
    sleep 0.5
  done
  ! pgrep -x "$NAME" >/dev/null
}

# 先請 App 自己結束，5 秒內沒結束再送 TERM；再等 5 秒仍在執行就停止，不換掉舊版本
if [ "$QUIT" = 1 ] && pgrep -x "$NAME" >/dev/null; then
  echo "結束執行中的 App…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  if ! wait_quit 5; then
    pkill -TERM -x "$NAME" 2>/dev/null || true
    if ! wait_quit 5; then
      echo "App 沒有結束（可能被 Xcode 除錯器暫停），沒有安裝；結束它之後再執行一次" >&2
      exit 1
    fi
  fi
fi

# 先複製到同一個資料夾的暫存名稱，成功後才換掉舊版本（複製失敗時舊版本不受影響）
TMP=$(mktemp -d "$DEST_DIR/.$NAME.installing.XXXXXX")
ditto "$BUILT" "$TMP/$NAME.app"
if [ -d "$DEST" ]; then
  TRASH=$HOME/.Trash/$NAME-$(date +%Y%m%d-%H%M%S).app
  mv "$DEST" "$TRASH"
  echo "舊版本已移到垃圾桶：$TRASH"
fi
mv "$TMP/$NAME.app" "$DEST"
echo "已安裝：${DEST}（版本 $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')）"

if [ "$OPEN" = 1 ]; then
  open "$DEST"
  echo "已打開。要登入時自動打開：點選單列圖示 → 齒輪 → 一般 → 登入時自動打開"
fi
