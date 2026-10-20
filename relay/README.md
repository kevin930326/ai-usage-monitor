# relay — Cloudflare Worker 中繼 API

Mac 收集器把最新一筆用量上傳到這裡，iPhone 再從這裡讀取。選擇 Cloudflare Worker 的理由見 [ADR-0001](../docs/adr/0001-cloudflare-worker-relay.md)。

## API

| 方法 | 路徑 | 驗證 | 回應 |
|---|---|---|---|
| `POST` | `/usage` | `Authorization: Bearer <WRITE_TOKEN>` | `204`；格式錯誤 `400`／`422`，超過 16 KB `413` |
| `GET` | `/usage` | `Authorization: Bearer <READ_TOKEN>` | `200` 最新一筆 JSON；尚無資料 `404` |

- 驗證失敗一律回 `401`；兩把密鑰未設定或相同時回 `500`，拒絕服務。
- 只接受 `schema_version` 為支援版本的內容；KV 只保存最新一筆。
- 密鑰比對先雜湊再逐 byte 比較，避免時序攻擊。

## 部署

需要 Cloudflare 帳號（免費方案即可）。

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

## 免費額度

KV 免費方案每天 1,000 次寫入。收集器每 5 分鐘上傳一次，每天約 288 次，在額度內。

## 開發

```bash
npm test      # Node 內建測試執行器，直接執行 TypeScript（Node 23.6 以上）
npm run dev   # 本機模擬 Worker
```
