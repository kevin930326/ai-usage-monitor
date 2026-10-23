# ADR-0009：額度歷史與 Token 統計的存放、保留與隱私（Mac）

- 狀態：**提議中**
- 日期：2026-10-23
- 相關需求：FR-18、FR-19、FR-23、FR-37、FR-40～FR-44、NFR-1、NFR-6、NFR-8、NFR-9、NFR-10
- 回答 [ADR-0004](0004-usage-history.md) 中屬於 Mac 的部分（Q1、Q2、Q4、Q6）；iPhone 端的預測（Q3）不在本 ADR 決定
- 相關：[ADR-0006](0006-claude-usage-via-cli.md)、[ADR-0007](0007-codex-usage-via-app-server.md)（收集器不讀憑證）、[ADR-0011](0011-multi-device-usage.md)（多裝置）

## 背景

新的 Mac 面板（[ADR-0008](0008-mac-panel-layout.md)）需要兩種過去的資料：

| 資料 | 用途 | 來源 | 範圍 |
|---|---|---|---|
| 額度歷史 | 本週走勢、額度消耗熱力圖、每週預測、近期速度、重置時間軸 | 收集器每 5 分鐘取得的快照（`usage.json` 的內容） | **整個帳號**（含手機、網頁、其他電腦的使用） |
| Token 統計 | 本週 Token、單日最高、最長任務、連續天數、Token 活動、活動熱力圖、完整統計視窗 | 本機 Claude Code 與 Codex CLI 的對話紀錄 | **只有這台 Mac**（ADR-0011 第 4 節） |

Claude Code 預設約 30 天清除舊的對話紀錄（`cleanupPeriodDays`），所以 Token 統計不能每次都從紀錄重算，要每天累加存在本機。

## 決定

### 1. 誰寫、誰讀

- **收集器寫入**（launchd 每 5 分鐘）：額度歷史與 Token 統計都由收集器產生。理由：收集器已經在背景定時執行；選單列 App 關閉時也要繼續累積；之後的 Windows 收集器（ADR-0011）可以共用同一份 Python 程式。
- **選單列 App 只讀**，例外是使用者在設定中按「清除歷史」或改保留期間（第 5 節）。
- 存放位置：`~/Library/Application Support/AIUsageMonitor/history.sqlite3`（與 `usage.json` 同資料夾，同樣受 `AI_USAGE_MONITOR_HOME` 控制）。SQLite（WAL 模式、`busy_timeout` 5 秒）：Python 標準函式庫與 macOS 的 `libsqlite3` 都有，支援以鍵覆蓋寫入（upsert）與兩個程序同時存取。檔案權限 `0600`。
- **不上傳**：歷史與統計都只在本機，不送到中繼，不在 iPhone 與手錶顯示（回答 ADR-0004 Q4：本階段不把時間序列放上雲端）。第二層多裝置（ADR-0011）只上傳每日 Token 加總，那時另行說明。

### 2. 資料表

```sql
-- 額度歷史：每次收集一列 × 每個額度（不含錯誤的服務）
CREATE TABLE quota_samples (
  ts          INTEGER NOT NULL,   -- 快照的 updated_at（Unix 秒，UTC）
  provider    TEXT    NOT NULL,   -- claude / codex
  window_id   TEXT    NOT NULL,   -- five_hour / weekly / weekly_fable …
  used_pct    REAL    NOT NULL,
  resets_at   INTEGER,            -- 可為 NULL
  PRIMARY KEY (provider, window_id, ts)
);

-- 收集器每次執行一列，用來分辨「沒有紀錄」（Mac 睡眠、收集器停止）與「沒有使用」
CREATE TABLE collector_runs (ts INTEGER PRIMARY KEY, ok INTEGER NOT NULL);

-- 每日 Token 加總：一列 = 某裝置、某天、某服務、某模型
CREATE TABLE daily_tokens (
  device_id      TEXT    NOT NULL,  -- 第一階段固定為本機的 device_id（第 6 節）；預留給 ADR-0011
  day            TEXT    NOT NULL,  -- 裝置當地日期 YYYY-MM-DD
  provider       TEXT    NOT NULL,
  model          TEXT    NOT NULL,  -- 正規化後的模型名稱（第 4 節）
  input_tokens          INTEGER NOT NULL DEFAULT 0,
  output_tokens         INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
  cache_write_tokens    INTEGER NOT NULL DEFAULT 0,
  reasoning_tokens      INTEGER NOT NULL DEFAULT 0,
  task_seconds          INTEGER NOT NULL DEFAULT 0,  -- 當天任務時間合計
  longest_task_seconds  INTEGER NOT NULL DEFAULT 0,
  updated_at     INTEGER NOT NULL,
  PRIMARY KEY (device_id, day, provider, model)
);

-- 每小時加總（給「一天中各時段」與熱力圖），欄位同上但以 hour（當地時間 0～23）細分
CREATE TABLE hourly_tokens (... 同 daily_tokens，多 hour INTEGER，PRIMARY KEY 加 hour ...);

-- 掃描進度：每個紀錄檔讀到哪裡
CREATE TABLE scan_state (
  file_key   TEXT PRIMARY KEY,  -- HMAC-SHA256(本機隨機鹽, 檔案路徑)，不存路徑本身
  size       INTEGER NOT NULL,
  mtime      INTEGER NOT NULL,
  offset     INTEGER NOT NULL,  -- 已處理到的位元組（只處理到最後一個完整的換行）
  last_seen  INTEGER NOT NULL
);

-- 去重：已計入的訊息或回應 ID（只存 ID，不存內容），保留 45 天
CREATE TABLE seen_ids (provider TEXT, id TEXT, day TEXT, PRIMARY KEY (provider, id));

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);  -- schema 版本、device_id、鹽、首次掃描進度
```

- 額度歷史只存 `quota_samples` 列出的欄位：不存方案名稱、錯誤訊息、額度顯示名稱。
- 只存數字、時間、服務與模型名稱。**沒有任何欄位存對話內容、提示詞、檔案路徑、專案名稱、工作目錄、git 分支、session 標題或帳號資訊。**
- `schema_version` 存在 `meta`；欄位變更以 migration 處理，App 遇到較新的版本時唯讀並提示更新。

### 3. 讀取對話紀錄的範圍與規則（NFR-9）

**只讀這些檔案**（一般檔案，不跟隨符號連結）：

| 服務 | 路徑 |
|---|---|
| Claude Code | `$CLAUDE_CONFIG_DIR/projects/*/*.jsonl` 與 `…/projects/*/*/subagents/*.jsonl`（未設定時為 `~/.claude`） |
| Codex CLI | `$CODEX_HOME/sessions/YYYY/MM/DD/*.jsonl` 與 `$CODEX_HOME/archived_sessions/*.jsonl`（未設定時為 `~/.codex`） |

**絕不開啟**：`~/.codex/auth.json`、`~/.claude/.credentials.json`、Keychain、`~/.codex/*.sqlite`、`config.toml`、`settings.json`、`history.jsonl`、`~/.claude.json` 以及上表以外的任何檔案（收集器已有測試掃描原始碼確認不讀憑證，新增模組要加入）。

**逐行處理，只取白名單欄位**：

1. 先以位元組比對篩選（例如 Claude 只處理含 `"usage"` 的行，Codex 只處理含 `"token_count"`、`"token_usage_record"`、`"task_started"`、`"task_complete"`、`"turn_context"` 的行），其他行不解析。
2. 解析成 JSON 後**立刻**只取下表的欄位，其餘丟棄；不保留原始行、不保留整個物件。
3. 單行超過 4 MB 直接跳過（只記錄「略過一行過長的紀錄」的次數）。

| 服務 | 取用的欄位 | 不取用（舉例，會在同一行出現） |
|---|---|---|
| Claude | `type == "assistant"` 的 `timestamp`、`message.id`、`requestId`、`message.model`、`message.usage` 的四個 token 數；`isSidechain`；任務時間用 `type == "user"` 行的 `timestamp` 與 `promptId`（只用於配對） | `message.content`、`cwd`、`gitBranch`、`sessionId` 以外的識別、附件、檔案快照、`lastPrompt`、`customTitle` |
| Codex | `token_count` 的 `info.last_token_usage`、`timestamp`；`token_usage_record` 的 `response_id` 與 `usage`；`turn_context` 的 `model`；`task_started`／`task_complete` 的 `turn_id`、`started_at`、`completed_at`、`duration_ms` | `task_complete.last_agent_message`、`turn_context.cwd`、`workspace_roots`、`response_item` 的一切、`rate_limits` |

> 限制：JSON 格式無法只解析部分欄位，篩選過的行仍會整行載入記憶體再丟棄。規則是「載入後只取白名單、不保留、不輸出」，不是「完全不讀到」。

**錯誤與日誌**：例外只記錄類別名稱與檔案序號（第幾個檔案），不記錄檔名、路徑、行內容或例外訊息（`json.JSONDecodeError` 的訊息會帶出原文片段）。日誌與 `usage.json` 不出現任何對話紀錄的內容。

### 4. 計算規則

- **去重**：Claude Code 串流時同一則回應會寫成多行（每個內容區塊一行，`usage` 相同或遞增），以 `message.id`（沒有時用 `requestId`）去重，取同一 ID 的最後一行；`--resume` 或分支產生的新檔會複製舊訊息，以 `seen_ids` 跨檔去重。Codex 以 `token_usage_record.response_id` 去重；舊版沒有這種事件時，用 `token_count.info.last_token_usage`（每次回應的增量），**不用** `total_token_usage`（累計值，重算會重複計入）。
- **日期**：以紀錄的 `timestamp` 換算成本機當下的時區後取日期與小時。時區改變不回頭重算已存的日子。
- **模型名稱**：只接受 `[A-Za-z0-9._:-]{1,64}`，其他一律記為 `other`；`<synthetic>` 這類非模型的值記為 `other`。
- **任務時間**：Codex 用 `task_complete.duration_ms`；Claude 以同一個 `promptId` 的使用者訊息到最後一則助理回應的時間差，超過 6 小時視為中斷，以 6 小時計。歸到任務**開始**那天。
- **Token 數**：顯示的「Token」為輸入＋輸出＋快取寫入＋快取讀取＋推理（明細另存，完整統計視窗可分開看）。是否把快取讀取算進「本週 Token」列為待確認事項。
- **連續使用天數**：當天任一服務的 Token > 0 即算使用。
- **額度消耗**（ADR-0011 第一層）：同一額度相鄰兩筆 `used_pct` 的正差值；`resets_at` 改變或 `used_pct` 下降時視為重置，該段以新值計；兩筆間隔超過 15 分鐘的時段標記為「沒有紀錄」。

### 5. 保留、匯出與清除（FR-37）

| 項目 | 規則 |
|---|---|
| 保留期間 | 設定中選 7 天／30 天／90 天／1 年／永久，**預設 1 年**；寫入 `config.json` 的 `history_retention_days`（`0` 表示永久），收集器每天第一次執行時刪除過期資料 |
| 降採樣 | `quota_samples` 超過 14 天的資料降為每小時一筆（保留該小時的最後一筆與最大值）；`hourly_tokens` 超過 90 天併入 `daily_tokens` 後刪除 |
| 去重表 | `seen_ids` 保留 45 天（大於 Claude Code 預設的 30 天清除期） |
| 匯出 CSV | 設定中按「匯出 CSV」→ 系統儲存對話框，由使用者選位置；匯出 `daily_tokens` 與每小時的額度歷史，欄位同資料表，不含 `scan_state`、`seen_ids`、鹽 |
| 清除歷史 | 確認對話框後刪除 `quota_samples`、`collector_runs`、`daily_tokens`、`hourly_tokens`，執行 `VACUUM`；**保留** `scan_state` 與 `seen_ids`，避免下次收集把仍在對話紀錄中的舊資料重新算回來。另提供「清除並重新掃描」：連同掃描進度一起清除，從現有對話紀錄重建 |
| 解除安裝 | `collector/scripts/uninstall-launchd.sh` 詢問是否一併刪除 `history.sqlite3`（預設不刪）；README 的隱私章節列出檔案位置 |

估計大小：額度歷史 4 個額度 × 288 筆／天，14 天後降為每小時，一年約 5 萬列；Token 統計每年數千列；整個檔案預期 < 20 MB。

### 6. 裝置識別

第一次建立資料庫時產生隨機 UUID 存在 `meta.device_id`，顯示名稱預設「這台 Mac」，可在設定中修改（不用電腦名稱，避免把使用者名稱帶進資料）。第一階段所有列都是本機的 `device_id`；欄位為了 ADR-0011 第二層預留。

### 7. 效能（NFR-8、NFR-10）

- 增量掃描：只讀 `offset` 之後新增的位元組；檔案變小或 `mtime` 倒退時（被改寫）從頭重掃該檔，以 `seen_ids` 避免重複計入。
- **首次掃描分段**：每次執行最多處理 64 MB 或 15 秒（先到者為準），其餘留給下次；以 `nice` 執行。面板在首次掃描完成前顯示「正在整理過去的紀錄（N%）」。
- 一般情況每次執行增加的時間 < 1 秒（以 400 MB 紀錄、每 5 分鐘新增數 MB 估計），須以測試量測並寫進 PR。
- App 只在面板或統計視窗開啟時查詢資料庫；查詢結果在面板開啟期間快取，收到 `usage.json` 變更時才重新查詢。面板關閉時關閉資料庫連線。

## 回答 ADR-0004 的問題（Mac 部分）

| # | 問題 | 回答 |
|---|---|---|
| Q1 | FR-19 的通知由誰發出 | **Mac 選單列 App**（macOS 通知），App 關閉時不通知；「上次通知的狀態」存在 App 的 `UserDefaults`。iPhone 端通知不在本 ADR 範圍（免費帳號沒有推播） |
| Q2 | 歷史要保留多久 | 使用者設定，預設 1 年；14 天後降採樣 |
| Q4 | 是否接受時間序列放在 Cloudflare | 本 ADR 不放；額度消耗（第一層）只用本機歷史即可涵蓋所有裝置，不需要上傳 |
| Q6 | 預測要有多少資料才顯示 | 近期速度需要最近 60 分鐘內至少 4 筆、跨度 ≥ 30 分鐘；不足時用本額度開始至今的平均速度（ADR-0008 第 4 節） |
| Q3 | 快照是否新增 `exhausts_at` | **不在本 ADR 決定**：Mac 自己算，不需要；iPhone 是否顯示預測另案處理 |

## 考慮過的選項

| 選項 | 不採用的原因 |
|---|---|
| JSONL 檔（ADR-0004 選項 A 的原案） | Token 統計需要以（裝置、日期、服務、模型）覆蓋寫入，JSONL 要整檔重寫；兩個程序同時讀寫要自己處理鎖 |
| 由選單列 App 掃描對話紀錄 | App 沒開時不累積，Claude Code 30 天清除後資料就沒了；Windows 收集器無法共用 |
| 用 `ccusage` 等第三方工具計算 | 多一個 Node 相依；無法保證它不讀取或輸出其他欄位 |
| 存每則訊息（而不是每日／每小時加總） | 資料量大、保留期間難控制；面板與統計視窗都不需要單則訊息 |

## 影響

- 收集器新增 `history` 與 `token_stats` 模組（只用標準函式庫），測試以假的紀錄檔確認：去重、增量、重寫、過長行、白名單（測試紀錄中放入假的內容、路徑與 email，掃描資料庫、日誌、stdout 確認沒有出現）。
- 選單列 App 新增唯讀的資料庫讀取層；設定視窗加入「歷史資料」分頁。
- README 的隱私章節（NFR-6）列出新讀取的檔案、取用的欄位與 `history.sqlite3` 的位置。
- 收集器每次執行的時間變長，launchd 的間隔不變。

## 待確認事項

1. 預設保留期間 1 年（設計圖的預設值）。
2. 「本週 Token」是否包含快取讀取（建議包含並在提示中說明；不含時數字會小很多，與 Claude Code `/cost` 的習慣不同）。
3. Claude 任務時間的定義（使用者訊息到最後一則回應，上限 6 小時）。
