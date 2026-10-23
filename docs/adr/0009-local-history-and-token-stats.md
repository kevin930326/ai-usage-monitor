# ADR-0009：額度歷史與 Token 統計的存放、保留與隱私（Mac）

- 狀態：**提議中**
- 日期：2026-10-23
- 相關需求：FR-18、FR-19、FR-37、FR-40～FR-44、FR-46、NFR-1、NFR-6、NFR-8、NFR-9、NFR-10
- 回答 [ADR-0004](0004-usage-history.md) 中屬於 Mac 的部分（Q1、Q2、Q4、Q6）；iPhone 端的預測（Q3）不在本 ADR 決定
- 相關：[ADR-0006](0006-claude-usage-via-cli.md)、[ADR-0007](0007-codex-usage-via-app-server.md)（收集器不讀憑證）、[ADR-0011](0011-multi-device-usage.md)（多裝置）

## 背景

新的 Mac 面板（[ADR-0008](0008-mac-panel-layout.md)）需要兩種過去的資料：

| 資料 | 用途 | 來源 | 範圍 |
|---|---|---|---|
| 額度歷史 | 本週走勢、額度消耗熱力圖、每週預測、近期速度、重置時間軸 | 收集器每 5 分鐘取得的快照（`usage.json` 的內容） | **整個帳號**（含手機、網頁、其他電腦的使用） |
| Token 統計 | 本週 Token、單日最高、最長任務、連續天數、Token 活動、活動熱力圖、完整統計視窗 | 本機 Claude Code 與 Codex CLI 的對話紀錄 | **只有這台 Mac**（ADR-0011 第 4 節） |

Claude Code 預設清除 30 天前的對話紀錄（`cleanupPeriodDays`，可調整；桌面 App 的紀錄另有規則），所以 Token 統計不能每次都從紀錄重算，要累加存在本機。

## 決定

### 1. 誰寫、誰讀

- **收集器寫入**（launchd 每 5 分鐘）：額度歷史與 Token 統計都由收集器產生。理由：收集器已經在背景定時執行；選單列 App 關閉時也要繼續累積；之後的 Windows 收集器（ADR-0011）可以共用同一份 Python 程式。
- **選單列 App 只讀**，例外是使用者在設定中「清除歷史」或「縮短保留期間」時，由 App 立即刪除（第 5 節）。
- 存放位置：`~/Library/Application Support/AIUsageMonitor/history.sqlite3`（與 `usage.json` 同資料夾，同樣受 `AI_USAGE_MONITOR_HOME` 控制，設計 skill 第 5 節的共用路徑一併列入）。SQLite（WAL 模式、`busy_timeout` 5 秒）：Python 標準函式庫與 macOS 的 `libsqlite3` 都有，支援以鍵覆蓋寫入（upsert）與兩個程序同時存取。資料庫與 `-wal`／`-shm` 檔的權限 `0600`。
- **不上傳**：歷史與統計都只在本機，不送到中繼，不在 iPhone 與手錶顯示（回答 ADR-0004 Q4）。第二層多裝置（ADR-0011）只上傳每日 Token 加總，那時另行說明。
- **schema 版本**存在 `meta`；**只有收集器執行 migration**。App 宣告支援的版本範圍：檔案版本較新時唯讀並提示更新 App；較舊時（收集器尚未更新）顯示「請重新執行安裝腳本」，不自行改寫。

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

-- 收集器每次執行一列：分辨「沒有紀錄」（Mac 睡眠、收集器停止）與「沒有使用」的唯一依據
CREATE TABLE collector_runs (ts INTEGER PRIMARY KEY, ok INTEGER NOT NULL);

-- 每日 Token 加總：一列 = 某裝置、某天、某服務、某模型（欄位語意見第 4 節的正規化）
CREATE TABLE daily_tokens (
  device_id      TEXT    NOT NULL,  -- 第一階段固定為本機的 device_id（第 6 節）；預留給 ADR-0011
  day            TEXT    NOT NULL,  -- 紀錄當下本機時區的日期 YYYY-MM-DD
  provider       TEXT    NOT NULL,  -- 只允許 claude / codex
  model          TEXT    NOT NULL,  -- 正規化後的模型名稱（第 4 節）
  input_tokens          INTEGER NOT NULL DEFAULT 0,  -- 不含快取的輸入
  cache_write_tokens    INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
  output_tokens         INTEGER NOT NULL DEFAULT 0,  -- 含推理
  reasoning_tokens      INTEGER NOT NULL DEFAULT 0,  -- 明細，已包含在 output_tokens 內，不另外加總
  task_count            INTEGER NOT NULL DEFAULT 0,
  task_seconds          INTEGER NOT NULL DEFAULT 0,  -- 當天開始的任務時間合計
  longest_task_seconds  INTEGER NOT NULL DEFAULT 0,
  updated_at     INTEGER NOT NULL,
  PRIMARY KEY (device_id, day, provider, model)
);

-- 每小時加總（給「一天中各時段」與熱力圖）：欄位同上，多 hour INTEGER（本機時間 0～23），PRIMARY KEY 加 hour
CREATE TABLE hourly_tokens (...);

-- 個人紀錄：不隨保留期間刪除（第 5 節）
CREATE TABLE records (key TEXT PRIMARY KEY, value INTEGER NOT NULL, day TEXT);
-- key：total_tokens（累計）、best_day_tokens、longest_task_seconds、longest_streak_days

-- 掃描進度：每個紀錄檔讀到哪裡
CREATE TABLE scan_state (
  file_key   TEXT PRIMARY KEY,  -- 服務＋檔名中的 session／rollout UUID（不含任何資料夾名稱）
  inode      INTEGER NOT NULL,  -- (st_dev, st_ino)：檔案被搬移、改名時仍能對上
  device     INTEGER NOT NULL,
  size       INTEGER NOT NULL,
  mtime      INTEGER NOT NULL,
  offset     INTEGER NOT NULL,  -- 已處理到的位元組（只處理到最後一個完整的換行）
  source     TEXT,              -- Codex：record / token_count（第 4 節）
  last_total TEXT,              -- Codex 用 token_count 時，上一筆累計值（JSON 數字陣列）
  last_seen  INTEGER NOT NULL   -- 超過 90 天沒看到這個檔案就刪除該列
);

-- 去重：已計入的訊息或回應 ID 與當時計入的數值（只存 ID 與數字，不存內容）。**永久保留**（一年約數十萬列、數十 MB 以內）
CREATE TABLE seen_ids (
  provider TEXT, id TEXT,
  day TEXT, hour INTEGER, model TEXT,   -- 第一次計入時的歸屬，之後的差額也記在這裡
  input_tokens INTEGER, cache_write_tokens INTEGER, cache_read_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
  PRIMARY KEY (provider, id)
);

-- 每個 Codex 紀錄檔對加總的貢獻（只有數字），從頭重掃或換來源時先扣掉再重算（第 4、7 節）
CREATE TABLE file_tokens (
  file_key TEXT, day TEXT, hour INTEGER, model TEXT,
  input_tokens INTEGER, cache_write_tokens INTEGER, cache_read_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
  PRIMARY KEY (file_key, day, hour, model)
);

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
-- schema_version、device_id、device_name、retention_days、first_scan_progress、upload_state（ADR-0011）
```

- 額度歷史只存 `quota_samples` 列出的欄位：不存方案名稱、錯誤訊息、額度顯示名稱。
- 只存數字、時間、服務與模型名稱。**沒有任何欄位存對話內容、提示詞、檔案或資料夾路徑、專案名稱、工作目錄、git 分支、session 標題或帳號資訊。** `file_key` 只用檔名中的 UUID（Claude 為 `<session>.jsonl`、Codex 為 `rollout-…-<uuid>.jsonl`），不含專案資料夾名稱，也不雜湊路徑（同一檔案中的鹽擋不了字典攻擊，沒有意義）。

### 3. 讀取對話紀錄的範圍與規則（NFR-9）

**紀錄資料夾**：以 `config.json` 的 `claude_config_dir`／`codex_home` 為準（安裝腳本在使用者的 shell 中讀 `CLAUDE_CONFIG_DIR`／`CODEX_HOME` 後寫入；launchd 不會傳入 shell 的環境變數，與 `claude_path`／`codex_path` 同理），其次是環境變數，最後是預設的 `~/.claude`、`~/.codex`。

**只讀這些檔案**（一般檔案，不跟隨符號連結）：

| 服務 | 路徑 |
|---|---|
| Claude Code | `<claude>/projects/*/<uuid>.jsonl` 與 `<claude>/projects/*/<uuid>/subagents/*.jsonl` |
| Codex CLI | `<codex>/sessions/YYYY/MM/DD/rollout-*.jsonl` 與 `<codex>/archived_sessions/rollout-*.jsonl` |

- `*.orphaned-*.jsonl`、`*.superseded-*.jsonl` 等同一 session 的舊副本也會讀，靠 `seen_ids` 去重（不另外判斷是否為副本）。
- **不讀**：`<session>/tool-results/` 與其他子資料夾、`~/.codex/auth.json`、`~/.claude/.credentials.json`、Keychain、`~/.codex/*.sqlite`、`config.toml`、`settings.json`、`history.jsonl`、`~/.claude.json`、`stats-cache.json` 與上表以外的任何檔案。收集器已有測試掃描原始碼確認不讀憑證，新模組要加入；另加測試確認檔案列舉只回傳上表的檔案。

**逐行處理，只取白名單欄位**：

1. 先以位元組比對篩選，其他行不解析：Claude 只處理同時含 `"assistant"` 與 `"usage"`，或含 `"user"` 的行（後者只用於任務時間）；這只是保守的候選篩選，是否真的是 assistant／user 行以解析後的 `type` 欄位判斷，不依空白或欄位順序（以 `"type": "assistant"` 等不同的合法 JSON 格式測試結果相同）；Codex 只處理含 `"token_usage_record"`、`"token_count"`、`"task_started"`、`"task_complete"`、`"turn_context"` 的行。
2. 解析成 JSON 後**立刻**只取下表的欄位，其餘丟棄；不保留原始行、不保留整個物件。
3. 單行超過 4 MB 直接跳過（只記錄「略過一行過長的紀錄」的次數）。

| 服務 | 取用的欄位 | 不取用（舉例，會在同一行出現） |
|---|---|---|
| Claude | assistant 行：`timestamp`、`message.id`、`requestId`、`message.model`、`message.usage` 的 `input_tokens`／`cache_creation_input_tokens`／`cache_read_input_tokens`／`output_tokens`、`isSidechain`；user 行：`timestamp`、`isMeta`、`isSidechain`，以及 `message.content` **是否為 `tool_result`**（只判斷型別，不讀文字） | `message.content` 的文字、`cwd`、`gitBranch`、附件（含 `userEmail`、`gitStatus`）、檔案快照、`lastPrompt`、`customTitle` |
| Codex | `token_usage_record` 的 `response_id`、`usage`、`timestamp`；`token_count` 的 `info.total_token_usage`、`timestamp`（`info` 為 null 時略過）；`turn_context` 的 `model`；`task_started`／`task_complete` 的 `turn_id`、`started_at`、`completed_at`、`duration_ms` | `task_complete.last_agent_message`、`turn_context.cwd`、`workspace_roots`、`response_item` 的一切、`rate_limits` |

> 限制：JSON 無法只解析部分欄位，篩選過的行仍會整行載入記憶體再丟棄（例如 user 行的提示文字）。規則是「載入後只取白名單、不保留、不輸出」，不是「完全不讀到」。測試在假紀錄的每一種行放入假的內容、路徑與 email，確認資料庫、CSV、日誌、stdout 都沒有出現。

**錯誤與日誌**：例外只記錄類別名稱與檔案序號（第幾個檔案），不記錄檔名、路徑、行內容或例外訊息（`json.JSONDecodeError` 的訊息會帶出原文片段）。日誌與 `usage.json` 不出現任何對話紀錄的內容。

### 4. 計算規則

**Token 的正規化**（兩家語意不同，各自換算成第 2 節的欄位）：

| 欄位 | Claude（Anthropic：`input_tokens` 不含快取） | Codex（OpenAI：快取是輸入的子集、推理是輸出的子集） |
|---|---|---|
| `input_tokens` | `input_tokens` | `input_tokens − cached_input_tokens − cache_write_input_tokens`（不小於 0） |
| `cache_write_tokens` | `cache_creation_input_tokens` | `cache_write_input_tokens` |
| `cache_read_tokens` | `cache_read_input_tokens` | `cached_input_tokens` |
| `output_tokens` | `output_tokens`（已含 thinking） | `output_tokens`（已含推理） |
| `reasoning_tokens` | 不填（thinking 明細不另存） | `reasoning_output_tokens`（明細） |

- **顯示的「Token」= `input + cache_write + cache_read + output`**（不加 `reasoning`）。對 Codex 這等於 `total_tokens`，以測試驗證這個等式；`cache_write_input_tokens` 是否包含在 `input_tokens` 內要在實作時以實際紀錄再確認（本機 363 筆中 362 筆 `total == input + output`）。是否把快取讀取算進「本週 Token」列為待確認事項。
- **Claude 去重**：串流時同一則回應會寫成多行（每個內容區塊一行），以 `message.id`（沒有時用 `requestId`）去重，取同一 ID 最後一行的 `usage`；`--resume`、分支與舊副本會在別的檔案出現相同的 ID，以 `seen_ids` 跨檔去重（永久保留，所以舊副本超過任何期限後重掃也不會重算）。收集器每 5 分鐘執行，串流中的回應可能被切在兩次掃描之間，所以 `seen_ids` 保存**已計入的數值**：之後（同一次或之後的掃描、其他檔案）再看到同一 ID 時，若每個欄位都不小於已計入值，就把差額加到第一次計入的日期、小時與模型，並更新 `seen_ids`；任一欄位較小的（舊副本或較早的串流行）忽略。以測試驗證：同一 ID 的多行分散在不同掃描批次與不同檔案時，最終加總與一次讀完相同，重掃不增加。
- **Codex 來源**：每個檔案只採用一種來源，記在 `scan_state.source`。檔案中出現過 `token_usage_record` 就只用它（以 `response_id` 去重，忽略同檔的 `token_count`）；否則用 `token_count`，以**同檔相鄰兩筆 `total_token_usage` 的正差值**計算（自動吸收重送的相同事件；差值為負時視為 compaction，以新值重新起算、不計入）。第一次看到某檔時若還沒有任何 token 事件，延到下次執行再決定。
- **Codex 的重算**：每個檔案計入的數字同時記在 `file_tokens`。累計差值只在「從上次的位置接著讀」時正確，所以以下兩種情況都**先從 `daily_tokens`／`hourly_tokens` 扣掉該檔在 `file_tokens` 的貢獻、清空該檔的 `file_tokens` 與 `last_total`，再從頭重掃該檔**（同一個交易內完成）：(1) 檔案被改寫（第 7 節）；(2) 已用 `token_count` 的檔案之後出現 `token_usage_record`（來源改為 record）。來源一旦是 record 就不再改回。以測試驗證：截斷、改寫、compaction 後重掃、先只有 `token_count` 再追加重疊或不重疊的 record，結果都與一次讀完整個檔案相同，重複執行不改變統計。
- **日期與時區**：以紀錄的 `timestamp` 換算成**掃描當下**的本機時區取日期與小時；之後改時區不回頭重算。限制：旅行或另一台電腦在不同時區時，第二層合併的「同一天」不是同一個 24 小時（ADR-0011 第 1 節）。
- **模型名稱**：前綴白名單 `claude-`、`gpt-`、`codex-`、`o` 加數字（例如 `o4-mini`），且只含 `[a-z0-9._-]`、最長 64 字；其他（自訂別名、proxy、`<synthetic>`）一律記為 `other`。第二層會上傳模型名稱，所以用白名單而不是字元集。
- **任務時間**：Codex 用 `task_complete.duration_ms`（沒有時用 `completed_at − started_at`）。Claude：同一檔、非 sidechain，從一個「真人提示」（`type == "user"`、不是 `tool_result`、不是 `isMeta`）到下一個真人提示之前最後一筆 assistant 行的時間差；超過 6 小時視為中斷，以 6 小時計；sidechain（子代理）只計 Token、不另算任務。任務歸到**開始**那天。
- **連續使用天數**：當天任一服務的 Token > 0 即算使用。
- **「本週」與「上週」**：本機時間星期一 00:00 起算的日曆週（Token 統計）；額度相關的「本週走勢」則對齊各額度自己的重置時間。
- **額度消耗**（ADR-0011 第一層）：同一額度相鄰兩筆 `used_pct` 的正差值；`resets_at` 改變或 `used_pct` 下降時視為重置，該段以新值計。兩次收集之間沒有 `collector_runs` 紀錄超過 15 分鐘的時段標記為「沒有紀錄」。限制：Claude 的 `used_pct` 是整數（ADR-0006），每小時的消耗多數為 0 或 1 個百分點，熱力圖解析度較粗。
- **近期速度**（預測與「可撐到星期幾」）：5 小時額度用最近 60 分鐘、每週額度用最近 24 小時的樣本，至少 4 筆且跨度 ≥ 30 分鐘；不足時退回「本額度開始至今的平均速度」（ADR-0008 第 4 節）。

### 5. 保留、匯出與清除（FR-37）

| 項目 | 規則 |
|---|---|
| 保留期間 | 設定中選 7 天／30 天／90 天／1 年／永久，**預設 1 年**；存在 `history.sqlite3` 的 `meta.retention_days`（`0`＝永久），不寫 `config.json`（避免與安裝腳本的寫入互相覆蓋）。套用到 `quota_samples`、`collector_runs`、`daily_tokens`、`hourly_tokens`。**不套用**到 `records`（個人紀錄）與 `seen_ids` |
| 縮短保留期間 | App 立即刪除超出的資料；收集器每天第一次執行時也會依 `meta` 再刪一次 |
| 降採樣 | `quota_samples` 與 `collector_runs` 超過 35 天的資料降為每小時一筆（`quota_samples` 保留該小時最後一筆；`collector_runs` 保留該小時的執行次數），讓最近 4 週的額度消耗與「沒有紀錄」判斷維持 5 分鐘解析度；`hourly_tokens` 超過 90 天刪除（`daily_tokens` 已有同樣的加總） |
| 完整統計視窗 | 一年熱力圖需要 ≥ 1 年的保留期間；較短時只畫保留範圍內的部分並註明「保留期間 N 天」。累計 Token、單日最高、最長任務、最長連續天數讀 `records`，不受保留期間影響 |
| 匯出 CSV | 設定中按「匯出 CSV」→ 系統儲存對話框，由使用者選位置；匯出 `daily_tokens` 與每小時的額度歷史，欄位同資料表，不含 `scan_state`、`seen_ids`、`file_tokens`、`meta` |
| 清除歷史 | 確認對話框後刪除 `quota_samples`、`collector_runs`、`daily_tokens`、`hourly_tokens`、`records`，執行 `VACUUM`；**保留** `scan_state`、`seen_ids` 與 `file_tokens`（`file_tokens` 對應的加總已清除，重算時改為只清空不扣除），避免下次收集把仍在對話紀錄中的舊資料重新算回來。若收集器正在寫入，該次寫入的列可能在清除後出現（接受）。另提供「清除並重新掃描」：連同掃描進度與去重表一起清除，從現有對話紀錄重建 |
| 解除安裝 | `collector/scripts/uninstall-launchd.sh` 詢問是否一併刪除 `history.sqlite3`（含 `-wal`、`-shm`，預設不刪）；README 的隱私章節列出所有檔案：`history.sqlite3*`、App 的 UserDefaults（面板設定、通知狀態）、第二層的裝置寫入密鑰（Keychain） |

估計大小：額度歷史 4 個額度 × 288 筆／天，35 天後降為每小時，一年約 8 萬列；Token 統計每年數千列；`seen_ids` 每年數十萬列；整個檔案預期 < 50 MB。

### 6. 裝置識別

第一次建立資料庫時產生隨機 UUID 存在 `meta.device_id`，顯示名稱預設「這台 Mac」，可在設定中修改（不用電腦名稱，避免把使用者名稱帶進資料）。第一階段所有列都是本機的 `device_id`；欄位為了 ADR-0011 第二層預留。

### 7. 效能（NFR-8、NFR-10）

- 增量掃描：只讀 `offset` 之後新增的位元組；同一個 `(device, inode)` 的檔案變小或 `mtime` 倒退時（被改寫）從頭重掃該檔，Claude 以 `seen_ids` 避免重複計入；Codex 先扣掉 `file_tokens` 中該檔的貢獻再重算（第 4 節）。
- **首次掃描分段**：每次執行最多處理 64 MB 或 15 秒（先到者為準），其餘留給下次；以 `nice` 執行。以本機約 520 MB 的紀錄估計，首次約需 9 次執行（45 分鐘）。
- 一般情況每次執行增加的時間 < 1 秒，須以測試量測並寫進 PR。
- App 只在面板或統計視窗開啟時查詢資料庫；查詢結果在面板開啟期間快取，收到 `usage.json` 變更時才重新查詢。面板關閉時關閉資料庫連線。

### 8. 第一次使用（FR-46）

| 狀態 | 顯示 |
|---|---|
| 首次掃描進行中 | Token 統計：「正在整理過去的紀錄（N%）」骨架畫面；完成後當天就有過去的資料 |
| 額度歷史不足 | 走勢、額度消耗：「正在收集，幾小時後開始會有資料」骨架畫面；有 ≥ 2 筆後開始畫 |
| 沒有任何對話紀錄 | Token 統計：「這台 Mac 還沒有 Claude Code 或 Codex CLI 的紀錄」 |

### 9. 已知限制

- 不寫對話紀錄的 session 不會被統計：`claude -p --no-session-persistence`（收集器自己的 `/usage` 查詢就是這樣，正好不會被算進去）、設定為不保存紀錄的 session。
- 手機 App、claude.ai 網頁、雲端 session 沒有本機紀錄（ADR-0011）。
- 對話紀錄的格式不是公開介面，可能隨版本改變；認不得的行略過並計數，面板顯示「部分紀錄無法解析」。

## 回答 ADR-0004 的問題（Mac 部分）

| # | 問題 | 回答 |
|---|---|---|
| Q1 | FR-19 的通知由誰發出 | **Mac 選單列 App**（macOS 通知），App 關閉時不通知；「上次通知的狀態」存在 App 的 `UserDefaults`。iPhone 端通知不在本 ADR 範圍（免費帳號沒有推播） |
| Q2 | 歷史要保留多久 | 使用者設定，預設 1 年；35 天後降採樣 |
| Q4 | 是否接受時間序列放在 Cloudflare | 本 ADR 不放；額度消耗（第一層）只用本機歷史即可涵蓋所有裝置，不需要上傳 |
| Q6 | 預測要有多少資料才顯示 | 第 4 節「近期速度」：至少 4 筆且跨度 ≥ 30 分鐘；不足時用平均速度 |
| Q3 | 快照是否新增 `exhausts_at` | **不在本 ADR 決定**：Mac 自己算，不需要；iPhone 是否顯示預測另案處理 |

## 考慮過的選項

| 選項 | 不採用的原因 |
|---|---|
| JSONL 檔（ADR-0004 選項 A 的原案） | Token 統計需要以（裝置、日期、服務、模型）覆蓋寫入，JSONL 要整檔重寫；兩個程序同時讀寫要自己處理鎖 |
| 由選單列 App 掃描對話紀錄 | App 沒開時不累積，Claude Code 30 天清除後資料就沒了；Windows 收集器無法共用 |
| 用 `ccusage` 等第三方工具計算 | 多一個 Node 相依；無法保證它不讀取或輸出其他欄位 |
| 存每則訊息（而不是每日／每小時加總） | 資料量大、保留期間難控制；面板與統計視窗都不需要單則訊息 |
| `scan_state` 以雜湊後的完整路徑當鍵 | 鹽與雜湊在同一個檔案，擋不了以專案名稱試出路徑；檔案搬移、改名後也對不上 |
| 讀 `~/.claude/stats-cache.json` | 格式沒有保證；只在開發時拿來交叉比對 |

## 影響

- 收集器新增 `history` 與 `token_stats` 模組（只用標準函式庫），測試以假的紀錄檔確認：Claude 串流重複、跨檔重複、Codex 兩種來源與重送、compaction、增量、改寫、改名、過長行、白名單（假內容不外洩）、Token 等式。
- 安裝腳本把 `claude_config_dir`／`codex_home` 寫入 `config.json`。
- 選單列 App 新增唯讀的資料庫讀取層；設定視窗加入「歷史資料」分頁。
- README 的隱私章節（NFR-6）列出新讀取的檔案、取用的欄位與 `history.sqlite3` 的位置。

## 待確認事項

1. 預設保留期間 1 年（設計圖的預設值），以及保留期間不套用到個人紀錄與去重表。
2. 「本週 Token」是否包含快取讀取（建議包含並在提示中說明；不含時數字會小很多）。
3. Claude 任務時間的定義（真人提示到最後一則回應，上限 6 小時）。
