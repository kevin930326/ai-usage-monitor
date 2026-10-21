# collector — Mac 端用量收集器

讀取 Claude Code 與 Codex CLI 在本機的登入資訊（只用其中一個也可以），查詢用量並輸出[統一格式的 JSON](../docs/02-architecture.md#3-資料格式)。只使用 Python 標準函式庫，支援 Python 3.10 以上。

## 前置條件

| 服務 | 需要 | token 位置 |
|---|---|---|
| Claude | 在終端機執行 `claude` 並 `/login` 過一次（只用 Claude 桌面版不會產生 CLI token） | macOS Keychain `Claude Code-credentials` |
| Codex | 執行 `codex login` 過一次 | `~/.codex/auth.json` |

### 只收集有用的服務

`config.json` 的 `enabled_providers` 列出要收集的服務：

```json
{ "relay_url": "https://...", "enabled_providers": ["claude"] }
```

- `scripts/install-launchd.sh` 會自動偵測並寫入（合併寫入，不會洗掉 `relay_url` 等其他欄位）：Keychain 有 `Claude Code-credentials` 就啟用 claude，有 `~/.codex/auth.json` 就啟用 codex，並印出偵測結果。偵測只檢查登入資訊是否存在，不讀取內容（`scripts/detect-providers.sh`）。
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

第一次讀取 Keychain 時，macOS 可能會詢問是否允許，選「永遠允許」。

### Claude token 過期時自動續期

Claude 的 token 只有幾小時有效期，平常由 Claude Code 在下次使用時續期。收集器讀到的 token 已過期或 5 分鐘內到期時，會執行一次

```bash
claude -p /usage --safe-mode --no-session-persistence
```

讓 Claude Code 自己續期，再重新讀取 Keychain。收集器本身不發送刷新請求、不寫入憑證。

- 在暫存資料夾執行、stdin 關閉、30 秒逾時；不呼叫模型，不消耗額度。
- claude 的完整路徑由 `scripts/install-launchd.sh` 偵測後寫進 `config.json` 的 `claude_path`（launchd 的 PATH 找不到 claude）；找不到就不嘗試。手動執行時退回 PATH。
- 最多每 30 分鐘嘗試一次；過期且續期失敗超過 30 分鐘時發一次 macOS 通知（同一次過期只通知一次），此時開一次 Claude Code 即可。
- 這依賴 Claude Code 未寫入文件的行為，理由、實測與失效時的備案見 [ADR-0005](../docs/adr/0005-delegate-claude-token-refresh.md)。

日誌中看到 `已委派 Claude Code 續期（completed）` 且之後沒有「token 已過期」，代表續期成功；`failed` 或 `timed_out` 代表 claude 執行失敗或逾時。

結束碼：至少一個啟用的服務成功且上傳沒有失敗為 `0`，否則為 `1`。錯誤訊息帶時間戳記輸出到 stderr。

### 檔案位置

| 檔案 | 位置 | 內容 |
|---|---|---|
| 本機快照 | `~/Library/Application Support/AIUsageMonitor/usage.json` | 最新一次的用量（Mac 選單列 App 讀這個） |
| 設定 | `~/Library/Application Support/AIUsageMonitor/config.json` | 中繼 API 網址、claude 完整路徑、啟用的服務（`enabled_providers`） |
| 續期狀態 | `~/Library/Application Support/AIUsageMonitor/claude-refresh.json` | 上次委派續期的時間與通知紀錄（不含 token） |
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

- **token 不離開本機**：只輸出百分比與重置時間；錯誤訊息不含例外內容。
- **不自行刷新 token**：避免與 Claude Code / Codex CLI 互搶。Claude token 快過期時委派 Claude Code 續期，仍失敗才提示使用者開一次原程式（[ADR-0005](../docs/adr/0005-delegate-claude-token-refresh.md)）。
- **provider 互相隔離**：單一服務失敗只會讓該服務的 `error` 有值。
- **原子寫入**：本機快照先寫暫存檔再改名，讀取端不會讀到寫一半的檔案。
- **新增服務**：在 `usage_collector/providers/` 新增模組並實作 `fetch() -> ProviderUsage`，再到 `providers/__init__.py` 註冊，並在 `scripts/detect-providers.sh` 加上偵測。
