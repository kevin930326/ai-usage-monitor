# collector — Mac 端用量收集器

> Windows PC 也能用同一份程式統計 Token：見 [docs/windows.md](../docs/windows.md)（`windows/install-task.ps1`）。平台差異集中在 `usage_collector/system.py`。

執行 Claude Code 的 `/usage` 取得 Claude 用量、執行 Codex CLI 的 `codex app-server` 取得 Codex 用量（只用其中一個也可以），不讀取任何服務的 token，並輸出[統一格式的 JSON](../docs/02-architecture.md#3-資料格式)。只使用 Python 標準函式庫，支援 Python 3.10 以上。

## 前置條件

| 服務 | 需要 | 收集器如何取得用量 |
|---|---|---|
| Claude | 安裝 Claude Code，在終端機執行 `claude` 並用 Claude 訂閱 `/login` 過一次（只用 Claude 桌面版不算） | 執行 `claude -p /usage`，解析它印出的額度；**不讀取 Claude 的 token**（[ADR-0006](../docs/adr/0006-claude-usage-via-cli.md)） |
| Codex | 安裝 Codex CLI（或 ChatGPT 桌面版，內附 codex），用 ChatGPT 帳號 `codex login` 過一次 | 執行 `codex app-server`，查詢 `account/rateLimits/read`；**不讀取 Codex 的 token**（[ADR-0007](../docs/adr/0007-codex-usage-via-app-server.md)） |

### 只收集有用的服務

`config.json` 的 `enabled_providers` 列出要收集的服務：

```json
{ "relay_url": "https://...", "enabled_providers": ["claude"] }
```

- `scripts/install-launchd.sh` 會自動偵測並寫入（合併寫入，不會洗掉 `relay_url` 等其他欄位）：`claude auth status` 回報已登入就啟用 claude，`codex login status` 回報用 ChatGPT 登入就啟用 codex，並印出偵測結果（`scripts/detect-providers.sh`）。偵測不讀取任何登入資訊的內容，兩個指令的輸出（可能含 email）直接丟棄。找不到指令時，該服務的設定資料夾（`~/.claude`、`~/.codex`，只看是否存在）存在就視為「不知道」、不更動這個欄位，不存在就當成沒用過、不啟用（只用其中一個服務的人不會一直看到另一個的錯誤）；結果認不得或逾時也視為「不知道」。
- 未啟用的服務不查詢、不出現在輸出的 `providers` 中、不寫日誌，App 上也不會顯示。
- 已啟用但讀不到登入資訊（例如登出了）仍是錯誤，該服務的 `error` 有值，日誌也會記錄。
- 沒有 `config.json`、沒有這個欄位或格式不對時全部啟用（舊版安裝的行為）。兩個服務都沒偵測到時安裝腳本不寫入這個欄位並提示先登入，登入後下一次排程就會開始收集。
- 之後登入了另一個服務，重新執行 `scripts/install-launchd.sh`；也可以直接編輯 `config.json`。
- 設成空陣列 `[]` 時不收集任何服務，App 會顯示「沒有啟用任何服務」，收集器結束碼為 `1`。

## 使用

```bash
cd collector
python3 -m usage_collector                 # 印出格式化 JSON
python3 -m usage_collector --compact       # 單行 JSON
python3 -m usage_collector --write-local   # 同時寫入本機 usage.json
python3 -m usage_collector --upload        # 同時上傳中繼 API（未設定時略過）
python3 -m usage_collector --write-local --upload --quiet   # launchd 用的組合
```

### Claude：執行 Claude Code 的 `/usage`

每次收集時執行未修改的 Claude Code：

```bash
claude -p /usage --safe-mode --no-session-persistence --output-format json   # 額度與重置時間
claude auth status --json                                                   # 只取方案名稱（subscriptionType）
```

收集器不讀取 Keychain 的 `Claude Code-credentials`、不持有 token、不直接呼叫 Anthropic 的端點；token 的續期由 Claude Code 啟動時自己處理（[ADR-0006](../docs/adr/0006-claude-usage-via-cli.md)）。

- `/usage` 在 `-p` 模式是本機指令，不呼叫模型、不消耗額度；每次約 1.5 秒。
- 在暫存資料夾執行、stdin 關閉、30 秒逾時；輸出不寫入日誌。輸出中的 email 等個人資訊不會進入快照。
- claude 的完整路徑由 `scripts/install-launchd.sh` 偵測後寫進 `config.json` 的 `claude_path`（launchd 的 PATH 找不到 claude）；手動執行時退回 PATH。
- `/usage` 的文字格式沒有文件保證。認不得時 Claude 會顯示「Claude Code 的 /usage 輸出格式已改變，請更新收集器」，不會顯示錯的數字；fixture 在 `tests/fixtures/claude/`。

| 日誌／App 上的錯誤 | 原因與處理 |
|---|---|
| 找不到 claude 執行檔 | 重新執行 `scripts/install-launchd.sh` |
| 尚未用 Claude 訂閱登入 Claude Code | 在終端機執行 `claude` 並 `/login` |
| Claude Code 暫時查不到額度 | Claude Code 這次沒拿到額度，下一次排程會再試 |
| Claude Code 的 /usage 輸出格式已改變 | Claude Code 改版，需要更新收集器 |
| Claude Code 執行逾時（30 秒）／執行 /usage 失敗 | 在終端機手動執行上面的指令確認 |

### Codex：執行 Codex CLI 的 `app-server`

每次收集時執行未修改的 Codex CLI，在標準輸入輸出上以 JSON-RPC 查詢額度，查完就關閉：

```bash
codex app-server --listen stdio://   # 送出 initialize → initialized → account/rateLimits/read
```

收集器不讀取 `~/.codex/auth.json`、不持有 token、不直接呼叫 chatgpt.com；token 的續期由 Codex CLI 自己處理（[ADR-0007](../docs/adr/0007-codex-usage-via-app-server.md)）。

- 不開對話、不呼叫模型、不消耗額度；每次約 0.7 秒。
- 在暫存資料夾執行、30 秒逾時；結束時關閉 stdin（app-server 會自己結束），等不到就結束整個 process group，不留下背景程序。
- 只取 `rateLimits` 的 5 小時、每週額度與方案名稱；回應中的帳號 ID、stderr 都不寫入日誌或快照。
- 另取重置次數卷（`rateLimitResetCredits`）的可用張數與到期時間（依到期時間分組），寫進 `reset_credits`（FR-58）；卷的 id、標題與取得時間不保留，格式不對時省略、不影響額度。**只讀、不使用卷**：程式裡沒有使用卷的方法，`tests/test_codex.py` 會掃描收集器的程式碼確認。
- codex 的完整路徑由 `scripts/install-launchd.sh` 偵測後寫進 `config.json` 的 `codex_path`；沒有設定時退回 PATH 與 ChatGPT.app 內附的 codex。
- app-server 標示為 experimental，格式沒有保證。認不得時 Codex 會顯示「Codex app-server 的回應格式已改變，請更新收集器」，不會顯示錯的數字；fixture 在 `tests/fixtures/codex/`。

| 日誌／App 上的錯誤 | 原因與處理 |
|---|---|
| 找不到 codex 執行檔 | 重新執行 `scripts/install-launchd.sh` |
| 尚未登入 Codex CLI | 在終端機執行 `codex login`（用 ChatGPT 帳號） |
| Codex app-server 的回應格式已改變 | Codex CLI 改版，需要更新收集器 |
| Codex app-server 回應逾時（30 秒）／意外結束／查詢額度失敗 | 在終端機執行 `codex login status` 確認登入狀態，或更新 Codex CLI |

結束碼：至少一個啟用的服務成功且上傳沒有失敗為 `0`，否則為 `1`。錯誤訊息帶時間戳記輸出到 stderr。

### 檔案位置

| 檔案 | 位置 | 內容 |
|---|---|---|
| 本機快照 | `~/Library/Application Support/AIUsageMonitor/usage.json` | 最新一次的用量（Mac 選單列 App 讀這個）。磁碟空間不足時多一個只在本機的 `local_status`（不上傳） |
| 磁碟不足標記 | `~/Library/Application Support/AIUsageMonitor/disk-low` | 空檔案：剩餘空間不足期間存在，只用來讓日誌在狀態改變時才記一行 |
| 設定 | `~/Library/Application Support/AIUsageMonitor/config.json` | 中繼 API 網址、claude 與 codex 的完整路徑、啟用的服務（`enabled_providers`）、對話紀錄資料夾（`claude_config_dir`、`codex_home`） |
| 額度歷史與 Token 統計 | `~/Library/Application Support/AIUsageMonitor/history.sqlite3` | 見下方「額度歷史」「Token 統計」 |
| 服務狀態 | `~/Library/Application Support/AIUsageMonitor/service-status.json` | 見下方「服務狀態」；只在本機、不上傳 |
| 寫入密鑰 | macOS Keychain `AIUsageMonitor-relay-write` | 不存在任何檔案中 |
| 日誌 | `~/Library/Logs/AIUsageMonitor/collector.log` | launchd 執行紀錄；超過 1 MB 時改名為 `collector.log.1`（只留一份舊的，Windows 的 `--log-file` 與 iPhone 自動重裝的 `reinstall.log` 相同；ADR-0014） |

設定環境變數 `AI_USAGE_MONITOR_HOME` 可以改變快照、設定與額度歷史的資料夾（測試用）。

### 額度歷史

`--write-local` 時，寫完 `usage.json` 並上傳之後，把這次的額度寫進本機的 SQLite 資料庫 `history.sqlite3`（[ADR-0009](../docs/adr/0009-local-history-and-token-stats.md)），給 Mac 面板的走勢、額度消耗與近期速度使用。

| 資料表 | 內容 |
|---|---|
| `quota_samples` | 每次收集 × 每個額度（不含有錯誤的服務）一列：`ts`（快照的 `updated_at`，Unix 秒）、`provider`、`window_id`、`used_pct`、`resets_at` |
| `collector_runs` | 每次收集一列：`ts`、`ok`（成功次數）、`runs`（代表幾次執行）。分辨「沒有紀錄」（Mac 睡眠、收集器停止）與「沒有使用」的依據 |
| `meta` | `schema_version`、`device_id`（隨機 UUID）、`device_name`（「這台 Mac」）、`retention_days`、`last_cleanup_day`、`downsampled_before`；App 另寫 `token_days_from`（延長保留期間或清除歷史後，實際還有每日 Token 的第一天） |

- 只存數字、時間、服務與額度 id：不存方案名稱、錯誤訊息、額度顯示名稱。**不上傳。**
- SQLite WAL 模式、`busy_timeout` 5 秒；資料庫與 `-wal`／`-shm` 權限 `0600`。
- 每天（本機日期）第一次執行時清理：刪除超過保留期間的資料（`meta.retention_days`，預設 365，`0`＝永久，由 App 的設定修改）；35 天前的資料降為每小時一筆（`quota_samples` 保留該小時最後一筆，`collector_runs` 合成一列並保留次數）。每 30 天（或可回收的空間超過 20%）`VACUUM` 並截斷 WAL，讓刪掉的空間還給磁碟；剩餘空間不到資料庫大小的 2 倍＋64 MB 時隔天再試（ADR-0014 LT-14）。
- **歷史是附加功能**：寫在 `usage.json` 與上傳之後；資料庫被鎖住、損毀、版本較新或資料夾不能寫入時，只在日誌記一行「略過額度歷史（例外類別）」，不影響 `usage.json`、上傳與結束碼。損毀的檔案不會被自動刪除或覆蓋。
- **磁碟空間不足**（剩不到 500 MB，ADR-0014 LT-06）：不寫 `history.sqlite3`（額度歷史、Token 統計、第二層同步、每日清理都暫停），`usage.json`、上傳與服務狀態照常；本機的 `usage.json` 多 `"local_status": {"history_paused": "low_disk", "disk_free_mb": N}`，Mac 面板顯示警告。不足與恢復各記一行日誌。`--tokens-only`（Windows）在不足時直接結束並回傳 1。`usage.json` 本身寫不進去時只記一行，照常上傳。被強制結束留下的暫存檔（`.usage-*.json`、`.service-status-*.json`）超過 1 天就刪掉
- 只有收集器執行 migration；App 只讀（清除歷史、縮短保留期間除外）。
- 每次執行增加的時間：`python3 scripts/measure-history.py`（一年的資料量，一般執行約 1 ms，每天第一次含清理約 3 ms）。

### Token 統計

`--write-local` 時，寫完額度歷史後讀這台 Mac 的 Claude Code 與 Codex CLI 對話紀錄，把 Token 累加進同一個 `history.sqlite3`（schema 2，[ADR-0009](../docs/adr/0009-local-history-and-token-stats.md) 第 3、4、7 節），給 Mac 面板的 Token 統計使用。只算這台 Mac，**不上傳**。

**讀哪些檔案**（一般檔案，不跟隨符號連結；資料夾依序取 `config.json` 的 `claude_config_dir`／`codex_home`、環境變數 `CLAUDE_CONFIG_DIR`／`CODEX_HOME`、預設的 `~/.claude`／`~/.codex`，安裝腳本會把 shell 中的環境變數寫進 `config.json`）：

| 服務 | 檔案 | 只取的欄位 |
|---|---|---|
| Claude Code | `<claude>/projects/*/<uuid>.jsonl`、`<claude>/projects/*/<uuid>/subagents/*.jsonl` | assistant 行的時間、`message.id`／`requestId`、模型、四種 Token 數、是否為子代理；user 行的時間、`isMeta`、是否為子代理、內容**是否為** `tool_result`（只看型別） |
| Codex CLI | `<codex>/sessions/YYYY/MM/DD/rollout-*.jsonl`、`<codex>/archived_sessions/rollout-*.jsonl` | `token_usage_record` 的 `response_id`、`usage`、時間；`token_count` 的累計用量與時間；`turn_context` 的模型；`task_complete` 的 `turn_id`、開始與結束時間、`duration_ms` |

不讀憑證、設定、`history.jsonl`、`tool-results/` 或上表以外的檔案。每一行先以位元組比對篩選，解析後立刻只取上表的欄位；資料庫只存數字、時間、服務、模型名稱（白名單，其他記為 `other`）與 ID，`file_key` 只用檔名中的 UUID。例外只記錄類別名稱與檔案序號。

| 資料表 | 內容 |
|---|---|
| `daily_tokens`／`hourly_tokens` | 每天（每小時）× 服務 × 模型的 `input`、`cache_write`、`cache_read`、`output`（含推理）、`reasoning`（明細）、任務數、任務時間、最長任務。日期與小時用掃描當下的本機時區 |
| `record_days` | 每天每個服務的主數字，不套用保留期間（單日最高與連續天數以它計算） |
| `record_days_cached` | 同 `record_days`，但數字含快取讀取（FR-60，單日最高（含快取）以它計算） |
| `records` | 個人紀錄（不隨保留期間刪除）：`total_tokens`、`best_day_tokens`、`longest_task_seconds`、`longest_streak_days`、含快取讀取的 `total_tokens_cached`、`best_day_tokens_cached`，以及加上 `:claude`／`:codex` 的各服務版本 |
| `scan_state` | 每個紀錄檔讀到哪裡（inode、大小、mtime、offset、Codex 的來源與上一筆累計值、跨次掃描的任務狀態） |
| `seen_ids`／`seen_tasks` | 已計入的訊息、回應與任務 ID 與當時的數值（去重與補差額）；只保留 90 天的時間窗（比時間窗舊的訊息不計算也不記錄，ADR-0009 第 4 節） |
| `file_tokens` | 每個 Codex 紀錄檔對加總的貢獻；檔案被改寫或改用 `token_usage_record` 時先扣掉再重算 |

- 主數字（「Token」）= `input + cache_write + output`，`cache_read` 不計入。
- Claude 以 `message.id` 去重，串流被切在兩次掃描之間時補差額；`--resume` 與舊副本靠 `seen_ids` 跨檔去重。任務：真人提示到下一個真人提示之前最後一則回覆，上限 6 小時。
- Codex 每個檔案只用一種來源：有 `token_usage_record` 就用它（以 `response_id` 去重），否則用 `token_count` 相鄰兩筆累計值的正差值（變小時視為 compaction，重新起算）。
- 首次掃描每次執行最多處理 64 MB 或 15 秒，進度寫在 `meta.first_scan_progress`，完成時 `meta.first_scan_done = 1`；以 `nice` 執行。無法解析與過長（> 4 MB）的行略過並計數（`meta.token_bad_lines`、`token_long_lines`）。
- 與額度歷史一樣是附加功能：資料庫被鎖住時整次放棄、只記一行日誌，不影響 `usage.json`、上傳與結束碼。
- 每日資料套用保留期間，每小時資料只留 90 天，超過 90 天沒看到的紀錄檔刪掉掃描進度。
- 量測（假紀錄 683 MB、1,700 個檔案）：首次掃描 11 次執行完成（合計 2.7 秒），之後一般執行約 8 ms。

### 服務狀態

`--write-local` 時，最後讀 Anthropic 與 OpenAI 的公開狀態頁，寫入本機的 `service-status.json`（FR-45，權限 `0600`），讓 Mac 面板分辨「服務異常」與「額度用完」。Mac App 只讀這個檔案、自己不連網。

| 服務 | 狀態頁 | 保留的欄位 |
|---|---|---|
| Claude | `https://status.claude.com/api/v2/summary.json` | 整體狀態（`indicator`、說明）、不是「正常」的元件名稱與狀態、未解決事件的名稱與影響程度 |
| Codex | `https://status.openai.com/api/v2/summary.json` | 同上 |

- 不帶任何密鑰、cookie 或帳號資訊，不跟隨到其他主機的重新導向；只送出固定的 User-Agent。
- 名稱與說明最長 120 字、各最多 8 項；事件的內文、連結與其他欄位不保存。元件名稱含「Claude Code」「Claude API」（Codex：「Codex」「Responses」）時標記為與這個工具相關。
- 兩次抓取至少間隔 4 分鐘（啟用的服務改變時立刻重抓）；每個狀態頁逾時 8 秒。抓不到時該服務記錯誤類別，其他照常。
- 不放進快照、不上傳到中繼；失敗只記錯誤類別，不影響 `usage.json`、上傳與結束碼。

### 第二層：多台電腦的 Token 合併（選用）

設定後（[docs/tier2-setup.md](../docs/tier2-setup.md)），每一輪 Token 統計之後由 `usage_collector/token_sync.py` 上傳這台電腦有變動的每日加總，Mac 有讀取密鑰時再下載其他電腦的加總寫進 `daily_tokens`（其他 `device_id`）與 `devices` 表。`config.json` 的 `token_sync` 不是 `true` 時完全不執行。

- 每小時＋本機日期改變後的第一輪；每批 400 列、每輪最多 5 批或 60 秒。進度記在 `upload_state`（每列上次上傳的數值雜湊），失敗時不前進，以 5 分鐘、15 分鐘、1 小時、6 小時遞增間隔重試。
- 連續兩次 401 停止上傳（403 只會來自 Cloudflare 邊緣，照一般失敗重試）（`meta.upload_status = revoked`，面板顯示密鑰失效），重新執行設定腳本才恢復。
- 這台電腦在中繼上的 `device_id` 由中繼依密鑰決定（和本機 `meta.device_id` 不同）；下載時略過自己的所有 `device_id`，本機的數字以本機統計為準。
- 日誌只記錄狀態碼與錯誤類別，不記錄密鑰、網址與資料內容；任何失敗都不影響 Token 統計、額度與結束碼。

```bash
python3 -m usage_collector.token_sync status   # 上傳狀態、待上傳列數、裝置數（不含密鑰與資料內容）
python3 -m usage_collector.token_sync reset    # 清除失敗與「密鑰失效」狀態（設定腳本會執行）
python3 -m usage_collector.token_sync forget   # 刪除本機的其他電腦資料（set-tier2.sh --disable 會執行）
```

## 設定中繼 API

部署好 [relay](../relay/) 之後：

```bash
scripts/set-relay.sh https://ai-usage-relay.<你的帳號>.workers.dev
```

腳本會把網址寫進 `config.json`，並提示你貼上寫入密鑰存進 Keychain，密鑰不會留在 shell 歷史紀錄。

## 自動排程（launchd）

有兩種方式，同一時間只會有一個在收集：

- **App 內建的收集器**（發布版的 Mac App，[ADR-0013](../docs/adr/0013-download-and-install.md)）：App 內嵌 Python 與這個收集器，以 `SMAppService` 註冊 App 內的 LaunchAgent，執行 `python3.13 -I -m usage_collector --write-local --upload --quiet --agent app`（與 launchd 版相同的收集）；第一次註冊前以 `python -m usage_collector.setup` 偵測 claude／codex 並合併寫入 `config.json`。偵測到下面 `install-launchd.sh` 的 plist 或 launchd 工作時，內建的這一輪不收集。
- **`install-launchd.sh`**（從原始碼安裝）：

```bash
scripts/install-launchd.sh     # 安裝：登入時與每 5 分鐘執行一次
scripts/uninstall-launchd.sh   # 移除
```

想從 `install-launchd.sh` 改用 App 內建的：在 App 的「設定 › 背景收集器」按「改用內建收集器」（先確認內建的能跑、舊的確實停止，才把舊的 plist 移到垃圾桶）。

安裝腳本會把 [plist 範本](launchd/) 填入目前的 Python 與資料夾路徑後放到 `~/Library/LaunchAgents/`，並把偵測到的服務（`enabled_providers`）與 claude 的完整路徑寫進 `config.json`。移動 repo 資料夾、更換 Python 或 claude 的安裝位置後要重新執行安裝。

## 讓 Mac 保持清醒

launchd 排程在 Mac 睡眠時不會執行，手機上的資料會停在最後一次上傳。如果 Mac 平常都插著電：

1. 打開「系統設定」→「電池」（桌上型 Mac 為「能源」）→「選項…」
2. 開啟「**接上電源轉換器時，防止在顯示器關閉時自動進入睡眠**」

如此螢幕關閉後收集器仍會每 5 分鐘執行。限制：

- 闔上 MacBook 螢幕仍會睡眠，除非接著外接螢幕與電源。
- 使用電池時仍會照常睡眠，以節省電力。

## 測試

```bash
python3 -m unittest -v
../scripts/lint-collector.sh   # ruff＋mypy（設定在 pyproject.toml，版本固定在 requirements-lint.txt）
```

在 `collector` 資料夾執行。`tests/__init__.py` 會把資料夾與紀錄資料夾指到暫存位置，並設定 `AUM_TESTING=1`。

- 測試環境（已載入 unittest／pytest，或 `AUM_TESTING` 有值）沒有設定 `AI_USAGE_MONITOR_HOME` 時，`usage_collector.paths` 直接丟出 `TestHomeNotSet`，不會退回真的資料夾。
- 所以 `python3 -m unittest discover -s tests`（不會載入 `tests/__init__.py`）會在匯入時失敗，而不是寫到真的 `history.sqlite3`。
- Mac App 同理：UsageKit 的 `UsageFileLocator` 在測試環境（`AUM_TESTING`、`xcodebuild test`、`swift test`，以及 Debug 版的截圖與量測）沒有設定 `AI_USAGE_MONITOR_HOME` 時中止。

`scripts/verify-all.sh` 與 CI 都會跑這兩項。收集器本身只用標準函式庫，ruff 與 mypy 只裝在 `build/lint-venv`（開發用）。

## 設計重點

- **不碰 Claude 的 token**：Claude 用量由 Claude Code 自己的 `/usage` 取得（[ADR-0006](../docs/adr/0006-claude-usage-via-cli.md)）。
- **token 不離開本機**：Codex 的 token 只在 Mac 上使用；只輸出百分比與重置時間；錯誤訊息不含例外內容或子程序的輸出。
- **不自行刷新 token**：避免與 Codex CLI 互搶。
- **provider 互相隔離**：單一服務失敗只會讓該服務的 `error` 有值。
- **原子寫入**：本機快照先寫暫存檔再改名，讀取端不會讀到寫一半的檔案。
- **新增服務**：在 `usage_collector/providers/` 新增模組並實作 `fetch() -> ProviderUsage`，再到 `usage_collector/providers/__init__.py` 註冊，並在 `scripts/detect-providers.sh`（`install-launchd.sh` 用）與 `usage_collector/setup.py`（App 內建收集器用）加上偵測。
