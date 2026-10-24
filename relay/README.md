# relay — Cloudflare Worker 中繼 API

Mac 收集器把最新一筆用量上傳到這裡，iPhone 再從這裡讀取。選擇 Cloudflare Worker 的理由見 [ADR-0001](../docs/adr/0001-cloudflare-worker-relay.md)。

## API

| 方法 | 路徑 | 驗證 | 回應 |
|---|---|---|---|
| `POST` | `/usage` | `Authorization: Bearer <WRITE_TOKEN>` | `204`；格式錯誤 `400`／`422`，超過 16 KB `413` |
| `GET` | `/usage` | `Authorization: Bearer <READ_TOKEN>` | `200` 最新一筆 JSON；尚無資料 `404` |

第二層（選用，需要 D1 綁定；[docs/tier2-setup.md](../docs/tier2-setup.md)、ADR-0011 第 2 節）：

| 方法 | 路徑 | 驗證 | 回應 |
|---|---|---|---|
| `POST` | `/tokens/daily` | `Authorization: Bearer <裝置密鑰 aumd_…>` | `200 {"device_id", "accepted"}`；以（裝置、日期、服務、模型）覆蓋寫入；格式錯誤 `400`／`422`，超過 256 KB `413` |
| `GET` | `/tokens/daily?from=YYYY-MM-DD` | `Authorization: Bearer <READ_TOKEN>` | `200 {"devices": […], "rows": […]}`：所有裝置從 `from` 起的每日加總與裝置清單 |
| `GET` | `/devices` | `Authorization: Bearer <ADMIN_TOKEN>` | 裝置清單（不含密鑰與雜湊） |
| `POST` | `/devices` | `Authorization: Bearer <ADMIN_TOKEN>` | `201 {"device_id", "name", "key"}`：密鑰只回傳這一次 |
| `POST` | `/devices/<id>/rotate` | `Authorization: Bearer <ADMIN_TOKEN>` | 新密鑰（`device_id` 與資料不變）；已撤銷 `409` |
| `POST` | `/devices/<id>/revoke` | `Authorization: Bearer <ADMIN_TOKEN>` | 撤銷；內容 `{"delete_data": true}` 時一併刪除它的每日加總 |

- 裝置密鑰只能寫 `/tokens/daily`；`READ_TOKEN`、`WRITE_TOKEN`、`ADMIN_TOKEN` 都不能上傳每日加總。中繼只存裝置密鑰的 SHA-256，`device_id` 由中繼依密鑰決定，內容中的裝置欄位一律不採用。
- 每列只收白名單欄位：`day`（400 天前到明天，UTC）、`provider`（`claude`／`codex`）、`model`（`claude-`、`gpt-`、`codex-`、`o`＋數字開頭，或 `other`，最長 64 字）、五種 Token、`task_seconds`、`longest_task_seconds`（0～10¹² 的整數）；每批最多 400 列、同一批不能有重複的列。
- 沒有 D1 綁定時這些端點回 `503`；`ADMIN_TOKEN` 未設定或與其他密鑰相同時 `/devices` 回 `503`。`/usage` 不受影響。
- 管理指令用 `scripts/relay-device.sh`（`add`／`list`／`rotate`／`revoke [--delete-data]`）。

- 驗證失敗一律回 `401`；兩把密鑰未設定或相同時回 `500`，拒絕服務。
- 只接受 `schema_version` 為支援版本的內容；KV 只保存最新一筆。
- 依 schema 驗證每個欄位（`providers` 必須是物件、`used_pct` 是有限且不為負的數字、日期為 ISO 8601、字串長度與服務／額度數量有上限），不合格回 `422`。
- 以白名單重建後才保存：只留 `schema_version`、`updated_at`、各服務的 `plan`／`error`／`windows`，以及額度的 `id`／`label`／`used_pct`／`resets_at`／`hidden`，其他欄位移除。**收集器新增欄位時要先更新 `src/index.ts`（`sanitizeSnapshot`）並重新部署**，否則新欄位會被丟掉。
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

第一次部署到新的 workers.dev 子網域時，HTTPS 憑證可能要等 1～數分鐘才生效，期間會看到 TLS handshake 失敗（curl 回 `000`），稍等即可。

`wrangler.toml` 填入自己的 KV id 後，若不想讓這個改動出現在 git 中，可以執行 `git update-index --skip-worktree relay/wrangler.toml`。

## 免費額度

KV 免費方案每天 1,000 次寫入。收集器每 5 分鐘上傳一次，每天約 288 次，在額度內。第二層的 D1 每台電腦每小時最多一批（通常只有今天與昨天的幾列），遠低於免費方案的上限。

## 開發

```bash
npm test      # Node 內建測試執行器，直接執行 TypeScript（Node 23.6 以上）
npm run dev   # 本機模擬 Worker
```
