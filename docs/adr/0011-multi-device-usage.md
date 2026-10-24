# ADR-0011：多裝置的用量：額度消耗（第一層）與 Token 合併（第二層）

- 狀態：**已採用**（2026-10-23；第二層在 v2.0 實作）
- 日期：2026-10-23
- 相關需求：FR-42、FR-43、FR-48、FR-49、NFR-1、NFR-2、NFR-3、NFR-6、NFR-9
- 相關：[ADR-0001](0001-cloudflare-worker-relay.md)（中繼）、[ADR-0003](0003-cloud-collector.md)（不採用雲端收集）、[ADR-0009](0009-local-history-and-token-stats.md)（本機歷史與 Token 統計）

## 背景

使用者在 Mac、Windows PC、手機 App 與 claude.ai 網頁都會用 Claude 與 Codex。兩種資料的範圍不同：

| 資料 | 能涵蓋哪些裝置 | 原因 |
|---|---|---|
| 額度 %（5 小時、每週） | **整個帳號**：所有電腦、手機、網頁、雲端 session | 由服務端計算，Mac 收集器查到的是帳號層級的數字 |
| Token 數 | **只有裝了收集器、有本機對話紀錄的電腦** | 手機 App、網頁與雲端 session 不在本機留下紀錄；讀瀏覽器 cookie 取得 claude.ai 用量違反條款，不採用 |

因此分兩層：第一層用額度歷史回答「整個帳號什麼時候用得多」，第二層把各電腦的 Token 數合併。

## 決定

### 1. 第一層：額度消耗（FR-42，不需要其他裝置安裝任何東西）

- 以 Mac 本機的額度歷史（ADR-0009 `quota_samples`）計算**每小時消耗的額度 %**：同一額度相鄰兩筆的正差值，重置時以新值計（ADR-0009 第 4 節）。
- 預設用 Claude 與 Codex 的**每週**額度（5 小時額度變化快、重置頻繁，作為切換選項）。
- 呈現：熱力圖（星期 × 小時，最近 4 週；或日期 × 小時）與走勢；單位是「每週額度的 %」，不是 Token。
- **沒有紀錄的時段**（Mac 睡眠、關機、收集器停止：`collector_runs` 中斷超過 15 分鐘）：醒來後第一筆與前一筆的差值平均分到中間的小時，這些格子以斜線標示「估計（Mac 未執行）」。空檔中發生重置（`resets_at` 改變或 `used_pct` 下降到一半以下，ADR-0009 第 4 節；小幅下修不算）時無法知道重置前用了多少，整段只標示「沒有紀錄」、不分配。
- 限制：Claude 的 `used_pct` 是整數，每小時的消耗多為 0 或 1 個百分點；小時以 Mac 的本機時區計。
- 涵蓋手機、網頁、所有電腦與雲端 session，介面標註「整個帳號」。
- 只在本機計算與存放，不上傳。

### 2. 第二層：Token 用量合併（FR-48、FR-49）

#### 收集與上傳

- Mac 與 Windows PC 各自用 ADR-0009 的規則統計本機的 Token（同一份 Python 程式；Windows 以「工作排程器」每 5 分鐘執行，路徑改為 `%USERPROFILE%\.claude`、`%USERPROFILE%\.codex`，`CLAUDE_CONFIG_DIR`／`CODEX_HOME` 優先）。
- **只上傳每日加總**：（日期、服務、模型、輸入／快取寫入／快取讀取／輸出／推理 Token，**各欄分開、不預先加總**（ADR-0009 第 4 節），任務時間合計、最長任務）。不上傳每小時資料、專案名稱、路徑、對話內容、session ID、訊息 ID、檔名。
- 上傳時機：每小時一次＋本機日期改變後的第一次執行；只送 `device_id` 等於本機 `meta.device_id`、且「上次成功上傳後有變動」的列（含昨天，處理跨日的晚到紀錄），每批最多 400 列；從中繼下載的其他裝置的列**永遠不上傳**。
- 本機記錄上傳進度（`history.sqlite3` 的 `upload_state` 表：每列上次成功上傳時的數值雜湊與時間；最後結果與時間存在 `meta`）。失敗時不前進，下次執行重試，連續失敗以 5 分鐘、15 分鐘、1 小時、6 小時遞增間隔；HTTP 401／403 時停止上傳，`meta.upload_status = revoked`，面板讀到後顯示「這台電腦的寫入密鑰已失效」，不刪除本機資料。

#### Windows 收集器

| 項目 | 做法 |
|---|---|
| 排程 | 工作排程器，每 5 分鐘＋登入時，只在使用者登入時以本人身分執行（`collector/windows/install-task.ps1` 以 ScheduledTasks 指令建立，避開 `schtasks /TR` 的 261 字元上限）；`pythonw.exe -X utf8` 不開視窗、檔案一律 UTF-8 |
| 資料夾 | `%LOCALAPPDATA%\AIUsageMonitor\`（`history.sqlite3`、`config.json`、`collector.log`）；平台差異集中在 `system` 模組 |
| 紀錄資料夾 | `%USERPROFILE%\.claude`、`%USERPROFILE%\.codex`，`config.json` 的 `claude_config_dir`／`codex_home` 優先（同 ADR-0009 第 3 節） |
| 寫入密鑰 | Windows 認證管理員（Credential Manager），以標準函式庫的 `ctypes` 呼叫 `CredReadW`／`CredWriteW`；不存明文檔（NFR-1） |
| 共用 | `token_stats`、`history`、上傳模組與 Mac 相同；排程預設 `--tokens-only`，不執行 `claude -p /usage`、`codex app-server`（不收集額度）。程式本身在 Windows 也能收集額度（`install-task.ps1 -WithQuota`，只寫本機 `usage.json`、不上傳），供需要時使用 |
| 低優先序 | 以 `BELOW_NORMAL_PRIORITY_CLASS` 執行（相當於 macOS 的 `nice`） |

#### 中繼

| 項目 | 決定 |
|---|---|
| 端點 | `POST /tokens/daily`（寫入）、`GET /tokens/daily?from=YYYY-MM-DD`（讀取，用現有的讀取密鑰） |
| 寫入密鑰 | **每台電腦一把**，可單獨撤銷；中繼只存雜湊（SHA-256），`device_id` 由中繼依密鑰決定，**不信任內容中的裝置欄位**。裝置密鑰**只能**寫 `/tokens/daily`，不能寫 `/usage`（額度快照仍只由 Mac 以現有的寫入密鑰上傳，Windows 收集器不收集額度） |
| 覆蓋寫入 | 以（`device_id`、`day`、`provider`、`model`）為主鍵 upsert，重送同一列不會重複計算 |
| 驗證 | 日期格式與範圍（不早於 400 天前、不晚於明天）、服務只允許 `claude`／`codex`、模型名稱依 ADR-0009 第 4 節的白名單格式、數值為 0～10¹² 的整數、每批列數上限 |
| 讀取 | Mac 收集器以讀取密鑰下載每日加總，**略過本機 `device_id` 的列**（本機的數字以本機統計為準，避免以中繼的舊值蓋掉較新的本機值），其他裝置的列以（`device_id`、`day`、`provider`、`model`）覆蓋寫進本機 `daily_tokens`；本機統計只寫本機 `device_id` 的列，兩者不會互相覆蓋。以測試驗證延遲上傳、下載到自己的舊值與重試時，各裝置與合計都不倒退、不重複、歸屬不變。**選單列 App 仍然不連網、不持有密鑰** |
| 裝置管理 | `scripts/relay-device.sh add <名稱>`（產生密鑰、印一次、存雜湊）／`list`／`revoke <device_id>`；撤銷時可選擇一併刪除該裝置的資料 |

**儲存選擇：Cloudflare D1（建議）**，不用現有 KV：

| 面向 | D1 | KV（現有） |
|---|---|---|
| upsert | `INSERT … ON CONFLICT DO UPDATE`，原子 | 需讀改寫整個值，非原子；兩台電腦同時上傳可能互相覆蓋 |
| 免費額度（撰寫時，實作前再查證） | 每天寫入 10 萬列、讀取 500 萬列、5 GB | 每天寫入 1,000 次、讀取 10 萬次、1 GB |
| 寫入量估計 | 每台每小時 ≤ 10 列，3 台約 720 列／天 | 若每台每小時寫一個值，3 台 72 次／天，加上現有快照 288 次，仍在 1,000 內，但每個值要包含多天資料 |
| 查詢 | SQL 依日期範圍 | 要列出鍵再逐一讀取 |
| 部署 | `wrangler d1 create`＋migration，多一個綁定 | 不用改 |

KV 的替代做法（每台裝置一個鍵 `daily:<device_id>`，值為最近 400 天的 JSON）可行，但上傳要整份重寫，且以後要加查詢時難以擴充。**決定採用 D1**。

### 3. 第二層的隱私（NFR-6、NFR-9）

- 離開電腦的只有：日期、服務、模型名稱、各類 Token 數、任務秒數；README 的隱私章節要列出。
- 中繼不記錄來源 IP 以外的 Cloudflare 預設日誌；不提供公開讀取。
- 使用者可在設定中關閉上傳（預設：安裝第二層時才開啟，Mac 單機不上傳）。

### 4. 範圍標示（兩個階段不同）

| 階段 | 統計卡片的標籤 | 滑鼠移上去的說明 | 切換 |
|---|---|---|---|
| **Mac 階段**（v1.7） | 「這台 Mac」 | 「只包含這台 Mac 上 Claude Code 與 Codex CLI 的對話紀錄（含它們的桌面 App 與編輯器外掛）。不包含 claude.ai 網頁、手機 App、其他電腦與雲端 session。額度 % 是整個帳號的數字。」 | 全部／Claude／Codex |
| **多裝置階段**（v2.0，第二層完成後） | 「所有電腦（N 台）」或所選裝置的名稱 | 「包含已安裝收集器的電腦：Mac、PC…（各自最後上傳時間）。不包含 claude.ai 網頁、手機 App 與雲端 session。」 | 服務切換之外，另加裝置切換：全部／各裝置 |

- 額度相關的卡片（主圓環、額度、走勢、額度消耗）一律標註或說明為「整個帳號」。
- 某裝置超過 48 小時沒有上傳時，在裝置切換中標示「N 天前更新」，合計仍包含它已上傳的資料。
- 資料模型從第一階段起每列都有 `device_id`（ADR-0009），切換到多裝置時不需要遷移。

### 5. 實作順序

1. 第一層（額度歷史、額度消耗熱力圖與走勢）— 只改收集器與 Mac App。
2. Mac 的 Token 統計（ADR-0009）。
3. Windows 收集器與第二層合併（中繼新增端點與 D1、裝置管理、上傳、Mac 下載合併、裝置切換）。

### 6. 實作補充（v2.0）

- **裝置管理**：`/devices` 以另一把 `ADMIN_TOKEN`（secret）驗證，和 `READ_TOKEN`／`WRITE_TOKEN` 不同（相同或未設定時回 503）。除了 `add`／`list`／`revoke`，另有 `rotate`（換新密鑰、`device_id` 與資料不變），避免同一台電腦重新註冊造成重複計算。撤銷時密鑰雜湊改為不可能相符的值。
- **密鑰失效的判斷**：連續 **兩次** 401／403 才停止上傳（`REVOKE_AFTER = 2`），一次可能是中繼暫時設定錯誤；本機資料不刪除，重新執行設定腳本（`token_sync reset`）後恢復。
- **自己在中繼上的 `device_id`**：由中繼依密鑰決定，收集器從上傳的回應取得並記在 `meta.relay_device_id`，所有用過的 id 記在 `meta.relay_device_ids`；下載時略過全部。還不知道自己的 id 時不下載。換成另一台裝置的密鑰時清除 `upload_state`，全部重新上傳到新的 id。
- **上傳欄位**：不含任務次數（`task_count` 只用在本機的 CSV）；下載的列 `task_count` 為 0。
- **下載**：從 399 天前（本機日期）起，整批取代本機的其他裝置列與 `devices` 表；只有 Mac 存了讀取密鑰時才下載（Windows 只上傳）。
- **App 的範圍**：每小時資料與個人紀錄（`records`、`record_days`）只有這台 Mac 有。「所有電腦」與單一電腦的個人紀錄與累計由面板讀到的每日資料（最近一年）計算；「一天中的時段」只有這台 Mac。
- **關閉上傳**（第 3 節）以 `set-tier2.sh --disable`／`set-tier2.ps1 -Disable` 實作，不是 App 的設定（App 不寫 `config.json`、不持有密鑰）；Mac 關閉時一併刪除本機的其他電腦資料。
- **D1 綁定**在 `wrangler.toml` 預設註解（填了不存在的 `database_id` 會讓 `wrangler deploy` 失敗）；沒有綁定時第二層的端點回 503，`/usage` 不受影響。

## 參考專案

| 專案 | 參考了什麼 | 不採用的部分 |
|---|---|---|
| [claude-telemetry](https://github.com/wjdtjq6/claude-telemetry) | 每台電腦一把 API key；連續 401 時停止上傳 | 以 `ccusage` 解析（多一個相依、無法控制讀取的欄位）；Neon Postgres；儀表板沒有登入 |
| [toki-sync](https://github.com/korjwl1/toki-sync) | 以（裝置、服務、訊息 ID）覆蓋寫入、可重送；裝置資料可單獨刪除 | 上傳每則事件與專案名稱；自架 TCP 伺服器，無法放在 Worker |
| [claude-usage-tracker](https://github.com/Cdower/claude-usage-tracker) | 以 `message.id` 去重、同一 ID 取最後一筆；記錄每檔處理到哪裡；上傳失敗不前進 | 所有裝置共用一個密鑰；儲存 `cwd`；**讀瀏覽器 cookie 取得 claude.ai 用量（違反條款）** |

## 考慮過的選項

| 選項 | 不採用的原因 |
|---|---|
| 讀瀏覽器 cookie 查 claude.ai 用量 | 違反條款（ADR-0003、ADR-0006 的同一原則） |
| 上傳每則訊息或每小時資料 | 不需要；增加隱私風險與寫入量 |
| 所有裝置共用一把寫入密鑰 | 無法單獨撤銷遺失的電腦 |
| 讓選單列 App 直接呼叫中繼 | App 目前不連網、不持有密鑰；由收集器下載可維持這個性質 |
| 用額度 % 換算 Token 數 | 服務未公開換算方式，且會隨模型改變 |

## 影響

- 第一層只影響收集器與 Mac App；第二層需要中繼新增端點、D1 綁定、裝置管理腳本與 Windows 安裝說明。
- NFR-2（讀寫不同密鑰）延伸為「每台電腦各自的寫入密鑰」。
- 需求文件新增 FR-42、FR-43、FR-48、FR-49。

## 決定（使用者於 2026-10-23 決定）

1. 第二層的儲存：**D1**。
2. 額度消耗遇到沒有紀錄的時段：平均分配到中間的小時並以斜線標示「估計（Mac 未執行）」；空檔中有重置時不分配，只標示「沒有紀錄」（第 1 節）。
3. 上傳預設：只有安裝第二層的電腦才上傳；Mac 單機使用者永遠不上傳。
