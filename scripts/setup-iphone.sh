#!/bin/bash
# 第一次把 iPhone App 裝上手機、並和中繼配對（ADR-0012、ADR-0013 第 6 節）。
#
#   scripts/setup-iphone.sh                      # 檢查 → 建置並安裝 → 提示配對
#   scripts/setup-iphone.sh --auto-reinstall     # 另外安裝每 6 天自動重新簽署的排程
#   scripts/setup-iphone.sh --pair qr            # 安裝後在終端機顯示配對 QR 碼（iPhone 設定 →「掃描 QR 碼」）
#   scripts/setup-iphone.sh --pair code          # 安裝後向中繼要一組 10 分鐘的短碼（中繼要支援 /pair）
#   scripts/setup-iphone.sh --pair-only qr       # 只配對，不建置安裝
#   scripts/setup-iphone.sh --dry-run            # 只印出會做什麼：不寫設定、不建置、不讀 Keychain、不連網
#
# 其他選項：--team <Team ID>、--udid <iPhone UDID>（有多台手機時）。
# 免費 Apple ID 即可（Personal Team）：先在 Xcode → Settings → Accounts 登入，並用線連一次 iPhone、按「信任」。
# 腳本內不放任何帳號、密碼或密鑰；Team ID 與 UDID 寫進 config.json（不進版控）。
# QR 碼只含中繼網址與**讀取密鑰**（Keychain 的 AIUsageMonitor-relay-read），只畫在終端機，按 Enter 後清除。
#
# 結束碼：0 成功、2 參數或環境（Xcode、xcodegen、Team）、3 找不到手機或有多台、4 建置或安裝失敗、5 配對失敗
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$HOME/Library/Application Support/AIUsageMonitor"
CONFIG="$CONFIG_DIR/config.json"
PYTHON="${AUM_PYTHON:-python3}"
HELPER=("$PYTHON" "$REPO/scripts/reinstall_ios_helper.py")
UPDATE_CONFIG=("$PYTHON" "$REPO/collector/scripts/update-config.py" "$CONFIG")
READ_SERVICE="AIUsageMonitor-relay-read"
WRITE_SERVICE="AIUsageMonitor-relay-write"

TEAM_ARG="" UDID_ARG="" PAIR="" PAIR_ONLY=0 AUTO=0 DRY=0
fail() { echo "失敗：$1" >&2; exit "${2:-2}"; }
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
    case "$1" in
        --team) TEAM_ARG="${2:-}"; shift 2 || fail "--team 需要 Team ID" ;;
        --udid) UDID_ARG="${2:-}"; shift 2 || fail "--udid 需要 UDID" ;;
        --pair) PAIR="${2:-}"; shift 2 || fail "--pair 需要 qr 或 code" ;;
        --pair-only) PAIR="${2:-}"; PAIR_ONLY=1; shift 2 || fail "--pair-only 需要 qr 或 code" ;;
        --auto-reinstall) AUTO=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "不認得的選項：$1（見 --help）" ;;
    esac
done
case "$PAIR" in ""|qr|code) ;; *) fail "--pair 只接受 qr 或 code" ;; esac
[ -z "$TEAM_ARG" ] || [[ $TEAM_ARG =~ ^[A-Z0-9]{10}$ ]] || fail "Team ID 是 10 個大寫英數字（Xcode → Settings → Accounts）"
[ -z "$UDID_ARG" ] || [[ $UDID_ARG =~ ^[A-Fa-f0-9-]{20,40}$ ]] || fail "UDID 格式不正確"

ok() { echo "✅ $1"; }
todo() { echo "⚠️  $1"; }
run() {  # 實際執行；--dry-run 時只印出
    if [ "$DRY" = 1 ]; then echo "（dry-run）會執行：$*"; else "$@"; fi
}
config_get() {
    "$PYTHON" -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")
except (FileNotFoundError, ValueError): print("")' "$CONFIG" "$1"
}
valid_token() { local LC_ALL=C; [[ ${#1} -ge 16 && ${#1} -le 256 && $1 =~ ^[!-~]+$ ]]; }

# ---------- 1～4：安裝 ----------
if [ "$PAIR_ONLY" = 0 ]; then
    xcodebuild -version >/dev/null 2>&1 \
        || fail "找不到 Xcode。請從 App Store 安裝 Xcode、打開一次，再執行 sudo xcode-select -s /Applications/Xcode.app"
    ok "Xcode：$(xcodebuild -version 2>/dev/null | head -1)"
    command -v xcodegen >/dev/null 2>&1 || fail "找不到 xcodegen，請先執行 brew install xcodegen"
    ok "xcodegen"

    TEAM=${TEAM_ARG:-$(config_get development_team)}
    if [ -z "$TEAM" ]; then
        TEAM=$("${HELPER[@]}" team 2>/dev/null) \
            || fail "找不到唯一的 Team ID：在 Xcode → Settings → Accounts 登入 Apple ID，或用 --team 指定"
    fi
    ok "Team ID：$TEAM"

    DEVICES_JSON=$(mktemp)
    trap 'rm -f "$DEVICES_JSON"' EXIT
    xcrun devicectl list devices --timeout 60 --json-output "$DEVICES_JSON" >/dev/null 2>&1 \
        || fail "devicectl 無法列出裝置（Xcode 需要 15 以上）" 3
    IPHONES=$("${HELPER[@]}" iphones "$DEVICES_JSON")
    UDID=${UDID_ARG:-$(config_get iphone_udid)}
    if [ -z "$UDID" ]; then
        count=$(printf '%s' "$IPHONES" | grep -c . || true)
        if [ "$count" -eq 0 ]; then
            fail "找不到 iPhone：用線連接、解鎖並按「信任這部電腦」，再到 iPhone 的「設定 → 隱私權與安全性」打開「開發者模式」" 3
        fi
        if [ "$count" -gt 1 ]; then
            echo "有 $count 台 iPhone，用 --udid 指定其中一台：" >&2
            cut -f1,2 <<<"$IPHONES" | sed 's/^/  /' >&2
            exit 3
        fi
        UDID=$(cut -f1 <<<"$IPHONES")
    fi
    DEVICE=$(grep "^$UDID"$'\t' <<<"$IPHONES") || fail "清單中沒有這台 iPhone（${UDID}），確認它已連線並信任這台 Mac" 3
    ok "iPhone：$(cut -f2 <<<"$DEVICE")（$(cut -f3 <<<"$DEVICE")）"

    run "${UPDATE_CONFIG[@]}" development_team "$TEAM" || fail "無法寫入 config.json"
    run "${UPDATE_CONFIG[@]}" iphone_udid "$UDID" || fail "無法寫入 config.json"

    echo "建置並安裝中（第一次約需數分鐘；手機要解鎖）……"
    if ! run "$REPO/scripts/reinstall-ios.sh"; then
        fail "建置或安裝失敗，見 ~/Library/Logs/AIUsageMonitor/reinstall.log。第一次安裝後，到 iPhone 的「設定 → 一般 → VPN 與裝置管理」信任你的 Apple ID" 4
    fi
    [ "$DRY" = 1 ] || ok "已安裝。第一次打開前，到 iPhone 的「設定 → 一般 → VPN 與裝置管理」信任你的 Apple ID"

    if [ "$AUTO" = 1 ]; then
        run "$REPO/scripts/install-reinstall-launchd.sh" || fail "無法安裝自動重新簽署排程" 4
        [ "$DRY" = 1 ] || ok "已安裝自動重新簽署（每 6 天；免費 Apple ID 的簽署 7 天後失效）"
    else
        todo "免費 Apple ID 的簽署 7 天後失效：加上 --auto-reinstall 讓 Mac 每 6 天自動重新安裝"
    fi
fi

# ---------- 5：配對 ----------
if [ -z "$PAIR" ]; then
    todo "還沒配對：執行 scripts/setup-iphone.sh --pair-only qr，在 iPhone 的設定按「掃描 QR 碼」"
    exit 0
fi

RELAY_URL=$(config_get relay_url)
RELAY_URL=${RELAY_URL%/}
[[ $RELAY_URL == https://* ]] || fail "config.json 沒有 https 的 relay_url：先依 relay/README.md 部署中繼，並執行 collector/scripts/set-relay.sh" 5
ok "中繼：${RELAY_URL#https://}"

if [ "$PAIR" = qr ]; then
    if [ "$DRY" = 1 ]; then
        echo "（dry-run）會從 Keychain 讀取 ${READ_SERVICE}（沒有時請你貼上一次），在終端機顯示 QR 碼，按 Enter 後清除"
        exit 0
    fi
    READ=$(security find-generic-password -s "$READ_SERVICE" -a default -w 2>/dev/null || true)
    if [ -z "$READ" ]; then
        echo "Keychain 還沒有讀取密鑰。貼上部署中繼時設定的 READ_TOKEN（不是寫入密鑰），會存進 Keychain：" >&2
        security add-generic-password -U -s "$READ_SERVICE" -a default -w || fail "無法存入 Keychain" 5
        READ=$(security find-generic-password -s "$READ_SERVICE" -a default -w 2>/dev/null || true)
    fi
    valid_token "$READ" || fail "讀取密鑰的格式不正確（16～256 個可見字元）" 5
    WRITE=$(security find-generic-password -s "$WRITE_SERVICE" -a default -w 2>/dev/null || true)
    [ -z "$WRITE" ] || [ "$WRITE" != "$READ" ] || fail "Keychain 裡的讀取密鑰和寫入密鑰相同：寫入密鑰不能放進 iPhone，請輪換其中一把" 5
    unset WRITE
    QR=$(printf '%s\n%s\n' "$RELAY_URL" "$READ" | swift "$REPO/scripts/render-qr.swift") || fail "無法產生 QR 碼" 5
    unset READ
    echo
    echo "$QR"
    echo
    echo "在 iPhone 打開 AI 用量 → 設定 →「掃描 QR 碼」。QR 碼含讀取密鑰，不要截圖或拍照分享。"
    read -r -p "配對完成後按 Enter 清除畫面…" _ </dev/tty || true
    unset QR
    printf '\033[3J\033[H\033[2J'  # 清除畫面與捲動緩衝
    ok "已清除畫面"
    exit 0
fi

# 短碼：以寫入密鑰呼叫中繼的 POST /pair（密鑰經標準輸入交給 curl，不出現在程序參數）
if [ "$DRY" = 1 ]; then
    echo "（dry-run）會從 Keychain 讀取 ${WRITE_SERVICE}，呼叫 ${RELAY_URL}/pair 取得 10 分鐘的短碼"
    exit 0
fi
WRITE=$(security find-generic-password -s "$WRITE_SERVICE" -a default -w 2>/dev/null || true)
[ -n "$WRITE" ] || fail "Keychain 沒有寫入密鑰：先執行 collector/scripts/set-relay.sh" 5
RESPONSE=$(mktemp)
trap 'rm -f "$RESPONSE" "${DEVICES_JSON:-}"' EXIT
STATUS=$(printf 'Authorization: Bearer %s\n' "$WRITE" \
    | curl -sS -o "$RESPONSE" -w '%{http_code}' --max-time 20 -X POST -H @- --data '' "$RELAY_URL/pair") || STATUS=000
unset WRITE
case "$STATUS" in
    200) ;;
    404) fail "中繼還不支援短碼（要部署含 /pair 的版本，見 ADR-0012），改用 --pair-only qr" 5 ;;
    401) fail "中繼拒絕寫入密鑰（HTTP 401）：確認 Keychain 的 ${WRITE_SERVICE} 與中繼的 WRITE_TOKEN 相同" 5 ;;
    000) fail "無法連線到中繼" 5 ;;
    *) fail "中繼回應錯誤（HTTP ${STATUS}）" 5 ;;
esac
LINE=$("$PYTHON" -c 'import json,re,sys
d = json.load(open(sys.argv[1]))
code, exp = d.get("code", ""), d.get("expires_at", "")
if not re.fullmatch(r"[0-9A-HJKMNP-TV-Z]{8}", code): sys.exit(1)
print(code[:4] + "-" + code[4:] + "\t" + str(exp))' "$RESPONSE") || fail "中繼回應的格式不正確" 5
echo
echo "    網址：${RELAY_URL#https://}"
echo "    短碼：${LINE%%$'\t'*}"
echo
echo "在 iPhone 打開 AI 用量 → 設定 →「輸入短碼」。短碼 10 分鐘內有效（到期：${LINE##*$'\t'}），只能用一次。"
