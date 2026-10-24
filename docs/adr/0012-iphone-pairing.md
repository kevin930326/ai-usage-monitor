# ADR-0012：iPhone 配對（QR 碼與一次性短碼）

- 狀態：**已採用**（2026-10-24 提議，同日由使用者採用）
- 日期：2026-10-24
- 相關需求：FR-55、NFR-1、NFR-3、NFR-6
- 相關：[ADR-0001](0001-cloudflare-worker-relay.md)（中繼與讀寫密鑰）、[ADR-0013](0013-download-and-install.md) 第 6 節（iPhone 的安裝方式）

## 背景

iPhone App 要兩樣東西才能顯示用量：中繼網址與**讀取密鑰**（`READ_TOKEN`，只能 `GET /usage`）。目前要在 iPhone 的設定裡手動打一長串網址、從 Mac 複製一段 43 字元的隨機字串貼上，容易打錯，也常有人誤貼寫入密鑰（設定畫面特別警告）。

限制：

- 選單列 App 不連網、不持有密鑰（ADR-0008 第 8 節、ADR-0013 第 4 節）：配對不經過 Mac App。
- 不為別人架中繼，每個人用自己的 Cloudflare 帳號（中繼程式在 repo 裡）。
- iPhone 上只存讀取密鑰（Keychain，`relay-read-token`），寫入密鑰永遠不離開 Mac。
- 今晚不能部署中繼、不能動使用者正在用的密鑰。

## 選項

| | A. QR 碼（終端機顯示，App 內掃描） | B. 一次性短碼（中繼發碼、iPhone 兌換） | C. 自訂 URL scheme（相機掃 QR 直接打開 App） | D. 維持手動貼上 |
|---|---|---|---|---|
| 使用者步驟 | Mac 執行 `scripts/setup-iphone.sh --pair qr` → iPhone 設定按「掃描 QR 碼」→ 確認 | Mac 執行 `--pair code` → iPhone 輸入網址＋8 碼 → 完成 | 同 A，但用相機 App 掃 | 打網址、複製貼上密鑰 |
| 中繼要改 | **不用** | 要（新增 `POST /pair`、`POST /pair/claim`） | 不用 | 不用 |
| 密鑰經過哪裡 | Mac 終端機畫面 → iPhone 相機（不經網路） | 中繼回傳給 iPhone（HTTPS） | 同 A | 使用者的剪貼簿、通訊軟體…… |
| 風險 | 畫面被拍或截圖就等於拿到讀取密鑰（只能讀用量） | 短碼被猜中（以長度、一次性、到期、嘗試次數限制）；中繼多兩個端點 | **任何網頁或訊息裡的連結**都能叫 App 改中繼設定（社交工程把 iPhone 指到別人的中繼） | 剪貼簿外流 |
| 要不要網路 | 不用 | 要 | 不用 | 不用 |

## 決定

1. **主要方式：A（QR 碼）**。不改中繼、不經網路、今晚就能完整驗證。
2. **輔助方式：B（短碼）**，給相機不方便（iPhone 在別處、Mac 螢幕在投影）時用。中繼的端點另開 PR（`feat/relay-pairing`），**不合併、不部署**，等使用者看過再決定；iPhone 端先做好，中繼沒有這個端點時（HTTP 404）提示「中繼還不支援短碼，改用 QR 碼」。
3. **不採用 C**：註冊 URL scheme 等於讓任何連結都能觸發「改中繼設定」，即使有確認畫面也多一個社交工程的入口；App 內掃描只認得 A 的格式，效果相同。
4. **保留 D**（手動貼上），也是兩種方式都失敗時的退路。

### QR 碼的內容

```
aiusage-pair:v1:<base64url(JSON)>
JSON = {"url": "https://ai-usage-relay.<帳號>.workers.dev", "read": "<READ_TOKEN>"}
```

- 只放**讀取密鑰**與網址。寫入密鑰不在 Mac 的 QR 碼裡出現（腳本只讀 Keychain 的 `AIUsageMonitor-relay-read`；沒有時請使用者貼上一次，存進 Keychain 後再顯示）。
- iPhone 端（UsageKit `PairingPayload`）檢查：前綴與版本、網址必須是 `https`、密鑰長度 16～256、只含可見 ASCII；不符就不採用、不顯示內容。
- 採用前顯示確認：「把中繼設定為 `<主機名稱>`？」（只顯示主機名稱，不顯示密鑰）；已經有設定時寫「取代目前的設定」。
- QR 碼只畫在終端機，**不存成檔案**、不進剪貼簿；腳本畫完後提示「配對完成後按 Enter 清除畫面」並清除（`clear` 與捲動緩衝）。
- 終端機的 QR 以 CoreImage（`CIQRCodeGenerator`、糾錯等級 M）產生，用 Unicode 半格方塊畫，不需要安裝 `qrencode`；測試以 `CIDetector` 解碼回原字串。

### 短碼

| 項目 | 決定 |
|---|---|
| 產生 | **中繼**以 `crypto.getRandomValues` 產生（Mac 腳本以**寫入密鑰**呼叫 `POST /pair`），回傳短碼與到期時間 |
| 格式 | 8 個 Crockford base32 字元（不含 I、L、O、U），顯示成 `XXXX-XXXX`；約 40 位元。iPhone 輸入時忽略大小寫、空白與連字號，`O`→`0`、`I`／`L`→`1` |
| 保存 | KV 一個鍵 `pair`：`{hash: SHA-256(短碼), expires_at, failures}`；**只存雜湊**，同一時間只有一組（再產生一組就取代舊的） |
| 到期 | 10 分鐘 |
| 一次性 | 兌換成功立即刪除 |
| 嘗試次數 | 錯誤 5 次就刪除（必須重新產生）；攻擊者最多猜 5 次 40 位元的碼 |
| 兌換 | iPhone `POST /pair/claim {"code": "..."}`（不需要密鑰）→ 200 `{"read_token": "..."}`；錯誤、到期、沒有短碼都回 403（不區分，避免探測）；端點不存在（舊中繼）是 404 |
| 比對 | 與現有密鑰比對相同，先雜湊再固定時間比對 |
| 已知限制 | Cloudflare KV 最終一致：刪除最多約 60 秒才傳到所有節點，這段時間內「一次性」只在同一節點保證；短碼仍要先被知道才能利用，風險可接受 |

### iPhone 端

- 設定的「中繼」區塊加「掃描 QR 碼」「輸入短碼」兩個按鈕，原本的手動欄位保留。
- 掃描用 VisionKit `DataScannerViewController`（只辨識 QR、只接受 `aiusage-pair:` 開頭）；需要相機權限（`NSCameraUsageDescription`：「掃描 Mac 上顯示的配對 QR 碼」）。不支援的裝置（模擬器）按鈕停用並說明。
- 採用後與手動貼上相同：網址存 UserDefaults、讀取密鑰存 Keychain（`relay-read-token`），立即重新整理一次；配對成功的提示不顯示密鑰。
- 手錶照舊由 iPhone 傳送（WatchConnectivity，既有流程）。

### `scripts/setup-iphone.sh`

把第一次安裝串起來（細節見腳本說明）：檢查 Xcode 與 xcodegen → Team ID（`--team`、config.json 的 `development_team`，或從 Xcode 的帳號清單找唯一的 Personal Team）→ 手機（`xcrun devicectl`，只有一台時自動選）→ 寫進 config.json → 呼叫既有的 `scripts/reinstall-ios.sh` 建置與安裝 → 可選 `--auto-reinstall`（既有的 `install-reinstall-launchd.sh`）→ 可選 `--pair qr|code`。`--dry-run` 只印出會做什麼。測試以假的 `xcodebuild`、`devicectl`、`security`、`curl` 執行，不碰真的 Keychain 與手機。

## 後果

- iPhone 配對從「打兩串字」變成「掃一次」；短碼要等使用者合併並部署 `feat/relay-pairing` 後才可用。
- 讀取密鑰會短暫出現在 Mac 的終端機畫面（QR 碼）。讀取密鑰只能讀用量，外流時以既有方式輪換（`wrangler secret put READ_TOKEN`，iPhone 重新配對）。
- 中繼多兩個不需要密鑰也能呼叫的端點（`/pair/claim`）；以一次性、10 分鐘、5 次與只存雜湊限制。
- 新增：UsageKit `PairingPayload`、`PairingCode`、`RelayClient.claimPairing`；iPhone 設定的掃描與短碼畫面；`scripts/setup-iphone.sh`、`scripts/render-qr.swift`；中繼的 `/pair` 端點（另一個 PR）。

## 使用者的決定（2026-10-24）

1. 採用這份 ADR。
2. `feat/relay-pairing`（短碼，#86）照合併條件合併；**部署由使用者自己做**。部署之前中繼沒有 `/pair`，iPhone 的「輸入短碼」顯示「中繼還不支援短碼，改用 QR 碼」。
3. 接受短碼的並行殘留：KV 沒有條件更新，同時大量猜測時實際嘗試次數可能略多於 5 次（40 位元、10 分鐘到期，風險很低；見 relay/README.md）。要完全序列化得改用 Durable Objects，屆時另寫 ADR。
4. PC 以短碼加入第二層之後再做（記在 BACKLOG）；目前第二層以 `scripts/relay-device.sh` 產生的裝置密鑰加入（FR-57）。
