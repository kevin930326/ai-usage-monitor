# collector — Mac 端用量收集器

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
| 本機快照 | `~/Library/Application Support/AIUsageMonitor/usage.json` | 最新一次的用量（Mac 選單列 App 讀這個） |
| 設定 | `~/Library/Application Support/AIUsageMonitor/config.json` | 中繼 API 網址、claude 與 codex 的完整路徑、啟用的服務（`enabled_providers`） |
| 寫入密鑰 | macOS Keychain `AIUsageMonitor-relay-write` | 不存在任何檔案中 |
| 日誌 | `~/Library/Logs/AIUsageMonitor/collector.log` | launchd 執行紀錄 |

設定環境變數 `AI_USAGE_MONITOR_HOME` 可以改變快照與設定的資料夾（測試用）。

## 設定中繼 API

部署好 [relay](../relay/) 之後：

```bash
scripts/set-relay.sh https://ai-usage-relay.<你的帳號>.workers.dev
```

腳本會把網址寫進 `config.json`，並提示你貼上寫入密鑰存進 Keychain，密鑰不會留在 shell 歷史紀錄。

## 自動排程（launchd）

```bash
scripts/install-launchd.sh     # 安裝：登入時與每 5 分鐘執行一次
scripts/uninstall-launchd.sh   # 移除
```

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
```

## 設計重點

- **不碰 Claude 的 token**：Claude 用量由 Claude Code 自己的 `/usage` 取得（[ADR-0006](../docs/adr/0006-claude-usage-via-cli.md)）。
- **token 不離開本機**：Codex 的 token 只在 Mac 上使用；只輸出百分比與重置時間；錯誤訊息不含例外內容或子程序的輸出。
- **不自行刷新 token**：避免與 Codex CLI 互搶。
- **provider 互相隔離**：單一服務失敗只會讓該服務的 `error` 有值。
- **原子寫入**：本機快照先寫暫存檔再改名，讀取端不會讀到寫一半的檔案。
- **新增服務**：在 `usage_collector/providers/` 新增模組並實作 `fetch() -> ProviderUsage`，再到 `providers/__init__.py` 註冊，並在 `scripts/detect-providers.sh` 加上偵測。
