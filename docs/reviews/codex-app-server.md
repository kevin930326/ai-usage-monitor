# 合併前審查：Codex 用量改由 `codex app-server` 取得

- 分支：`feat/codex-usage-via-app-server`（[ADR-0007](../adr/0007-codex-usage-via-app-server.md)）
- 日期：2026-10-22
- 審查者：Claude Fable 5.1 subagent，對抗式、只讀（可在暫存資料夾寫實驗腳本，不修改 repo）；修正由主 session 完成
- 審查範圍：`git diff origin/main...HEAD`，重點為 `collector/usage_collector/providers/codex.py`、`paths.py`、`__main__.py`、`http.py`、`collector/scripts/detect-providers.sh`、`install-launchd.sh` 與對應測試

## 審查重點與結論

| 重點 | 結論 |
|---|---|
| email、帳號 ID 等個人資訊是否可能進入快照、日誌、錯誤訊息或上傳資料 | **沒有路徑**。stderr 丟棄；錯誤訊息只用固定文字與整數錯誤代碼；`plan_name` 只接受 `[a-z0-9_]{1,32}`；未預期例外只輸出類別名稱；`initialize` 的 `codexHome`、通知的主機名稱與 `installationId`、回應的 `accountId` 都不會被讀取或輸出。測試以 `@`、`example-mac`、`/Users/example`、`00000000` 掃描 stdout、stderr 與快照 |
| app-server 是否一定被關閉、不留下背景程序 | 發現 1 個問題（下方 #1，已修正）。修正後：正常、逾時、JSON-RPC 錯誤、亂碼、輸出過大、中途結束、Ctrl-C、launchd 的 SIGTERM、app-server 忽略 EOF 或 SIGTERM、app-server 產生子程序，都有測試確認程序全部結束 |
| 是否還有讀取 `~/.codex/auth.json` 或處理 token 的地方 | **沒有**。程式與腳本中沒有讀取 `auth.json`、Claude 的 Keychain 項目或任何服務 token 的程式；`relay.py` 只讀自己中繼的寫入密鑰。測試會掃描收集器原始碼確認 |
| 格式改變時是否會把缺少的欄位當成 0% | **不會**。缺少、`null`、字串、布林、NaN、inf、負數都回報錯誤；長度缺少、非正整數、重複都回報格式改變，不猜是 5 小時或每週。審查另發現極端值的錯誤類型不對（下方 #5，已修正） |

## 發現的問題與處理

| # | 嚴重度 | 位置 | 問題 | 處理 |
|---|---|---|---|---|
| 1 | 中 | `codex.py` `AppServer.close` | macOS 的 `os.killpg` 對只剩殭屍的 process group 回 **EPERM**（不是 ESRCH），原本只接 `ProcessLookupError`：app-server 在等待逾時後、`killpg` 前才結束時，`close()` 丟出 `PermissionError`，已拿到的結果變成「未預期的錯誤」，程序沒被收掉、暫存資料夾也沒刪。`Popen` 成功但 selector 設定失敗時也沒有清理 | ✅ 已修正：`killpg` 的任何 `OSError` 都視為已結束，仍然 `wait()`；`stdout` 與暫存資料夾在 `finally` 中關閉；已有錯誤傳遞中時，清理錯誤不會蓋掉原本的錯誤；selector 失敗時結束程序並清理。新增以殭屍重現的測試（還原修正時會失敗） |
| 2 | 中低 | `detect-providers.sh` | `0:*ChatGPT*` 比 `0:*"API key"*` 先比對：API key 登入的說明文字若提到 ChatGPT，會被當成 ChatGPT 登入而啟用 Codex | ✅ 已修正：先比對 API key 與未登入，ChatGPT 登入以 `Logged in using ChatGPT` 開頭比對，其他一律「不知道」；新增測試 |
| 3 | 低 | `detect-providers.sh` | `codex login status`、`claude auth status` 沒有逾時，卡住時安裝腳本會無限期等待 | ✅ 已修正：兩者限時 20 秒（macOS 沒有 `timeout`，用 perl），在自己的 process group 執行，逾時整組結束並視為「不知道」。實作時發現只結束外層程序不夠：子程序仍握著輸出管線，`$(...)` 會繼續等。另外 `claude auth status` 的結束碼不是 0 或 1 時改為「不知道」（原本視為未登入）。新增測試 |
| 4 | 低 | `codex.py` `parse_window` | `resetsAt` 為 0 或負數時輸出 1970 年的重置時間；舊程式把 0 當成沒有重置時間 | ✅ 已修正：0 視為沒有重置時間，負數視為格式改變；新增測試 |
| 5 | 低 | `models.py` `parse_pct`、`codex.py` | `usedPercent` 是 `10**400` 這類超大整數時丟 `OverflowError`（快照顯示「未預期的錯誤」，不會變 0%）；`windowDurationMins` 超大時 window id 超過中繼的 64 字上限，中繼會拒收整份快照（連 Claude 的資料） | ✅ 已修正：轉不成浮點數或超過 1000（中繼的 `LIMITS.maxPct`，原本同樣會讓整份快照被拒收）一律回報百分比格式不正確；額度長度超過 366 天視為格式改變；新增測試 |
| 6 | 低 | `paths.py` `resolve_executable` | `config.json` 手動寫相對路徑時，以收集器的工作目錄判斷可執行，但在暫存資料夾執行，結果「找得到卻執行不了」 | ✅ 已修正：回傳絕對路徑；新增測試 |
| 7 | 低 | `codex.py`（`claude.py` 既有） | 收集器被 SIGKILL 時會留下空的 `aum-codex-*` 暫存資料夾（app-server 本身會因 stdin EOF 自己結束，實測沒有殘留） | 不修改：launchd 正常停止工作時送 SIGTERM（已轉成 `SystemExit` 並清理），只有強制結束才會發生，留下的是空資料夾，系統會定期清理 `$TMPDIR`。記錄在 ADR-0007 |

審查者另外提出「新的額度長度（例如 1440 分鐘 → `24h`）在 Apple 端可能有資料但不顯示」：確認 Apple 端（iPhone、Mac、手錶）是依 `hidden` 旗標顯示所有額度，只有示範資料寫死 `five_hour`／`weekly`，因此照實輸出即可，不需要決定。

## 驗證

- 收集器測試：117 個全部通過（`AI_USAGE_MONITOR_HOME=$(mktemp -d) python3 -m unittest`）。
- 突變測試：把 `killpg` 改回只接 `ProcessLookupError`，殭屍測試失敗；把 `killpg` 改成 `os.kill`，「app-server 忽略 EOF／SIGTERM 時連同子程序結束」的測試失敗。
- 實機：`python3 -m usage_collector --compact`（不上傳、不寫本機檔）與真的 Codex CLI 0.163.0-alpha.10.2 取得 Team、5 小時 0%、每週 8%，與舊做法的快照相同；執行後 `pgrep` 沒有殘留的 app-server，`~/.codex/auth.json` 的修改時間不變；`detect-providers.sh` 對真的 claude 與 codex 印出 `claude`、`codex`。
- `scripts/verify-all.sh`：修正前 16/16 通過（`79c3f8a`）；修正後重跑結果見下方。

修正後（`c9e23aa`）重跑：**16/16 通過**（collector-tests、relay-tests、usagekit-macos、usagekit-linux、iOS／Mac／watch 的 Debug 與 Release 建置、appex 嵌入、Release 不含除錯字串）。

## 使用者的決定

1. **Claude 與 Codex 的「不知道」規則不對稱**（#41 帶進來的既有行為：找不到 `claude` 一律視為「不知道」，只用 Codex、從沒裝 Claude Code 的人永遠不會寫入 `enabled_providers`，App 一直顯示 Claude 的錯誤）。
   → **選 B**：Claude 比照 Codex，找不到 `claude` 且 `~/.claude`（或 `CLAUDE_CONFIG_DIR`）不存在時視為沒用過、不啟用；資料夾存在時仍是「不知道」、不更動設定。只檢查資料夾是否存在，不讀內容。已實作並加測試（`test_codex_only_user_without_claude_code` 等）。
2. **用 API key 登入 Codex CLI 的人**重新執行安裝腳本後 Codex 會被停用（舊做法會啟用，但也查不到訂閱額度）。
   → **接受**，記錄在 ADR-0007 與 CHANGELOG。

決定後重跑 verify-all 的結果見下方。

決定後（`f54d55e`）重跑：**16/16 通過**，收集器測試 119 個。
