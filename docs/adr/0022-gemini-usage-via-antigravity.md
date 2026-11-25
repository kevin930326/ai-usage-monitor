# ADR-0022：Gemini 額度改由 Antigravity 的本機服務取得

- 狀態：**已採用**
- 日期：2026-11-23
- 相關需求：FR-4（自動排程收集）、FR-12（單一服務失敗只影響該服務）、NFR-1（token 不離開 Mac）
- 相關：[ADR-0006](0006-claude-usage-via-cli.md)、[ADR-0007](0007-codex-usage-via-app-server.md)（同樣交給官方程式查詢，收集器不碰帳號憑證）

## 背景

使用者訂閱了 Google AI Pro，想把 Gemini 的額度加進來。Google AI Pro 包含兩個與額度有關的產品：

| | Gemini App（聊天） | Antigravity（寫程式） |
|---|---|---|
| 額度 | 依運算量計算，每 5 小時恢復、另有每週上限；Google 只公布倍數（Pro 是基本額度的 4 倍），不公布數字 | 同樣是 5 小時加每週上限，依 token 成本扣；分三組各自計算：Gemini 模型、Claude 與 GPT 模型、Gemini 4 Argon |
| 和另一個共用 | 不共用（Google One 說明：每個產品各有額度） | 同左 |
| 哪裡看得到 | 只有網頁 gemini.google.com →「設定」→「使用量限制」；Mac 的 Gemini.app 裡沒有 | Antigravity 的介面；本機的 language server 也查得到 |

使用者寫程式用的是 Antigravity，Gemini App 的額度只在網頁上，要讀就得用使用者的 Google 登入 cookie，違反本專案「收集器不碰帳號憑證」的原則（ADR-0006、ADR-0007）。本 ADR 只收 Antigravity 的額度，顯示為服務「Gemini」。

## 調查（2026-11-22～23，Antigravity 2.33.0，Google AI Pro）

### 本機服務

Antigravity 開著時有一個官方的 `language_server`（`/Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --subclient_type hub …`），Antigravity 自己的介面也靠它取得額度。它把連線資訊寫在 `~/.gemini/antigravity/daemon/hub_<port>.json`：`pid`、`httpsPort`、`httpPort`、`lsVersion`、`csrfToken`。HTTP 埠只聽 127.0.0.1；呼叫時要在標頭 `x-codeium-csrf-token` 帶 csrfToken（這是本機服務自己產生、只用來呼叫它的值，不是 Google 帳號的 token）。

介面是 Connect RPC（JSON），額度在 `exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`：

```json
{"response": {"groups": [
  {"displayName": "Gemini Models", "buckets": [
    {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.896, "resetTime": "2026-11-28T09:00:02Z"},
    {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.980, "resetTime": "2026-11-22T20:00:02Z"}]},
  {"displayName": "Claude and GPT models", "buckets": [{"bucketId": "3p-weekly", …}, {"bucketId": "3p-5h", …}]},
  {"displayName": "Gemini 4 Argon", "buckets": [{"bucketId": "gemini-argon-wtu-weekly", "window": "weekly", …}]}]}}
```

（完整回應存在 `collector/tests/fixtures/gemini/quota-summary-pro.json`，沒有 email、姓名或帳號 ID。）

### 實測

| 項目 | 結果 |
|---|---|
| 不帶參數 | 0.01～0.02 秒，但回傳的是**快取**：5 小時額度的 `resetTime` 已經過了一天多，數字仍是一天前的 |
| 帶 `{"forceRefresh": true}` | 0.4～0.5 秒，language server 向 Google 重新取得，數字與重置時間都是最新的 |
| 是否消耗額度 | 不消耗。不開對話、不呼叫模型；連續查詢 5 次（不帶參數）與 2 次（`forceRefresh`）前後的 `remainingFraction` 都不變 |
| 還沒用的額度 | `remainingFraction` 為 1，`resetTime` 是「現在＋額度長度」，每次查都往後移 |
| 個人資訊 | 額度摘要沒有 email、姓名或帳號 ID。另一個方法 `GetUserStatus` 有方案名稱（`planName: "Pro"`），但同時回傳 email 與姓名 |
| 其他方法 | 有 `agentapi`（`~/.gemini/antigravity/bin/agentapi`，開新對話、送訊息用），沒有查額度的子指令 |

### 社群與官方文件

- 本機介面沒有公開文件。社群的額度工具（Antigravity Quota Bar 等）都用這兩個方法，並回報 2.16 版改過 `RetrieveUserQuotaSummary` 的回應格式；也有人回報後端偶爾不管用量都回 `remainingFraction: 1`。
- [Antigravity FAQ](https://antigravity.google/docs/faq/)：用第三方軟體、工具或服務存取 Antigravity 違反服務條款，可能停權。實際停權的案例（OpenClaw、OpenCode 的 antigravity-auth 等）都是**拿 Antigravity 的登入（OAuth）在自己的程式裡叫模型**、消耗方案額度；停權是自動判定，聽說只能申訴一次。

## 決定

收集器新增 `gemini` provider，呼叫 Antigravity 本機 language server 的 `RetrieveUserQuotaSummary`，帶 `{"forceRefresh": true}`：

| 細節 | 做法 | 理由 |
|---|---|---|
| 找服務 | `~/.gemini/antigravity/daemon/hub_*.json` 裡最近修改、`pid` 還活著的一個（Windows 不檢查 pid：`os.kill(pid, 0)` 會送 CTRL_C_EVENT） | Antigravity 重開後埠與 csrfToken 都會變，舊檔可能留著 |
| 連線 | `http://127.0.0.1:<httpPort>`，不使用代理伺服器設定，15 秒逾時，回應最多讀 1 MiB | 請求（含 csrfToken）只送到本機；異常輸出不吃光記憶體 |
| 只呼叫一個方法 | 只有 `RetrieveUserQuotaSummary`；不呼叫 `GetUserStatus`（有 email），因此不顯示方案名稱；不開對話（測試掃描原始碼確認） | 與 ADR-0007 不送 `account/read` 相同 |
| `forceRefresh` | 每次都帶 | 不帶時可能拿到一天以上的舊快取 |
| 額度 | Gemini 模型這一組是主要額度：`five_hour`（5 小時）、`weekly`（每週）。Claude／GPT 一組列為 `weekly_claude_gpt`、`five_hour_claude_gpt`，Argon 列為 `weekly_argon`，都是次要額度（`hidden`）。已用 % = `(1 − remainingFraction) × 100` | 使用者主要用 Gemini 模型；其他兩組多數時候沒用 |
| 欄位缺少 | 沒有 `remainingFraction` 視為 0（protobuf 的 JSON 省略 0）；`remainingFraction` 為 1 時不輸出重置時間（還沒開始計時，同 Codex「下次使用時開始計時」） | 用完的額度才不會被當成格式錯誤；滾動的重置時間沒有意義 |
| 格式 | 認不得的分組或額度長度略過；欄位型別不對、同一種額度出現兩次、沒有 Gemini 模型的額度時回報錯誤，不猜測 | 同 ADR-0006、0007 |
| 錯誤 | 沒有 daemon 檔或連不上：「Antigravity 沒有開啟，開啟後才會更新 Gemini 額度」；Connect 錯誤代碼 `unauthenticated`：「尚未登入 Antigravity」；401／403：「拒絕連線，請重新開啟」；其他只帶 HTTP 狀態碼。回應裡的錯誤訊息不帶出去 | 單一服務的錯誤只顯示在該服務（FR-12）；訊息可能含帳號資料 |
| 啟用 | 用過 Antigravity（`~/.gemini/antigravity` 存在，只看是否存在、不讀內容）就啟用：`detect-providers.sh`、`setup.py`、Windows 的 `install-task.ps1 -WithQuota`。沒有 `config.json` 或沒有 `enabled_providers` 時**不**啟用（維持舊版安裝只有 Claude、Codex 的行為） | Antigravity 沒開時無法得知登入狀態；沒用的人不該一直看到錯誤 |
| 頻率 | 與其他服務相同，每 5 分鐘 | 使用者決定照一般服務處理 |

App 端：服務順序 Claude、Codex、Gemini；識別色紫色（深色 `#A78BFA`、淺色 `#6D4FC9`），避開「全部」熱力圖的藍色；原創圖示「四芒星」（凹邊、腰身飽滿的單色四芒星；最初是兩個重疊的圓「雙子」，使用者希望更接近 Gemini 的印象後改成這個），不收錄 Google 的 Gemini 標誌（細腰、漸層的那個）（設計 skill 第 2、3 節）。Mac 瀏海的額度卡片在有 Gemini 時多一欄。鎖定畫面卡片、動態島展開版面與中型小工具高約 160pt，只放得下兩個服務：三個服務時只列剩餘最少的兩個（`UsageActivityState.compactProviders`，有錯誤的服務排在後面），剩餘最少的額度一定在裡面；iPhone App、大型小工具、Mac 與手錶照常列出全部。

## 後果

- 好處：使用者在 iPhone、手錶、Mac 上也看得到 Antigravity 的 Gemini 額度，與 Claude、Codex 一起比較剩最少的是哪一個。
- **Antigravity 要開著**：關掉後 Gemini 一欄顯示「沒有開啟」，其他服務照常。language server 在 Antigravity 的視窗關掉但 App 還在時是否繼續執行，尚未驗證。
- **服務條款的風險**：FAQ 的措辭（「用第三方軟體存取 Antigravity」）字面上很寬。收集器不拿 Google 登入、不叫模型、不直接連 Google，只問本機官方程式，與被停權的案例不同；但 Google 沒有公開判定規則，不能保證不會被誤判。使用者在知道這點的情況下決定照一般服務處理。Google 公告不允許這種用法時就移除。
- **沒有公開文件**：回應格式可能再變（社群回報 2.16 版改過）。格式認不得時 Gemini 一欄顯示「格式已改變，請更新收集器」，不會顯示錯的數字。
- **每 5 分鐘一次 `forceRefresh`**：每次讓 language server 向 Google 查一次額度（只查額度，不叫模型）。
- **不顯示方案名稱**：要從 `GetUserStatus` 取得，但它會回傳 email 與姓名。
- **Gemini App 的額度不收**：只有網頁看得到，需要使用者的 Google cookie。
- Windows 收集器照同一套程式碼執行，但 Windows 版 Antigravity 尚未實測。
- 已經安裝的人要重新執行 `install-launchd.sh`（或 Mac App 設定精靈的重新檢查）才會把 `gemini` 加進 `enabled_providers`。
