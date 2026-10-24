# relay — Cloudflare Worker 中繼 API

Mac 收集器把最新一筆用量上傳到這裡，iPhone 再從這裡讀取。選擇 Cloudflare Worker 的理由見 [ADR-0001](../docs/adr/0001-cloudflare-worker-relay.md)。

## API

| 方法 | 路徑 | 驗證 | 回應 |
|---|---|---|---|
| `POST` | `/usage` | `Authorization: Bearer <WRITE_TOKEN>` | `204`；格式錯誤 `400`／`422`，超過 16 KB `413` |
| `GET` | `/usage` | `Authorization: Bearer <READ_TOKEN>` | `200` 最新一筆 JSON；尚無資料 `404` |
| `POST` | `/pair` | `Authorization: Bearer <WRITE_TOKEN>` | `200` `{"code", "expires_at"}`：iPhone 配對用的一次性短碼（[ADR-0012](../docs/adr/0012-iphone-pairing.md)） |
| `POST` | `/pair/claim` | 不需要；內容 `{"code": "XXXX-XXXX"}` | `200` `{"read_token"}`；錯誤、到期、沒有短碼一律 `403` |

- 驗證失敗一律回 `401`；兩把密鑰未設定或相同時回 `500`，拒絕服務。
- 只接受 `schema_version` 為支援版本的內容；KV 只保存最新一筆。
- 依 schema 驗證每個欄位（`providers` 必須是物件、`used_pct` 是有限且不為負的數字、日期為 ISO 8601、字串長度與服務／額度數量有上限），不合格回 `422`。
- 以白名單重建後才保存：只留 `schema_version`、`updated_at`、各服務的 `plan`／`error`／`windows`，以及額度的 `id`／`label`／`used_pct`／`resets_at`／`hidden`，其他欄位移除。**收集器新增欄位時要先更新 `src/index.ts`（`sanitizeSnapshot`）並重新部署**，否則新欄位會被丟掉。
- 密鑰比對先雜湊再逐 byte 比較，避免時序攻擊。
- 短碼（`scripts/setup-iphone.sh --pair code` 會呼叫 `/pair`）：8 個 Crockford base32 字元（約 40 位元），10 分鐘到期、兌換成功立即刪除、錯 5 次作廢；KV 只存 SHA-256 雜湊，同一時間只有一組。`/pair/claim` 只回讀取密鑰，寫入密鑰永遠不經過這裡。
  - 錯誤次數記在每組短碼自己的鍵（`pair-fail:<雜湊前 16 字>`），錯誤的請求從不寫回短碼本身，所以晚到的寫入不會讓已兌換或已被取代的短碼復活；刪除前會再讀一次，只刪仍是同一組的短碼（再讀與刪除之間仍有極短空窗：舊碼被刪的同時 Mac 剛好發新碼，新碼可能一起被刪，重新產生一組即可）。
  - 格式不對的兌換請求（不是 8 個有效字元、不是 JSON）直接回 403，不讀寫 KV、不算錯誤次數。格式正確的錯誤短碼仍會計次：知道你正在配對的人可以用 5 次猜測讓這組短碼作廢（只能阻擋，拿不到密鑰），這時改用 QR 碼或重新產生一組。
  - 已知限制：KV 最終一致且沒有條件更新或交易，所以「一次性」不是絕對保證：
    - 同一組短碼同時送出的正確請求可能都兌換成功；刪除最多約 60 秒才傳到所有節點，這段時間內其他節點仍可能兌換。
    - 同時大量猜測時，實際嘗試次數可能略多於 5 次。
    - 要完全序列化得改用 Durable Objects（架構變更，需要另寫 ADR）。
    - 短碼仍要先被知道才能利用，換到的也只有讀取密鑰。40 位元的短碼即使被猜上千次，命中機率仍約十億分之一，而且攻擊者得在這 10 分鐘內知道有人正在配對。

## 部署

需要 Cloudflare 帳號（免費方案即可）。

### 一次完成（FR-56）

```bash
scripts/setup-relay.sh --dry-run    # 先看會做什麼：不登入、不建立資源、不產生密鑰、不寫設定
scripts/setup-relay.sh              # 登入 Cloudflare → 建 KV → 部署 → 設定兩把密鑰 → 寫收集器設定
```

- 需要 Node.js 23.6 以上；wrangler 用 `relay/package-lock.json` 鎖定的版本。
- KV 命名為 `<Worker 名稱>-usage`（預設 `ai-usage-relay-usage`，binding 仍是 `USAGE_KV`），id 寫在 `relay/wrangler.local.toml`（不進版控），不改 `relay/wrangler.toml`。
- 兩把密鑰以 `openssl rand` 產生，只經由標準輸入交給 `wrangler secret put` 與 `security`，不印出、不寫檔：寫入密鑰存 Keychain `AIUsageMonitor-relay-write`，讀取密鑰存 `AIUsageMonitor-relay-read`（`scripts/setup-iphone.sh --pair-only qr` 用來顯示配對 QR 碼）。
- **已經設定過就停止、不覆蓋**：config.json 已有 `relay_url`、Keychain 已有寫入密鑰、`relay/wrangler.local.toml` 已存在，Cloudflare 上已有同名的 Worker，或已有同名的 KV（`--name` 可以換名稱；帳號裡其他名稱的 KV 不會被沿用或改動）；查不到 Worker 狀態（網路、權限）時也停止。
- 中途失敗（例如設定密鑰時斷線）時，錯誤訊息會列出這次建立的 KV id 與清理指令（`npx wrangler delete --config wrangler.local.toml`、`npx wrangler kv namespace delete --namespace-id <id>`、`rm wrangler.local.toml`），照做後重跑，或改用下面的手動步驟。
- 結束碼：0 成功、2 環境或登入、3 已有部署或設定（沒有變更）、4 Cloudflare 操作失敗、5 本機設定失敗。

### 手動

```bash
cd relay
npm install
npx wrangler login                          # 用瀏覽器登入 Cloudflare
npx wrangler kv namespace create USAGE_KV   # 把輸出的 id 填進 wrangler.toml

# 產生兩把不同的密鑰，分別貼進下面兩個指令的提示
openssl rand -base64 32
npx wrangler secret put WRITE_TOKEN
npx wrangler secret put READ_TOKEN

npm run deploy                              # 會印出 https://ai-usage-relay.<帳號>.workers.dev
```

接著在 Mac 上設定收集器（見 [collector](../collector/README.md#設定中繼-api)）：

```bash
../collector/scripts/set-relay.sh https://ai-usage-relay.<帳號>.workers.dev
```

`READ_TOKEN` 之後要填進 iOS App；`WRITE_TOKEN` 只存在 Mac 的 Keychain。

## 驗證

```bash
curl -i https://ai-usage-relay.<帳號>.workers.dev/usage -H "Authorization: Bearer <READ_TOKEN>"
```

第一次部署到新的 workers.dev 子網域時，HTTPS 憑證可能要等 1～數分鐘才生效，期間會看到 TLS handshake 失敗（curl 回 `000`），稍等即可。

`wrangler.toml` 填入自己的 KV id 後，若不想讓這個改動出現在 git 中，可以執行 `git update-index --skip-worktree relay/wrangler.toml`。

## 免費額度

KV 免費方案每天 1,000 次寫入。收集器每 5 分鐘上傳一次，每天約 288 次，在額度內。

## 開發

```bash
npm test      # Node 內建測試執行器，直接執行 TypeScript（Node 23.6 以上）
npm run dev   # 本機模擬 Worker
```
