# ADR-0007：Codex 用量改由 `codex app-server` 取得

- 狀態：**已採用**
- 日期：2026-10-22
- 相關需求：FR-4（自動排程收集）、NFR-1（token 不離開 Mac）
- 相關：[ADR-0006](0006-claude-usage-via-cli.md)（Claude 用同一個思路改用 `claude -p /usage`；附錄是本 ADR 的前期調查）

## 背景

原本 Codex provider 讀取 `~/.codex/auth.json` 的 `access_token` 與 `account_id`，自己呼叫 ChatGPT 的非公開端點 `https://chatgpt.com/backend-api/wham/usage`。ADR-0006 讓 Claude 改為執行 Claude Code 本身後，Codex 是收集器裡唯一還在讀取、持有服務 token 的地方。

Codex CLI 有給桌面 App 與編輯器外掛使用的本機介面 `codex app-server`，[CodexMeter](https://github.com/raycalrui/CodexMeter)（Mac 選單列的 Codex 額度工具）就是以 `codex app-server --listen stdio://` 取得帳號與額度，並註明「stdio transport keeps account credentials inside the official Codex process」。本 ADR 決定收集器也改走這個介面，完成後收集器不讀取任何服務的 token。

## 調查

### 環境

- Codex CLI `codex-cli 0.163.0-alpha.10.2`，隨 ChatGPT.app 安裝在 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`（這台 Mac 的 PATH 沒有 `codex`）。
- 用 ChatGPT（Team 方案）登入。

### CodexMeter 的做法（`CodexMeter/CodexUsageService.swift`，2026-10-11 的 `4c6baee`）

| 項目 | 做法 |
|---|---|
| 啟動 | `codex app-server --listen stdio://`，stdin／stdout／stderr 都是管線；PATH 前面加上 codex 所在資料夾與 `~/.local/bin`、`/opt/homebrew/bin` 等（npm 版 codex 需要 node） |
| 握手 | `initialize`（`clientInfo` 帶名稱與版本）→ 等回應 → `initialized` 通知 |
| 查詢 | `account/read`（帳號類型、方案、**email**）與 `account/rateLimits/read`；另有 `account/usage/read` 取 token 用量 |
| 回應格式 | 一行一個 JSON 物件，JSON-RPC 2.0 但不帶 `"jsonrpc": "2.0"`；有 `method` 沒有 `id` 的是通知（`account/rateLimits/updated` 等） |
| 解析 | 優先讀 `rateLimitsByLimitId`（多個額度），沒有時讀舊的單一 `rateLimits`；每個額度的 `primary`／`secondary` 有 `usedPercent`、`windowDurationMins`、`resetsAt` |
| 結束 | 常駐的選單列 App，程序一直開著；需要時 `terminate()` |
| 個人資訊 | 錯誤訊息只依已知的錯誤代碼選本機文字，註明上游訊息可能含憑證或帳號資料 |

收集器每 5 分鐘只要查一次，不需要常駐；也不需要 `account/read`（方案名稱在 `rateLimits.planType` 裡），因此**完全不送會回傳 email 的請求**。

### 實測（2026-10-22）

自己寫的探測腳本（只送 `initialize`、`initialized`、`account/rateLimits/read`，然後關閉 stdin）：

| 項目 | 結果 |
|---|---|
| 5 小時額度 | ✅ `rateLimits.primary`：`usedPercent` 0、`windowDurationMins` 300、`resetsAt` Unix 秒 |
| 每週額度 | ✅ `rateLimits.secondary`：`usedPercent` 8、`windowDurationMins` 10080、`resetsAt` `1793094310`（`2026-10-27T09:45:10Z`） |
| 方案名稱 | ✅ `rateLimits.planType`：`team` |
| 與現行收集器比對 | 與同時間的 `usage.json`（舊做法）完全相同：Team、5 小時 0%、每週 8%、每週重置 `2026-10-27T09:45:10Z` |
| 是否消耗額度 | ❌ 不消耗。不開對話（不送 `thread/start`／`turn/start`），連續查詢 9 次前後的使用率都不變；`~/.codex/session_index.jsonl` 沒有新增紀錄 |
| 耗時 | 啟動與 `initialize` 0.05～0.12 秒，查詢 0.5～0.7 秒；收集器的 `fetch()` 連續 5 次 0.64～0.82 秒（`claude -p /usage` 約 1.5 秒） |
| 結束 | 關閉 stdin 後 app-server 約 0.05 秒自己結束（結束碼 0）；不啟動子程序；之後 `pgrep` 找不到殘留程序 |
| `~/.codex/auth.json` | 修改時間（2026-10-19）、大小與 SHA-256 在多次執行前後都不變，沒有觸發續期 |
| 個人資訊 | `account/rateLimits/read` 的回應**沒有 email**，但有 `accountId`（帳號 UUID）；`initialize` 的回應有 `codexHome`（含使用者名稱的路徑）；啟動後主動送出的 `remoteControl/status/changed` 通知有主機名稱與 `installationId` |
| 未登入 | `CODEX_HOME` 指向空資料夾：`initialize` 正常，`account/rateLimits/read` 回 `{"code": -32600, "message": "codex account authentication required to read rate limits"}` |
| 其他寫入 | app-server 會在 `CODEX_HOME` 更新 Codex 自己的 `logs_2.sqlite`、`models_cache.json` 等狀態檔，與開一次 Codex 相同；收集器不讀取這些檔案 |

`codex login status`：用 ChatGPT 登入時印出 `Logged in using ChatGPT`、結束碼 0；未登入時印出 `Not logged in`、結束碼 1；訊息都印在 stderr。執行前後 `auth.json` 同樣不變。

### 官方文件

[Codex app-server 文件](https://learn.chatgpt.com/docs/app-server)（原 developers.openai.com/codex/app-server）把它定位為「the interface Codex uses to power rich clients」，適合「a deep integration inside your own product」；但也寫明 app-server 與 WebSocket 傳輸是 **experimental**，「aren't supported for production workloads」。文件列出 `account/rateLimits/read` 與它的 `rateLimits`／`rateLimitsByLimitId` 回應。可用 `codex app-server generate-json-schema` 產生與安裝版本相符的 JSON Schema（本次產生的 `GetAccountRateLimitsResponse.json` 與實際回應一致）。

[Codex 驗證文件](https://learn.chatgpt.com/docs/auth) 說明登入資訊快取在明文的 `~/.codex/auth.json`（或系統的憑證儲存區），檔案含 access token，應該像密碼一樣保護。本次沒有找到 OpenAI 明文禁止第三方程式讀取 `auth.json` 的條款，也沒有找到允許的條款；`chatgpt.com/backend-api/wham/usage` 則完全沒有文件。

## 決定

收集器改為執行**未修改的** Codex CLI：

```
codex app-server --listen stdio://
→ {"method": "initialize", "id": 1, "params": {"clientInfo": {"name": "ai_usage_monitor", …}}}
→ {"method": "initialized", "params": {}}
→ {"method": "account/rateLimits/read", "id": 2, "params": null}
（關閉 stdin，app-server 自己結束）
```

收集器不再讀取 `~/.codex/auth.json`、不持有 token、不直接呼叫 chatgpt.com。token 的讀取、續期與 API 呼叫都由 Codex CLI 自己完成。完成後收集器的程式碼中沒有任何服務的 token（測試會掃描原始碼確認）；`http.py` 只剩上傳快照到自己的中繼 API 使用，保留。

| 細節 | 做法 | 理由 |
|---|---|---|
| 執行環境 | 暫存資料夾當工作目錄、stdin／stdout 是管線、stderr 丟棄 | app-server 不會把收集器的資料夾當成專案；stderr 可能含個人資訊 |
| 逾時 | 整段對話 30 秒（與 Claude 相同），用 `selectors` 等待 stdout | 讀取時不會無限卡住 |
| 結束 | 關閉 stdin → 等 3 秒 → 對整個 process group 送 SIGTERM → 再等 3 秒 → SIGKILL；程序剛好在等待逾時後才結束時（macOS 的 `killpg` 對只剩殭屍的 group 回 EPERM）照樣 `wait` 收掉；清理時的錯誤不會蓋掉原本的結果或錯誤，暫存資料夾一定刪除 | 正常 0.05 秒自己結束；`start_new_session` 讓 app-server 日後若啟動子程序也一起收掉。逾時、格式錯誤、未預期例外與 Ctrl-C 都走同一段清理（`with` 區塊）；launchd 的 SIGTERM 在 `__main__` 轉成 `SystemExit`，同樣會清理。收集器被 SIGKILL 時 stdin 管線跟著關閉，app-server 收到 EOF 也會自己結束（只會留下空的 `aum-codex-*` 暫存資料夾，與 Claude 的 `aum-claude-*` 相同） |
| 輸出上限 | 最多讀 1 MiB | 異常輸出不會吃光記憶體 |
| 只讀的欄位 | `rateLimits.primary`、`rateLimits.secondary`（`usedPercent`、`windowDurationMins`、`resetsAt`）與 `rateLimits.planType` | 與舊端點的資料相同；`accountId`、`credits`、`rateLimitsByLimitId` 等一律不讀 |
| 個人資訊 | 回應、通知、`initialize` 結果與 stderr 都不寫進日誌、快照或錯誤訊息；錯誤訊息只用固定文字與 JSON-RPC 錯誤代碼 | 回應含 `accountId`、路徑、主機名稱 |
| codex 路徑 | `config.json` 的 `codex_path`（安裝腳本偵測後合併寫入）→ PATH → ChatGPT.app 內附的 codex | launchd 的 PATH 只有系統目錄；ChatGPT.app 的路徑讓舊安裝不重新執行安裝腳本也能運作 |
| PATH | 執行時把 codex 所在資料夾放到 PATH 最前面 | npm 版 codex 是 `#!/usr/bin/env node` 腳本，Homebrew 的 node 與它在同一個資料夾 |
| 登入偵測 | `detect-providers.sh` 改為 `codex login status`：結束碼 0 且是 ChatGPT 登入 → 啟用；`Not logged in` 或 API key 登入 → 不啟用；其他結果（例如輸出改變）→ **不知道**；兩個狀態指令都限時 20 秒，逾時結束整個 process group，視為不知道；`claude auth status` 的結束碼不是 0 或 1 時也是不知道；找不到 codex 時 Codex 資料夾存在 → 不知道，否則不啟用 | 不再只看 `auth.json` 是否存在；「不知道」時安裝腳本不更動 `enabled_providers`（與 integration review 對找不到 claude 的處理相同） |
| 方案名稱 | `planType` 對照表（`team` → `Team`），不在表內的 `[a-z0-9_]` 名稱轉成標題大小寫（`edu_plus` → `Edu Plus`），`unknown` 或其他字元 → `null` | 新方案不會讓快照被中繼拒收 |

JSON 格式與 `schema_version` 不變，iPhone、手錶、Mac App 與中繼都不需要修改。

## 與現行做法比較

| | 讀 `auth.json` 呼叫 `wham/usage`（舊） | 執行 `codex app-server`（本 ADR） |
|---|---|---|
| 條款風險 | 第三方程式讀取明文 token 並自行呼叫沒有文件的 `chatgpt.com/backend-api`；OpenAI 沒有明文允許，文件要求把 `auth.json` 當密碼保護 | 只執行 Codex CLI 本身，用的是文件中給整合者使用的本機介面；token 不離開 Codex 程序。文件註明 app-server 不支援 production workloads，個人在自己的 Mac 上每 5 分鐘查一次額度屬於一般使用 |
| token 續期 | 收集器不續期，依賴 Codex CLI 約每 8 天的主動續期；Codex 很久沒開時 token 可能過期，收集器只能回報錯誤 | Codex CLI 自己處理（本次實測沒有觸發續期，過期時的行為由 Codex 負責） |
| 穩定性 | 依賴沒有文件的端點與欄位（`rate_limit.primary_window` …） | 依賴標示為 experimental 的協定；但有文件、有 JSON Schema，CodexMeter 等第三方工具也依賴它，欄位已經歷版本演進（新增 `rateLimitsByLimitId` 時保留了 `rateLimits`） |
| 格式改變時 | 舊程式缺少欄位就略過或報錯 | 只取認得的欄位，形狀不對一律回報「回應格式已改變」，不把缺少的百分比當成 0%（見下方） |
| 效能 | 一個 HTTPS 請求 | 約 0.7 秒（啟動 Codex CLI＋一個查詢），每 5 分鐘一次可接受 |
| 個人資訊 | 收集器記憶體中有 access token 與 account ID | 收集器記憶體中有 `accountId`（不讀取、不保留），沒有 token |
| 依賴 | 只有 Python | 需要安裝 Codex CLI（或 ChatGPT.app）；只用 Codex 網頁版的人原本也需要 `codex login` 才有 `auth.json`，實際上沒有增加門檻 |

## 風險：介面沒有穩定性保證

app-server 是 experimental，協定可能改名、改欄位或要求不同的握手。收集器的處理方式與 ADR-0006 相同：**寧可回報錯誤，也不顯示錯的數字**。

| 情況 | 表現 |
|---|---|
| `rateLimits` 不見或不是物件、額度不是物件、`windowDurationMins` 缺少、不是正整數或超過 366 天、`resetsAt` 不是整數或是負數、兩個額度長度相同、回應不是 JSON | 「Codex app-server 的回應格式已改變，請更新收集器」 |
| `usedPercent` 缺少、`null`、字串、負數、NaN、布林值、大到轉不成浮點數或超過 1000（中繼的上限，超過會讓整份快照被拒收） | 「用量百分比缺少或格式不正確」（C-04）；**不會**變成 0% |
| `resetsAt` 是 0 | 視為沒有重置時間（與舊端點相同），不顯示 1970 年 |
| `primary`／`secondary` 其中一個是 `null` | 照常輸出另一個（與舊端點回傳 `null` 時相同） |
| 兩個都沒有 | 「Codex 回應中沒有用量資料」 |
| 新的額度長度（例如 1440 分鐘） | 輸出為 `24h`／「24 小時」，不硬套成 5 小時或每週 |
| 方法改名或移除、伺服器回錯誤 | 「Codex app-server 查詢額度失敗（代碼 N）」，不帶出錯誤訊息內容 |
| 未登入 | 「尚未登入 Codex CLI，請在終端機執行 codex login」（依錯誤訊息含 `authentication required` 判斷；訊息改了會變成上一列） |
| 參數改名、app-server 啟動失敗或中途結束 | 「Codex app-server 意外結束」 |
| 卡住 | 「Codex app-server 回應逾時（30 秒）」，並結束 app-server |
| `account/rateLimits/read` 開始消耗額度 | 收集器無法偵測；每 5 分鐘一次會明顯出現在用量中，發現後應停用 Codex provider |

錯誤訊息會出現在 App 上與 `collector.log`。測試以錄下的真實回應（已遮蔽）為 fixture（`collector/tests/fixtures/codex/`），並用假的 app-server 測試逾時、不理會 EOF 與 SIGTERM、中途結束、亂碼、大量輸出、伺服器用相同 id 發來的請求與中斷時的清理。升級 Codex CLI 後可以用 `codex app-server generate-json-schema` 比對 `GetAccountRateLimitsResponse`。

### 失效時的備案

1. 依新的 JSON Schema 更新解析與 fixture（最常見）。
2. 改用 `rateLimitsByLimitId`（目前的多額度格式）；也可以把其他額度列為 hidden，像 Claude 的各模型每週額度。本次 `rateLimitsByLimitId` 只有 `codex` 一項，與 `rateLimits` 相同，先不處理。
3. 停用 Codex provider（`enabled_providers` 只留 `claude`）。

不考慮退回讀取 `auth.json`。

## 影響

- `collector/usage_collector/providers/codex.py` 改寫；`http.py` 移除沒有使用者的 `get_json`；`paths.resolve_executable` 由 Claude 與 Codex provider 共用。
- `scripts/install-launchd.sh` 偵測 codex 的完整路徑寫進 `config.json` 的 `codex_path`（合併寫入）；`scripts/detect-providers.sh` 改用 `codex login status`，並以 `?codex`／`?claude` 回報「不知道」。
- **不一定要重新安裝 launchd**：plist 沒有變；沒有 `codex_path` 時收集器會找 PATH 與 ChatGPT.app 內附的 codex。codex 裝在其他位置（npm、Homebrew）的人要重新執行 `scripts/install-launchd.sh`，此時 App 會顯示「找不到 codex 執行檔」。
- 用 API key 登入 Codex CLI 的人重新執行安裝腳本後 Codex 會被停用（API key 沒有訂閱額度，舊做法也查不到）。
