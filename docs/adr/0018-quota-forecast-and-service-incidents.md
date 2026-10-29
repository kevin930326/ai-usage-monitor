# ADR-0018：額度預測與服務異常

- 狀態：**已接受**（2026-10-29；Fable 對抗式審查 10 項都已處理）。2026-10-29 mascot3 修訂：第 4 節寫明 ChatGPT 事故不算 Codex（F-02）；Windows 的事故可以點開（第 4 節）
- 日期：2026-10-28
- 相關需求：FR-18（用得太快）、FR-45（服務狀態）、NFR-8
- 相關：[ADR-0008](0008-mac-panel-layout.md)（面板，第 2 節第 8 項服務狀態、第 4 節用量節奏）、[ADR-0009](0009-local-history-and-token-stats.md)（歷史與近期速度）、[ADR-0015](0015-windows-desktop-app.md)（Windows）、[ADR-0016](0016-mascot-character.md)（角色表情）

## 背景

面板已經有「用得較快，約 N 分鐘後用完」（FR-18）：有歷史時用近期速度，不足時退回本額度開始至今的平均速度。使用者要的是更明確的預測：「照目前速度約幾點幾分用完」、「比平常快幾倍」，而且**資料不足時不要猜**；瀏海、Windows 圓環與 iPhone 都要看得到，角色在會用完前一直擔心。

服務狀態（FR-45）也已經有：收集器讀兩個公開狀態頁寫到本機 `service-status.json`，只有 Mac 面板讀。2026-10-28 實測發現 OpenAI 的狀態頁換成 incident.io 後，`summary.json` 沒有 `incidents` 欄位，所以 **Codex 的事故目前永遠讀不到**；而且 Windows 與 iPhone 看不到這份檔案。

## 決定

### 1. 預測規則（共用邏輯）

對 5 小時與每週額度（`five_hour`、`weekly`、`weekly_*`），在以下條件**全部**成立時才有預測，否則什麼都不顯示：

- 快照沒有過期、額度沒有隱藏、服務沒有錯誤、`resets_at` 已知而且還沒到。
- **有近期速度**（ADR-0009 第 4 節的規則：同一輪、回看 60 分鐘／24 小時內至少 4 筆、跨度至少 30 分鐘／12 小時）。**不退回平均速度**：資料不足就不顯示。
- 近期速度 > 0，而且 `現在 + 剩餘 ÷ 速度` 早於 `resets_at`（會在重置前用完）。已用 100% 的不算預測（那是「用完」，表情是 ×）。

結果：

- `exhausts_at`：預計用完的時間（畫面寫「約 14:32 用完」，跨日時加「明天」或星期）。
- `urgent`：距離用完不到 60 分鐘（紅色）；其他是黃色（同提醒光環「偏高」的顏色）。顏色以外一律有文字。
- `faster`：比平常快幾倍。**平常**＝過去 7 天每一天「同一個時段」（往前推整天數的同一段回看範圍）的速度，各天用同樣的資料門檻（至少 4 筆、跨度足夠），**至少 3 天**有資料才算；取中位數。中位數 > 0 而且 `近期速度 ÷ 中位數 ≥ 1.5` 時才顯示，倍數取到小數一位、無條件捨去（1.58 → 1.5）。中位數是 0（平常這個時段不用）時不顯示倍數，不寫「快無限倍」；倍數最多 10，到上限時寫「10 倍以上」（平常幾乎沒用時倍數沒有意義）。
- 平常的速度用相鄰兩筆的正差值，跨過重置的那一段不算（同「額度消耗」的算法）。

這套規則放在 `UsageKit/QuotaForecast.swift`、`UsageCore/QuotaForecast.cs`，以及收集器的 `usage_collector/forecast.py`（見第 2 節），`fixtures/forecast/cases.json` → `golden.json` 三邊跑同一份。

### 2. 誰算、怎麼送到各平台

- **收集器**在寫 usage.json 前用同一套規則算好（唯讀打開 `history.sqlite3`、最多等 1 秒；這次收集的值也算進去），寫進每個額度的選填欄位 `forecast`（`{"exhausts_at": "...", "urgent": true, "faster": 2.1}`；沒有預測時不輸出）。同一個 `schema_version` 新增選填欄位（FR-13 的規則），舊版 App 略過；中繼以白名單重建快照，要一起加（`relay/src/index.ts`；格式不符時只丟掉這個欄位，不擋下整份快照）。**中繼要重新部署 iPhone 才看得到**（這個 PR 不部署）。
- **Mac 面板**有讀歷史（面板打開時），只用自己算的；算不出來就不顯示（資料不足時不猜，不退回快照）。用完的時間以最後一筆樣本的時間起算，兩次收集之間不會每分鐘往後漂一分鐘。
- **瀏海、角色表情、iPhone、Windows App** 用快照的（瀏海與角色不為了預測讀資料庫，維持 ADR-0016 的效能；Windows 面板原本就沒讀歷史）。快照過期、預計時間已過、或不在重置前時不用；「緊急」照現在的時間重算。
- 三邊（Swift、C#、Python）跑同一份 golden，所以不論哪裡算，結果相同。

### 3. 畫面

- Mac 面板額度列、瀏海展開的額度卡、Windows 圓環展開後的額度列、iPhone App 的額度卡：會在重置前用完的額度下面一行「照目前速度約 14:32 用完」（不到 60 分鐘紅，其他黃），有倍數時接「・比平常快 2.1 倍」。
- 原本的「用得較快，約 N 分鐘後用完」改成上面這行（同一個位置）。選單列圖示「太快」的小點維持原本的規則（ADR-0008 第 1 節，平均速度也算），因為那是提醒，不是預測的時間。資料不足以預測、但選單列已經是「太快」時，面板（Mac、Windows）同一個位置只寫「用得較快」，不帶時間，讓小點有解釋。
- 瀏海展開的額度卡：每個服務最後一行原本是重置倒數，有事故時換成事故名稱（點了打開事故頁），否則有預測時換成最早用完的那個額度的短說法（「每週 約明天 09:05 用完・快 2.1 倍」）。
- Windows 圓環展開後的兩行：有預測時重置倒數換成短說法（紅／黃）。
- **角色**：角色代表的服務有任何額度會在重置前用完時，表情**持續**是擔心（小圓點眼＋眉毛），不是只跳一下；優先順序：資料過期或讀取失敗（閉眼，額度不明時不畫 ×，同 ADR-0016）> 用完（×）> 服務異常（生病，第 4 節）> 預測會用完或剩不到 20%（擔心）> 正常。

### 4. 服務異常

- 收集器每次執行時查兩個官方狀態頁（Mac 與 Windows 的收集器是同一份 Python，兩邊都會做）：
  - Claude：`https://status.claude.com/api/v2/incidents/unresolved.json`（Statuspage；`status.anthropic.com` 已 301 轉到這裡）。只算影響 `Claude Code`、`Claude API`、`claude.ai` 的事故；沒列元件的也算。
  - OpenAI：`https://status.openai.com/api/v2/incidents.json`（incident.io；沒有 `unresolved.json`，`summary.json` 沒有事故），篩 `status` 不是 `resolved`、`postmortem` 的。OpenAI 的事故沒有元件資訊，只算名稱提到 Codex、API 或 Responses 的（整字、不分大小寫）；廣告、客服、ChatGPT 連線器之類的不讓 Codex 角色生病。
    **名稱只寫 ChatGPT 的事故不算 Codex**（2026-10-29 使用者決定，Fable F-02 維持現狀）：Codex 雖然用 ChatGPT 帳號登入，但 ChatGPT 的事故多半是網頁、App、連線器或某個功能，Codex 照常能用；算進去角色會常常無故生病，使用者會學會忽略它。登入服務故障到 token 無法更新時，Codex 的額度讀取也會失敗，角色會因為讀取失敗閉眼。名稱同時提到 ChatGPT 與 Codex／API 的仍然算。`collector/tests/fixtures/status/openai-incidents.json`（手寫，依 incident.io 的 Statuspage 相容格式）與 `test_chatgpt_only_incidents_do_not_count_for_codex` 鎖住這條規則。
  - 元件狀態照舊讀 `summary.json`（兩邊都有）。
- 結果除了照舊寫 `service-status.json`（Mac 面板的詳細卡片；多了 `incidents_checked` 與事故的 `url`、`started_at`），也把**精簡版**寫進 usage.json 每個服務的選填欄位 `incidents`：`[{"name": "...", "impact": "minor", "url": "https://status.claude.com/incidents/<id>", "started_at": "..."}]`，最多 3 筆、名稱 120 字以內。查詢失敗、事故清單讀不到或上一次查詢超過 15 分鐘時**不輸出這個欄位**（不是空陣列；空陣列代表查過、沒有事故），額度收集照常、結束碼不變。狀態頁照舊在收集的最後才查（不拖慢 usage.json 與上傳），所以 usage.json 放的是**上一次**查到的結果，事故最多晚一次收集（約 5 分鐘）出現。
- 為什麼放進 usage.json（FR-45 原本只放本機）：狀態頁是公開資訊，不含使用者的任何資料；不放進去 Windows 與 iPhone 就看不到。只放名稱、等級、連結、開始時間，不放事故的更新內文。
- 畫面：有影響的事故（`minor` 以上；`maintenance`、`none` 不算）時角色生病（半閉眼、擔心的眉毛、冷汗）。事故名稱顯示在 Mac 面板的服務狀態列（「事故頁」按鈕打開那個事故）、瀏海展開的額度卡、Windows 面板的額度卡、iPhone App 的服務區塊。點了用瀏覽器打開事故頁；連結只接受兩個官方狀態頁的 `https://…/incidents/…`（Swift 的 `ServiceIncident.link`、中繼白名單），其他網址不顯示成連結。
- **Windows App 的事故可以點開**（2026-10-29 使用者決定，修訂 ADR-0015 第 2 節）：面板的事故那行是按鈕（文字後面「↗」），點了或按 Enter 用預設瀏覽器打開事故頁；只接受上面兩個官方狀態頁的 `https://…/incidents/<ID>`（UsageCore `IncidentLink`，和 Swift 的 `ServiceIncident.link` 同一份規則與 `fixtures/incident-links.json`），其他網址只顯示文字。App 本身仍不連網。圓環展開後的兩行空間不夠，事故只在面板顯示。

## 不做

- 不在資料不足時用平均速度猜用完時間（使用者明確要求）。
- 不對「其他長度」的額度（例如 `3h`）做預測：沒有近期速度的規則。
- 不發「預測會用完」的新通知：已經有「用得太快」通知（FR-19），規則不變。
- 不從 App 直接連狀態頁（App 不連網的原則不變）；事故頁一律交給使用者的瀏覽器打開。
- 不讀狀態頁的事故更新內文、不存歷史事故。

## 考慮過的選項

- **預測只在收集器算、所有 App 讀 usage.json**：只要一份實作；但 Mac、Windows 的「剩幾分鐘」只會每 5 分鐘跳一次，而且 TASK 規定預測要放 UsageKit／UsageCore。採用「三邊同一份 golden」。
- **iPhone 以快照的平均速度估算**：會在資料不足時亂猜，違反需求。
- **OpenAI 改用 summary.json 的元件狀態推事故**：沒有事故名稱與連結，不採用（元件狀態照舊顯示）。
- **名稱只寫 ChatGPT 的事故也算 Codex**（Fable F-02）：登入或帳號服務出事時會早一點提醒；但多數 ChatGPT 事故不影響 Codex，誤報會讓「生病」失去意義。不採用（2026-10-29 使用者決定）。

## 影響

- usage.json 新增兩個選填欄位（`windows[].forecast`、`providers.*.incidents`），`fixtures/usage-forecast-incidents.json`、中繼白名單、Swift／C#／TypeScript 的解析與 `fixtures/forecast/` golden 一起更新。
- Mac 面板與 Windows 面板原本的「用得較快，約 N 分鐘後用完」拿掉（資料不足時不再用平均速度猜）；選單列與 Windows 圓環的「太快」狀態照舊。
- 收集器每次多兩個 HTTP 請求（逾時 8 秒、至少間隔 4 分鐘，同原本的 `service-status.json`）。
- 中繼要重新部署 iPhone 才有新欄位。
