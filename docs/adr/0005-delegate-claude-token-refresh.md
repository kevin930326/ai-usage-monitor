# ADR-0005：Claude token 過期時委派 Claude Code 續期

- 狀態：**已被 [ADR-0006](0006-claude-usage-via-cli.md) 取代**（2026-10-21：收集器不再讀取 Claude 的 token，改由 Claude Code 的 `/usage` 取得用量，token 由 Claude Code 自己續期）
- 日期：2026-10-21
- 相關需求：FR-4（自動排程收集）

## 背景

Claude Code 的 OAuth access token 有效期只有幾小時，平常由 Claude Code 在**下一次呼叫 API 時**用 refresh token 續期並寫回 Keychain `Claude Code-credentials`。收集器只讀不寫，所以只要幾小時沒用 Claude Code，讀到的 token 就是過期的。

2026-10-21 08:10～12:08（台北時間）`collector.log` 每 5 分鐘都是「token 已過期」，手機上的 Claude 額度停止更新約 4 小時，直到使用者打開 Claude Code。

## 決定

收集器讀到的 Claude token **已過期或距離 `expiresAt` 不到 5 分鐘**時，執行一次：

```
claude -p /usage --safe-mode --no-session-persistence
```

讓 Claude Code 在啟動時用它自己的流程續期，之後收集器重新讀取 Keychain 再查詢用量。做法參考 [shuaiyuan17/tomo#419](https://github.com/shuaiyuan17/tomo/pull/419)。

| 細節 | 做法 | 理由 |
|---|---|---|
| 執行環境 | 暫存資料夾、stdin 關閉、輸出丟棄、30 秒逾時 | `-p` 在 stdin 是開著的管線時會等待輸入；暫存資料夾避免載入 repo 的 CLAUDE.md；輸出不進日誌 |
| `--safe-mode` | 略過 hooks、外掛、MCP 與自訂指令 | 不觸發使用者的自訂流程，啟動也較快（實測約 1.5 秒） |
| `--no-session-persistence` | 不留下 session 紀錄 | 避免每次續期都在 `claude --resume` 清單多一筆 |
| claude 路徑 | 安裝腳本偵測完整路徑寫進 `config.json` 的 `claude_path`；找不到就略過續期 | launchd 的 PATH 只有系統目錄 |
| 頻率 | 最多每 30 分鐘嘗試一次，時間記在 `claude-refresh.json` | 續期失敗時不要每 5 分鐘都啟動 Claude Code、打用量端點 |
| 失敗通知 | 過期且續期失敗超過 30 分鐘，發一次 macOS 通知；同一個 `expiresAt` 只通知一次 | 委派失效時使用者仍會知道要開 Claude Code |

收集器本身**仍然不發送任何刷新請求、不寫入憑證**。

### 實測：不消耗額度

2026-10-21 在 Claude Code 2.1.306 連續執行 5 次 `claude -p /usage --safe-mode --no-session-persistence --output-format json`：

- 每次 `total_cost_usd` 為 0、`num_turns` 為 0、所有 token 計數為 0、`duration_api_ms` 為 0，耗時 1.4～1.9 秒。
- 執行前、第 1 次後、第 5 次後與 60 秒後各查一次用量，5 小時額度都是 12.0%、每週 2.0%，沒有變化。

`/usage` 在 `-p` 模式是本機指令，不呼叫模型。

## 考慮過的其他做法

### A. 收集器自行刷新（不採用）

收集器拿 refresh token 呼叫 OAuth 端點換新 token。

- **會和 Claude Code 互搶**：refresh token 是一次性的（換新後舊的失效）。收集器與 Claude Code 同時刷新時，輸的一方手上的 refresh token 失效，最壞情況是 Claude Code 被登出。Claude Code 刷新時有自己的鎖，收集器拿不到。
- 要寫回 Keychain，等於收集器要複製 Claude Code 的 client id、scope 與儲存格式，Claude Code 一改就壞，而且壞的是使用者的登入。
- 違反「token 只讀」的設計原則（[架構 2.1](../02-architecture.md#21-mac-收集器-collector)）。

### B. `claude setup-token` 長效 token（不採用）

`setup-token` 產生一年期的 token，但只有 `user:inference` 權限，**缺少用量端點 `/api/oauth/usage` 需要的 `user:profile`**，無法查詢額度。另外它需要使用者額外執行一次並把 token 交給收集器保管，增加外洩面。（權限不足是使用者先前的觀察，本 ADR 沒有重新實測。）

### C. 執行一個真正的提示，例如 `claude -p "hi"`（不採用）

一定會續期，但每次都消耗額度，而且會出現在用量裡，干擾收集器要量的數字。

### D. `claude auth status`（不採用）

tomo#419 的作者觀察到它不會觸發續期。

## 風險：依賴未寫入文件的行為

「`claude -p` 啟動時會續期快過期的 token」不是 Claude Code 文件承諾的行為，未來版本可能改變。tomo#419 的作者從 CLI 觀察到啟動時的續期只在距離 `expiresAt` 約 5 分鐘內觸發，這也是本 ADR 選 5 分鐘門檻的原因。

本次實測時 token 仍有效（這個 session 本身就是 Claude Code，會持續續期），所以**沒有在真正過期的 token 上驗證續期**；只驗證了指令可以執行且不消耗額度。合併後的第一次過期可以從日誌確認：

```
claude: token 已過期，已委派 Claude Code 續期（completed）
```

之後下一行沒有「token 已過期」錯誤，就代表續期成功。

### 失效時的表現與備案

| 情況 | 表現 |
|---|---|
| Claude Code 不再於 `-p /usage` 時續期 | 日誌顯示 `completed` 但仍過期；30 分鐘後收到一次 macOS 通知。行為退回到本 ADR 之前：開一次 Claude Code 即可 |
| `-p /usage` 開始呼叫模型（消耗額度） | 每 30 分鐘最多一次、只在 token 過期時，影響有限。發現後應移除委派 |
| 參數改名或移除 | 指令回傳非 0，記為 `failed`，同上 |
| 找不到 claude | 日誌「找不到 claude 執行檔」，不嘗試續期；重新執行 `scripts/install-launchd.sh` |
| 續期卡住 | 30 秒後強制結束，記為 `timed_out` |

委派失效時的備案依序為：

1. 改用 Claude Code 日後提供的正式介面，例如 Agent SDK 的用量 API（tomo#419 提到 SDK 有 `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()`，目前不穩定）。
2. 找其他不呼叫模型、但會觸發續期的本機指令。
3. 只保留通知，由使用者手動開 Claude Code。

不考慮退回選項 A。

## Codex 是否有同樣的問題（只調查，不實作）

| 項目 | 結果 |
|---|---|
| token 位置 | `~/.codex/auth.json`（檔案，不在 Keychain） |
| access token 有效期 | **10 天**（JWT `iat` → `exp` 為 240 小時，2026-10-21 在本機確認） |
| id token 有效期 | 1 小時，但收集器只用 access token 與 account id，不受影響 |
| 續期方式 | Codex CLI 依 `auth.json` 的 `last_refresh` 主動續期。依 codex-rs 原始碼，超過約 8 天就會在下次使用時續期，也會在 API 回 401 時重試；本機版本沒有逐行確認 |
| 本機 CLI | `codex` 不在 PATH，隨 ChatGPT.app 安裝在 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`（0.163.0-alpha.10.2） |

**結論：目前不需要處理。** access token 有 10 天有效期，Codex CLI 大約每 8 天就會續期一次，只有連續 10 天沒用 Codex（CLI 或 ChatGPT App 裡的 Codex）才會過期，到時收集器會顯示「驗證失敗 (HTTP 401)，請重新登入」。

若日後需要委派：

- `codex exec` 會呼叫模型、消耗額度，不適合。
- `codex login status` 是本機指令，但**沒有確認它會不會觸發續期**；要用之前需要像本 ADR 一樣實測。調查時沒有執行它，因為若會續期，就會改寫 `auth.json`。
- 路徑要和 Claude 一樣由安裝腳本偵測；Codex 隨 ChatGPT.app 安裝時不在 PATH。

## 影響

- 新增 `collector/usage_collector/claude_refresh.py` 與測試（以假的 claude 執行檔模擬成功、失敗、逾時）。
- `install-launchd.sh` 偵測 claude 路徑寫進 `config.json`；`set-relay.sh` 改為合併寫入，不會洗掉 `claude_path`。
- 新增狀態檔 `~/Library/Application Support/AIUsageMonitor/claude-refresh.json`（只有時間戳記與 `expiresAt`，不含 token）。
- 已安裝的使用者要重新執行 `scripts/install-launchd.sh` 才會寫入 `claude_path`。
