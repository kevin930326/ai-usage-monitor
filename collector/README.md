# collector — Mac 端用量收集器

讀取 Claude Code 與 Codex CLI 在本機的登入資訊，查詢用量並輸出[統一格式的 JSON](../docs/02-architecture.md#3-資料格式)。只使用 Python 標準函式庫，支援 Python 3.10 以上。

## 前置條件

| 服務 | 需要 | token 位置 |
|---|---|---|
| Claude | 在終端機執行 `claude` 並 `/login` 過一次（只用 Claude 桌面版不會產生 CLI token） | macOS Keychain `Claude Code-credentials` |
| Codex | 執行 `codex login` 過一次 | `~/.codex/auth.json` |

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

結束碼：至少一個服務成功且上傳沒有失敗為 `0`，否則為 `1`。錯誤訊息帶時間戳記輸出到 stderr。

### 檔案位置

| 檔案 | 位置 | 內容 |
|---|---|---|
| 本機快照 | `~/Library/Application Support/AIUsageMonitor/usage.json` | 最新一次的用量（Mac 選單列 App 讀這個） |
| 設定 | `~/Library/Application Support/AIUsageMonitor/config.json` | 中繼 API 網址 |
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

安裝腳本會把 [plist 範本](launchd/) 填入目前的 Python 與資料夾路徑後放到 `~/Library/LaunchAgents/`。移動 repo 資料夾或更換 Python 後要重新執行安裝。

## 測試

```bash
python3 -m unittest -v
```

## 設計重點

- **token 不離開本機**：只輸出百分比與重置時間；錯誤訊息不含例外內容。
- **不自行刷新 token**：避免與 Claude Code / Codex CLI 互搶，過期時提示使用者開一次原程式。
- **provider 互相隔離**：單一服務失敗只會讓該服務的 `error` 有值。
- **原子寫入**：本機快照先寫暫存檔再改名，讀取端不會讀到寫一半的檔案。
- **新增服務**：在 `usage_collector/providers/` 新增模組並實作 `fetch() -> ProviderUsage`，再到 `providers/__init__.py` 註冊。
