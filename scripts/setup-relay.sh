#!/bin/bash
# 一次部署自己的中繼（Cloudflare Worker，ADR-0001），並把 Mac 收集器接上去。
#
#   scripts/setup-relay.sh              # 檢查 → 登入 Cloudflare → 建 KV → 部署 → 設定兩把密鑰 → 寫收集器設定
#   scripts/setup-relay.sh --dry-run    # 只檢查並印出會做什麼：不登入、不建立任何 Cloudflare 資源、不產生密鑰、不寫設定
#   scripts/setup-relay.sh --name my-relay   # Worker 名稱（預設 ai-usage-relay）
#
# 需要：Node.js 23.6 以上、免費的 Cloudflare 帳號（第一次執行時會打開瀏覽器登入）。
# 偵測到既有的部署或設定時**停止、不覆蓋**：config.json 已有 relay_url、Keychain 已有寫入密鑰、
# relay/wrangler.local.toml 已存在、或 Cloudflare 上已有同名的 Worker。要重新部署請照 relay/README.md 手動進行。
#
# 密鑰以 openssl 產生，只經由標準輸入交給 wrangler 與 security（不出現在程序參數、不寫檔、不印出）：
#   寫入密鑰 → Cloudflare secret WRITE_TOKEN ＋ Mac Keychain AIUsageMonitor-relay-write
#   讀取密鑰 → Cloudflare secret READ_TOKEN  ＋ Mac Keychain AIUsageMonitor-relay-read（給 setup-iphone.sh 顯示配對 QR 碼）
# KV id 寫在 relay/wrangler.local.toml（不進版控），不改 repo 裡的 relay/wrangler.toml。
#
# 結束碼：0 成功、2 環境或參數（Node、登入）、3 已有部署或設定（沒有變更）、4 Cloudflare 操作失敗、5 本機設定失敗
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RELAY="${AUM_RELAY_DIR:-$REPO/relay}"   # 測試用：指到暫存的 relay 複本
CONFIG_DIR="${AI_USAGE_MONITOR_HOME:-$HOME/Library/Application Support/AIUsageMonitor}"
CONFIG="$CONFIG_DIR/config.json"
LOCAL_TOML="$RELAY/wrangler.local.toml"
READ_SERVICE="AIUsageMonitor-relay-read"
WRITE_SERVICE="AIUsageMonitor-relay-write"
NAME="ai-usage-relay"
DRY=0

fail() { echo "失敗：$1" >&2; exit "${2:-2}"; }
ok() { echo "✅ $1"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --name) NAME="${2:-}"; shift 2 || fail "--name 需要 Worker 名稱" ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "不認得的選項：$1（見 --help）" ;;
    esac
done
[[ $NAME =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail "Worker 名稱只能用小寫英數字與連字號"

# wrangler 一律用 relay/ 裡鎖定版本的那份（package-lock.json），不用全域安裝的
# 不寫 wrangler 自己的磁碟日誌、強制遮蔽（繼承 WRANGLER_LOG_SANITIZE=false 時日誌會含 secret put 的內容；Codex C-01）
wrangler() {
    (cd "$RELAY" && WRANGLER_WRITE_LOGS=false WRANGLER_LOG_SANITIZE=true WRANGLER_LOG=warn \
        WRANGLER_SEND_METRICS=false npx --no-install wrangler "$@")
}
config_get() {
    python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")
except (FileNotFoundError, ValueError): print("")' "$CONFIG" "$1"
}

# ---------- 1. 環境 ----------
command -v node >/dev/null 2>&1 || fail "找不到 Node.js：到 https://nodejs.org 安裝 LTS 版（23.6 以上）"
NODE_VERSION=$(node -p 'process.versions.node' 2>/dev/null)
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>23||(a===23&&b>=6)?0:1)' \
    || fail "Node.js ${NODE_VERSION} 太舊，需要 23.6 以上"
ok "Node.js ${NODE_VERSION}"
command -v openssl >/dev/null 2>&1 || fail "找不到 openssl"
[ -f "$RELAY/package-lock.json" ] || fail "找不到 relay/package-lock.json"

# ---------- 2. 既有的部署或設定：停止、不覆蓋 ----------
existing=()
[ -z "$(config_get relay_url)" ] || existing+=("config.json 已有 relay_url（$(config_get relay_url)）")
security find-generic-password -s "$WRITE_SERVICE" -a default >/dev/null 2>&1 \
    && existing+=("Keychain 已有寫入密鑰 ${WRITE_SERVICE}")
[ ! -e "$LOCAL_TOML" ] || existing+=("relay/wrangler.local.toml 已存在")
if [ ${#existing[@]} -gt 0 ]; then
    echo "已經設定過中繼，沒有做任何變更：" >&2
    printf '  - %s\n' "${existing[@]}" >&2
    echo "要換一個中繼，請照 relay/README.md 手動部署，再執行 collector/scripts/set-relay.sh。" >&2
    exit 3
fi
ok "這台 Mac 還沒有設定中繼"

if [ ! -d "$RELAY/node_modules" ]; then
    if [ "$DRY" = 1 ]; then
        echo "（dry-run）會執行：npm ci（relay/，依 package-lock.json 安裝 wrangler）"
    else
        (cd "$RELAY" && npm ci --no-audit --no-fund) || fail "npm ci 失敗" 2
    fi
fi

if [ "$DRY" = 1 ]; then
    cat <<EOF
（dry-run）接下來會：
  1. wrangler whoami；沒有登入時執行 wrangler login（打開瀏覽器）
  2. 確認 Cloudflare 上沒有名為 ${NAME} 的 Worker（有就停止）
  3. wrangler kv namespace create USAGE_KV，把 id 寫進 relay/wrangler.local.toml
  4. wrangler deploy --config wrangler.local.toml --name ${NAME}
  5. 產生兩把不同的密鑰，經標準輸入執行 wrangler secret put WRITE_TOKEN／READ_TOKEN
  6. 以讀取密鑰確認 GET /usage 回 404（還沒有資料）
  7. 把網址寫進 config.json，兩把密鑰存進 Keychain（${WRITE_SERVICE}、${READ_SERVICE}）
EOF
    exit 0
fi

# ---------- 3. 登入 Cloudflare ----------
if ! wrangler whoami --json >/dev/null 2>&1; then
    echo "還沒有登入 Cloudflare，接著會打開瀏覽器（沒有帳號可以免費註冊）……"
    wrangler login || fail "Cloudflare 登入失敗或取消" 2
    wrangler whoami --json >/dev/null 2>&1 || fail "登入後仍無法取得帳號資訊" 2
fi
ok "已登入 Cloudflare"

# 只有 Cloudflare 明確回答「沒有這個 Worker」才繼續；查詢失敗（網路、權限）時停止，避免覆蓋別人的部署
if LIST_OUT=$(wrangler deployments list --name "$NAME" 2>&1); then
    fail "Cloudflare 上已經有名為 ${NAME} 的 Worker，沒有做任何變更。用 --name 換一個名稱，或照 relay/README.md 手動處理" 3
fi
grep -Eqi 'does not exist|not found|10007' <<<"$LIST_OUT" \
    || fail "無法確認 Cloudflare 上有沒有 ${NAME}（網路或權限問題；可執行 npx wrangler deployments list --name ${NAME} 查看）" 4
ok "沒有同名的 Worker（${NAME}）"

# ---------- 4. KV 與部署 ----------
KV_OUT=$(wrangler kv namespace create USAGE_KV 2>&1) || fail "建立 KV 失敗（可在 relay/ 執行 npx wrangler kv namespace list 確認）" 4
KV_ID=$(grep -Eo '[0-9a-f]{32}' <<<"$KV_OUT" | head -1)
[ -n "$KV_ID" ] || fail "看不懂 wrangler 的輸出，找不到 KV id" 4
ok "已建立 KV（${KV_ID}）"
cat >"$LOCAL_TOML" <<EOF
# scripts/setup-relay.sh 產生（不進版控）。部署：npx wrangler deploy --config wrangler.local.toml
name = "${NAME}"
main = "src/index.ts"
compatibility_date = "$(sed -n 's/^compatibility_date = "\(.*\)"/\1/p' "$RELAY/wrangler.toml")"

[[kv_namespaces]]
binding = "USAGE_KV"
id = "${KV_ID}"
EOF

DEPLOY_OUT=$(wrangler deploy --config wrangler.local.toml 2>&1) || fail "部署失敗（可在 relay/ 執行 npx wrangler deploy --config wrangler.local.toml 看完整訊息）" 4
URL=$(grep -Eo "https://${NAME}\.[A-Za-z0-9-]+\.workers\.dev" <<<"$DEPLOY_OUT" | head -1)
[ -n "$URL" ] || fail "部署成功但找不到 workers.dev 網址（見 Cloudflare 主控台）" 4
ok "已部署：${URL#https://}"

# ---------- 5. 密鑰 ----------
token() { openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'; }
WRITE=$(token); READ=$(token)
[ ${#WRITE} -ge 40 ] && [ ${#READ} -ge 40 ] && [ "$WRITE" != "$READ" ] || fail "無法產生密鑰" 5
printf '%s' "$WRITE" | wrangler secret put WRITE_TOKEN --config wrangler.local.toml >/dev/null 2>&1 \
    || fail "設定 WRITE_TOKEN 失敗（重跑前先刪除 relay/wrangler.local.toml 與 Cloudflare 上的 ${NAME}）" 4
printf '%s' "$READ" | wrangler secret put READ_TOKEN --config wrangler.local.toml >/dev/null 2>&1 \
    || fail "設定 READ_TOKEN 失敗（重跑前先刪除 relay/wrangler.local.toml 與 Cloudflare 上的 ${NAME}）" 4
ok "已設定兩把密鑰"

# 新的 workers.dev 子網域憑證可能要等 1～數分鐘；最多等 3 分鐘
STATUS=000
for _ in $(seq 1 18); do
    STATUS=$(printf 'Authorization: Bearer %s\n' "$READ" \
        | curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H @- "$URL/usage" 2>/dev/null) || STATUS=000
    [ "$STATUS" = 000 ] || break
    sleep "${AUM_RETRY_SECONDS:-10}"
done
case "$STATUS" in
    404) ok "中繼正常（還沒有資料）" ;;
    000) echo "⚠️  還連不到中繼（新網址的 HTTPS 憑證可能還沒生效），設定照常寫入，稍後收集器會自動上傳" ;;
    *) fail "中繼回應 HTTP ${STATUS}（預期 404），檢查 Cloudflare 主控台" 4 ;;
esac

# ---------- 6. 本機設定 ----------
mkdir -p "$CONFIG_DIR"
python3 "$REPO/collector/scripts/update-config.py" "$CONFIG" relay_url "$URL" || fail "無法寫入 config.json" 5
# security -i 從標準輸入讀指令，密鑰不出現在程序參數（base64url 不含空白與引號）
printf 'add-generic-password -U -s %s -a default -w %s\nadd-generic-password -U -s %s -a default -w %s\n' \
    "$WRITE_SERVICE" "$WRITE" "$READ_SERVICE" "$READ" | security -i >/dev/null 2>&1 || fail "無法存入 Keychain" 5
unset WRITE READ
ok "已寫入 config.json 與 Keychain"

cat <<EOF

完成。收集器下一次執行（5 分鐘內）會開始上傳。
接著把 iPhone 接上：
  scripts/setup-iphone.sh --pair-only qr     # 在 iPhone 的設定按「掃描 QR 碼」
EOF
