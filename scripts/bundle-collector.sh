#!/bin/bash
# 把 Python 執行環境與收集器放進已建置的 AIUsageMenuBar.app，加上內建收集器的 LaunchAgent，重新 ad-hoc 簽署（ADR-0013）。
#
#   scripts/bundle-collector.sh <AIUsageMenuBar.app> [--test-home <資料夾>]
#
# - Python：build/python-runtime/python（沒有就先執行 scripts/fetch-python-runtime.sh）→ Contents/Resources/python
# - 收集器：collector/usage_collector → Contents/Resources/python/lib/python3.13/site-packages（不依賴工作目錄）
# - LaunchAgent：apple/MacMenuBar/LaunchAgent/collector.plist.template → Contents/Library/LaunchAgents/<bundle ID>.collector.plist，
#   agent-sync.plist.template → <bundle ID>.agent-sync.plist（AI 狀態同步）
# - --test-home：安裝測試用。agent 加上 AI_USAGE_MONITOR_HOME＝<資料夾>/app、AUM_LAUNCH_AGENTS_DIR＝<資料夾>/LaunchAgents、
#   CLAUDE_CONFIG_DIR／CODEX_HOME＝<資料夾>/claude、codex（空的）、AUM_TESTING=1：只寫暫存資料夾，不看這台 Mac 真的舊安裝，
#   也不查真的帳號、不讀真的對話紀錄（要搭配不同的 bundle ID，見 scripts/build-release.sh --test-home）
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:?用法：bundle-collector.sh <AIUsageMenuBar.app> [--test-home <資料夾>]}
shift
TEST_HOME=
while [ $# -gt 0 ]; do
  case "$1" in
    --test-home) TEST_HOME=${2:?--test-home 要指定資料夾}; shift 2 ;;
    *) echo "不認得的參數：$1" >&2; exit 2 ;;
  esac
done
[ -f "$APP/Contents/Info.plist" ] || { echo "不是 App：$APP" >&2; exit 2; }
RUNTIME=$ROOT/build/python-runtime/python
[ -x "$RUNTIME/bin/python3.13" ] || "$ROOT/scripts/fetch-python-runtime.sh"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
LABEL=$BUNDLE_ID.collector
DEST=$APP/Contents/Resources/python
rm -rf "$DEST"
ditto "$RUNTIME" "$DEST"
SITE=$DEST/lib/python3.13/site-packages
mkdir -p "$SITE"
rsync -a --exclude __pycache__ --exclude '*.pyc' "$ROOT/collector/usage_collector/" "$SITE/usage_collector/"

EXTRA=
if [ -n "$TEST_HOME" ]; then
  mkdir -p "$TEST_HOME/app" "$TEST_HOME/LaunchAgents" "$TEST_HOME/claude" "$TEST_HOME/codex"
  TEST_HOME=$(cd "$TEST_HOME" && pwd)
  for pair in "AI_USAGE_MONITOR_HOME=$TEST_HOME/app" "AUM_LAUNCH_AGENTS_DIR=$TEST_HOME/LaunchAgents" \
              "CLAUDE_CONFIG_DIR=$TEST_HOME/claude" "CODEX_HOME=$TEST_HOME/codex" "AUM_TESTING=1"; do
    EXTRA+="        <key>${pair%%=*}</key>\n        <string>${pair#*=}</string>\n"
  done
fi
AGENTS=$APP/Contents/Library/LaunchAgents
mkdir -p "$AGENTS"
# 收集器（每 5 分鐘）與 AI 狀態同步（ADR-0019 第 2 節，沒有排程，App 以 launchctl kickstart 觸發）
SYNC_LABEL=${LABEL%.collector}.agent-sync
for pair in "collector|$LABEL" "agent-sync|$SYNC_LABEL"; do
  PLIST=$AGENTS/${pair#*|}.plist
  python3 - "$ROOT/apple/MacMenuBar/LaunchAgent/${pair%%|*}.plist.template" "$PLIST" "${pair#*|}" "$EXTRA" <<'PY'
import sys
template, out, label, extra = sys.argv[1:]
text = open(template).read().replace("__LABEL__", label).replace("__EXTRA_ENV__", extra.replace("\\n", "\n"))
open(out, "w").write(text)
PY
  plutil -lint "$PLIST" >/dev/null
done

# 內嵌的 Python 能載入收集器（-I：不受這台電腦的 PYTHON* 環境變數影響）
"$DEST/bin/python3.13" -I -B -c 'import usage_collector.__main__, usage_collector.setup' \
  || { echo "內嵌的 Python 無法載入收集器" >&2; exit 1; }

PY_VERSION=$("$DEST/bin/python3.13" -I -B -c 'import platform; print(platform.python_version())')

# 整個 App 重新 ad-hoc 簽署（Sign to Run Locally，不需要付費帳號；內嵌的執行檔一起簽）。
# 之後內嵌的 Python 一律以 -B 執行：寫出 __pycache__ 會讓簽章的資源清單不符（a sealed resource is missing or invalid）
codesign --force --deep -s - "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"
echo "已放入內建收集器：${LABEL}（Python ${PY_VERSION}，App $(du -sh "$APP" | awk '{print $1}')）"
