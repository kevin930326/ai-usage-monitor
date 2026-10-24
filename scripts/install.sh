#!/bin/bash
# AI 用量（Mac）一行安裝（FR-53、ADR-0013 第 1 節）：下載 → 驗證 SHA-256 → 安裝到「應用程式」→ 打開。
# 重跑即更新（舊版移到垃圾桶）。不使用 sudo，只寫「應用程式」資料夾、垃圾桶與暫存資料夾。
#
#   curl -fsSL https://github.com/kevin930326/ai-usage-monitor/releases/download/v<版本>/install.sh | bash
#   curl -fsSL …/install.sh | bash -s -- --uninstall            # 停用內建收集器、App 移到垃圾桶
#   curl -fsSL …/install.sh | bash -s -- --uninstall --purge    # 另外把資料與日誌移到垃圾桶
#
# Release 中的這份由 scripts/build-release.sh 寫入版本與 zip 的 SHA-256（只下載這個版本、不用 latest）。
# repo 裡的這份要另外給 --version 與 --sha256。
#
# 參數：--version <版本> --sha256 <zip 的 SHA-256> --uninstall --purge --yes（--purge 不再詢問）--no-open
# 測試用環境變數：AUM_INSTALL_DIR（改裝到這個資料夾，不結束執行中的 App、不打開）、
#   AUM_ZIP（改用本機的 zip，不下載）、AUM_EXPECT_BUNDLE_ID（安裝測試版的 bundle ID）、AUM_TRASH_DIR（取代垃圾桶）、
#   AUM_LAUNCH_AGENTS_DIR（取代 ~/Library/LaunchAgents，偵測舊收集器用）
#
# 為什麼不跳 Gatekeeper：隔離屬性是瀏覽器等 App 下載時加上的，curl 與 ditto 不會加，所以 macOS 不檢查這個 App。
# 這表示你信任的是這個腳本與它的下載來源（GitHub 上這個 repo 的 Release）；看過腳本再執行的做法見 README。
set -euo pipefail
VERSION="__VERSION__"
ZIP_SHA256="__ZIP_SHA256__"
REPO_URL=https://github.com/kevin930326/ai-usage-monitor
NAME=AIUsageMenuBar
BUNDLE_ID=${AUM_EXPECT_BUNDLE_ID:-io.github.kevin930326.AIUsageMenuBar}
DEST_DIR=${AUM_INSTALL_DIR:-/Applications}
DEST=$DEST_DIR/$NAME.app
DATA_DIR=${AI_USAGE_MONITOR_HOME:-$HOME/Library/Application Support/AIUsageMonitor}
LOG_DIR=$HOME/Library/Logs/AIUsageMonitor
LEGACY_PLIST=${AUM_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/io.github.kevin930326.ai-usage-monitor.plist
TRASH_DIR=${AUM_TRASH_DIR:-$HOME/.Trash}
TEST_MODE=0
[ -n "${AUM_INSTALL_DIR:-}" ] && TEST_MODE=1

MODE=install
PURGE=0
YES=0
OPEN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=${2:?--version 要指定版本}; shift 2 ;;
    --sha256) ZIP_SHA256=${2:?--sha256 要指定 SHA-256}; shift 2 ;;
    --uninstall) MODE=uninstall; shift ;;
    --purge) PURGE=1; shift ;;
    --yes) YES=1; shift ;;
    --no-open) OPEN=0; shift ;;
    -h|--help) sed -n '2,18p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "不認得的參數：$1" >&2; exit 2 ;;
  esac
done
VERSION=${VERSION#v}
[ "$TEST_MODE" = 1 ] && OPEN=0

say() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }

[ "$(uname -s)" = Darwin ] || fail "這個安裝腳本只支援 macOS；Windows 請用 install.ps1" 2

trash() {  # 移到垃圾桶（可以放回），名稱加上時間避免撞名
  local src=$1 base
  base=$(basename "$src")
  mkdir -p "$TRASH_DIR"
  mv "$src" "$TRASH_DIR/${base%.*}-$(date +%Y%m%d-%H%M%S)$([ "${base##*.}" != "$base" ] && echo ".${base##*.}")"
}

quit_app() {
  [ "$TEST_MODE" = 1 ] && return 0
  pgrep -x "$NAME" >/dev/null || return 0
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$NAME" >/dev/null || return 0; sleep 0.5; done
  pkill -TERM -x "$NAME" 2>/dev/null || true
  sleep 1
  ! pgrep -x "$NAME" >/dev/null || fail "AI 用量沒有結束；結束它之後再執行一次"
}

# 解除內建收集器的註冊（App 處理 --unregister-collector 後立即結束）；最多等 20 秒。失敗或逾時回傳非 0
unregister_collector() {
  [ -x "$DEST/Contents/MacOS/$NAME" ] || return 0
  perl -e 'alarm 20; exec @ARGV' "$DEST/Contents/MacOS/$NAME" --unregister-collector >/dev/null 2>&1 || return 1
  say "已停用內建收集器"
}

if [ "$MODE" = uninstall ]; then
  if [ -d "$DEST" ]; then
    quit_app
    # 背景收集器沒確定停下來就不移走 App 與資料：它還會每 5 分鐘寫入（App 留著，之後可以重跑）
    unregister_collector || fail "無法停用內建收集器，App 與資料都沒有移走：到「系統設定 › 一般 › 登入項目與延伸功能」關掉「AI 用量」後再執行一次" 5
    trash "$DEST"
    say "App 已移到垃圾桶：$DEST"
  else
    say "找不到 ${DEST}，略過 App"
  fi
  if [ "$PURGE" = 1 ]; then
    if [ -f "$LEGACY_PLIST" ]; then
      say "偵測到 install-launchd.sh 安裝的收集器仍在使用資料夾：先執行 collector/scripts/uninstall-launchd.sh，再加 --purge 重跑；這次沒有移走資料"
      exit 0
    fi
    if [ "$YES" != 1 ]; then
      # 能打開才算有終端機（-r 只看權限；沒有控制終端機時打開會失敗）
      (: </dev/tty) 2>/dev/null || fail "要移走資料與日誌請加 --yes（沒有終端機可以詢問）"
      printf '把資料（額度歷史、Token 統計）與日誌移到垃圾桶？[y/N] ' >/dev/tty
      read -r answer </dev/tty || answer=
      case "$answer" in y|Y|yes) ;; *) say "沒有移走資料"; exit 0 ;; esac
    fi
    for dir in "$DATA_DIR" "$LOG_DIR"; do
      if [ -d "$dir" ]; then trash "$dir"; say "已移到垃圾桶：$dir"; fi
    done
    say "中繼的密鑰仍在 Keychain；不再使用中繼時可以刪除："
    say "  security delete-generic-password -s AIUsageMonitor-relay-write -a default"
    say "  security delete-generic-password -s AIUsageMonitor-relay-read"
  fi
  exit 0
fi

# ---- 安裝 ----
[ "$(uname -m)" = arm64 ] || fail "目前只提供 Apple 晶片（arm64）的版本" 2
case "$VERSION" in __*|"") fail "沒有指定版本：用 Release 附的 install.sh，或加 --version 與 --sha256" 2 ;; esac
case "$ZIP_SHA256" in __*|"") fail "沒有指定 zip 的 SHA-256：用 Release 附的 install.sh，或加 --sha256" 2 ;; esac
[ -d "$DEST_DIR" ] && [ -w "$DEST_DIR" ] || fail "無法寫入 ${DEST_DIR}；改裝到自己的「應用程式」：AUM_INSTALL_DIR=~/Applications（不要用 sudo）" 2

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ZIP=$TMP/$NAME.zip
if [ -n "${AUM_ZIP:-}" ]; then
  cp "$AUM_ZIP" "$ZIP"
else
  URL=$REPO_URL/releases/download/v$VERSION/$NAME-$VERSION.zip
  say "下載 AI 用量 ${VERSION}…"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$ZIP" "$URL" || fail "下載失敗：$URL" 3
fi
GOT=$(shasum -a 256 "$ZIP" | awk '{print $1}')
[ "$GOT" = "$ZIP_SHA256" ] || fail "SHA-256 不符（預期 ${ZIP_SHA256}，實際 ${GOT}）：檔案可能損壞或被竄改，沒有安裝" 4
say "SHA-256 相符：$GOT"

ditto -x -k "$ZIP" "$TMP/x"
NEW=$TMP/x/$NAME.app
[ -f "$NEW/Contents/Info.plist" ] || fail "壓縮檔裡沒有 $NAME.app，沒有安裝" 4
GOT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW/Contents/Info.plist" 2>/dev/null || true)
[ "$GOT_ID" = "$BUNDLE_ID" ] || fail "壓縮檔裡的 App 不是 AI 用量（${GOT_ID:-沒有 bundle ID}），沒有安裝" 4
codesign --verify --deep --strict "$NEW" 2>/dev/null || fail "App 的簽章不完整（檔案可能損壞），沒有安裝" 4

quit_app
# 先放到同一個資料夾的暫存名稱，成功後才換掉舊版（失敗時舊版不受影響）
STAGE=$(mktemp -d "$DEST_DIR/.$NAME.installing.XXXXXX")
mv "$NEW" "$STAGE/$NAME.app"
if [ -d "$DEST" ]; then
  trash "$DEST"
  say "舊版本已移到垃圾桶"
fi
mv "$STAGE/$NAME.app" "$DEST"
rmdir "$STAGE"
say "已安裝：${DEST}（版本 $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "$VERSION")）"
if [ -f "$LEGACY_PLIST" ]; then
  say "偵測到 install-launchd.sh 安裝的收集器：App 不會另外註冊收集器，可以在設定 › 背景收集器 按「改用內建收集器」"
fi
if [ "$OPEN" = 1 ]; then
  open "$DEST"
  say "已打開。第一次打開會跑設定精靈，之後點選單列的圖示看用量。"
fi
