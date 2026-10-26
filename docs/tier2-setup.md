# 第二層：多台電腦的 Token 合併（FR-49、ADR-0011 第 2 節）

讓 Mac 的統計卡片與完整統計視窗顯示「所有電腦（N 台）」：每台裝了收集器的電腦把**每日加總**上傳到你自己的中繼（Cloudflare Worker＋D1），存了讀取密鑰的電腦（Mac 預設；PC 加 `-ReadKey`）再下載其他電腦的加總寫進本機的 `history.sqlite3`。選單列 App 與 Windows App 本身仍然不連網、不持有密鑰。

- **選用**。不設定時什麼都不上傳，面板一律是「這台 Mac」（Mac 單機使用者永遠不上傳）。
- 只上傳：日期、服務（`claude`／`codex`）、模型名稱、輸入／快取寫入／快取讀取／輸出／推理 Token、任務秒數合計、最長任務。**不上傳**每小時資料、任務次數、專案名稱、路徑、檔名、對話內容、session ID、訊息 ID。
- 每台電腦一把**寫入密鑰**（`aumd_…`），中繼只存它的 SHA-256；遺失的電腦可以單獨撤銷。
- 其他電腦的數字是它們最後一次上傳的每日加總（有變動時每小時上傳一次＋日期改變後的第一輪；沒有新的用量就不上傳）；超過 48 小時沒有上傳的電腦在切換選單中標示「N 天前更新」（沒在用的電腦也會這樣標示）。

## 需要

- 已部署的中繼（[relay/README.md](../relay/README.md)），Mac 已用 `collector/scripts/set-relay.sh` 設定過網址
- 中繼的讀取密鑰（`READ_TOKEN`，iPhone App 用的那把）
- Windows PC 已依 [docs/windows.md](windows.md) 安裝收集器（只有 Mac 時不需要第二層）

## 1. 在中繼建立 D1 資料庫（只做一次）

```bash
cd relay
npx wrangler d1 create ai-usage-tokens
```

把輸出的 `database_id` 填進 `relay/wrangler.toml`，並取消註解 `[[d1_databases]]` 那一段（5 行）。用 `scripts/setup-relay.sh` 部署的，設定在 `relay/wrangler.local.toml`：把同一段加進那個檔案，下面的 `wrangler` 指令都加上 `--config wrangler.local.toml`（`npm run deploy` 改成 `npx wrangler deploy --config wrangler.local.toml`）：

```toml
[[d1_databases]]
binding = "DB"
database_name = "ai-usage-tokens"
database_id = "<上面輸出的 id>"
migrations_dir = "migrations"
```

建立資料表、設定管理密鑰，再部署：

```bash
npx wrangler d1 migrations apply ai-usage-tokens --remote
openssl rand -base64 32                 # 產生管理密鑰，貼進下一行的提示；和 READ_TOKEN／WRITE_TOKEN 不同
npx wrangler secret put ADMIN_TOKEN
npm run deploy
```

- 管理密鑰只用在 `scripts/relay-device.sh`（新增、列出、換新、撤銷裝置），不要存進任何電腦的設定。建議存在密碼管理器。
- 沒有 D1 綁定時 `/tokens/daily` 與 `/devices` 回 `503`，`/usage`（iPhone）照常。
- 不想讓 `wrangler.toml` 的改動出現在 git：`git update-index --skip-worktree relay/wrangler.toml`。
- 中繼只保留 400 天：每月排程刪除更早的每日加總（ADR-0014 D-4）。部署設定要加 `[triggers]`，見 [relay/README.md](../relay/README.md)「每月清理的排程」。Mac 已下載的其他電腦數字依 Mac 自己的保留期間保存，不會因為中繼刪除而消失（收集器只取代最近 399 天）。

## 2. 為每台電腦產生寫入密鑰

在 Mac 上（任何有 `curl` 的電腦都可以）：

```bash
scripts/relay-device.sh add Mac
scripts/relay-device.sh add 工作PC
```

- 每次印出一把 `aumd_…`，**只顯示這一次**（中繼只存雜湊），馬上貼到下面的設定步驟。
- 管理密鑰：提示輸入，或事先設定環境變數 `AUM_ADMIN_TOKEN`。網址取自 `config.json` 的 `relay_url`（或 `--url`）。
- 名稱最長 32 個字元，會顯示在面板的裝置切換中。

## 3. 在 Mac 開啟第二層

```bash
collector/scripts/set-tier2.sh
```

依提示貼上這台 Mac 的寫入密鑰與 `READ_TOKEN`（不顯示；檢查格式後經標準輸入交給 `security`，不經過指令列、不留在 shell 歷史紀錄；格式不對時當場說明並重新詢問，見第 4 節最後），兩把都存在 Keychain（`AIUsageMonitor-device-key`、`AIUsageMonitor-relay-read`）。收集器下一輪（5 分鐘內）開始上傳；第一次上傳一年的資料會分幾輪（每輪最多 2,000 列）。

| 選項 | 作用 |
|---|---|
| `--no-read-key` | 只上傳、不下載：移除之前存的讀取密鑰與本機的其他電腦資料（這台 Mac 的面板不顯示其他電腦） |
| `--disable` | 關閉上傳與下載，刪除本機的其他電腦資料（面板回到「這台 Mac」）；Keychain 的密鑰與中繼上的資料不動 |

## 4. 在 Windows PC 開啟第二層

PowerShell（不需要系統管理員），在 repo 的 `collector` 資料夾：

```powershell
powershell -ExecutionPolicy Bypass -File windows\set-tier2.ps1 -RelayUrl https://ai-usage-relay.<帳號>.workers.dev
```

- 依提示貼上這台 PC 的寫入密鑰（不顯示），存在 Windows 認證管理員（一般認證 `AIUsageMonitor/device-key`），不寫進任何檔案。
- 預設只上傳、不下載。要在 PC 上（Windows App，[ADR-0015](adr/0015-windows-desktop-app.md)）看「所有電腦」時加 `-ReadKey`，再貼上 `READ_TOKEN`（存在 `AIUsageMonitor/relay-read`）；收集器第一次上傳成功後每小時下載其他電腦的每日加總。
- PC 仍**不上傳額度快照**（`/usage` 只由 Mac 上傳，避免兩台互相覆蓋、iPhone 的更新時間來回跳，ADR-0015 第 3 節）。

| 選項 | 作用 |
|---|---|
| `-ReadKey` | 也存讀取密鑰，下載其他電腦的每日加總 |
| `-NoReadKey` | 刪除讀取密鑰與本機的其他電腦資料，回到只上傳 |
| （兩者都不加） | 不動之前的讀取密鑰設定（例如只換寫入密鑰） |
| `-KeepDeviceKey` | 沿用已存的寫入密鑰、不重新提示（例如之後只想加 `-ReadKey`） |
| `-Disable` | 關閉上傳與下載，刪除本機的其他電腦資料（認證管理員裡的密鑰保留） |

貼上的密鑰會先檢查（Mac 的 `set-tier2.sh` 相同）：去掉前後的空白與換行；寫入密鑰必須以 `aumd_` 開頭、共 48 個字元；讀取密鑰至少 20 個字元、不含空白，也不能是寫入密鑰（貼錯位置）。不對時說明原因並重新詢問，三次都不對就停止、不存入。

## 5. 確認

| # | 在哪裡 | 步驟 | 預期 |
|---|---|---|---|
| T-1 | Mac | `scripts/relay-device.sh list` | 列出各台電腦；等 5～10 分鐘後「最後上傳」有時間 |
| T-2 | Mac | `(cd collector && python3 -m usage_collector.token_sync status)` | `upload_status` 為 `ok`、`pending_rows` 逐輪減少到 0；`devices` 是電腦台數 |
| T-3 | PC | `py -X utf8 -m usage_collector.token_sync status`（在 `collector` 資料夾） | `upload_status` 為 `ok` |
| T-4 | Mac 面板 | 統計卡片 | 標題列標籤為「所有電腦（N 台）」；卡片內有裝置切換；滑鼠移到標籤上列出各台電腦與最後上傳時間 |
| T-5 | Mac 面板 | 切換到「這台 Mac」 | 數字與開啟第二層之前相同 |
| T-6 | Mac 面板 | 切換到 PC | 只有 PC 的數字；完整統計視窗的「一天中的時段」說明其他電腦沒有時段資料 |
| T-7 | Mac | `collector.log` | 沒有密鑰、網址或資料內容；失敗時只有狀態碼與錯誤類別 |

## 換新或撤銷密鑰

| 情況 | 做法 |
|---|---|
| 密鑰外流、想換新 | `scripts/relay-device.sh rotate <device_id>`，再在那台電腦重新執行 `set-tier2.sh`／`set-tier2.ps1` 貼上新的。`device_id` 與資料不變 |
| 電腦遺失或不再使用 | `scripts/relay-device.sh revoke <device_id> --delete-data`：密鑰立即失效，它的資料一併刪除，其他 Mac 下一次下載後不再計入，也從裝置切換與「N 台」中拿掉（只剩這台 Mac 時回到「這台 Mac」；中繼要更新並重新部署才會生效） |
| 只撤銷、保留它過去的數字 | `scripts/relay-device.sh revoke <device_id>`（不加 `--delete-data`）：仍列在裝置切換、標「已撤銷」，數字照算 |

- 被撤銷或換掉的電腦收到兩次 401 後停止上傳（`upload_status = revoked`），面板顯示「這台電腦的寫入密鑰已失效」；本機資料保留。重新執行設定腳本後恢復。
- **換新電腦**（移轉輔助程式或 Time Machine 會把 Keychain 的寫入密鑰與 `history.sqlite3` 一起搬過去）：沿用同一個身分時在新電腦以 `rotate` 換新密鑰、舊電腦停止上傳；另立新身分時才 `revoke` 舊的。步驟見 [runbook.md](runbook.md)「換電腦」。同一把密鑰在兩台電腦上傳時，兩台會互相覆蓋同一個 `device_id` 的數字，其他電腦看到的合計會來回跳；所以新電腦的收集器發現資料庫是從別台搬來的（硬體指紋不同，ADR-0014 D-2）就暫停上傳、面板提示，重新執行設定腳本後恢復。
- **同一台電腦不要用 `add` 重新註冊**（請用 `rotate`）：新的 `device_id` 會把所有資料重新上傳一次，舊 `device_id` 的資料若沒有以 `revoke --delete-data` 刪除，其他 Mac 會把它們算兩次。

## 中繼的用量（免費方案）

平常每台電腦每小時上傳一批（通常只有今天與昨天的幾列；第一次上傳一年的資料時每 5 分鐘一輪、每輪最多 5 批），Mac 每小時下載一次。三台電腦每天約數百列寫入，遠低於 D1 免費方案的上限（撰寫時：每天 10 萬列寫入、500 萬列讀取；以 Cloudflare 目前的公告為準）。
