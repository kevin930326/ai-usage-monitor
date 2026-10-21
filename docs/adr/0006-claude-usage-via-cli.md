# ADR-0006：Claude 用量改由 Claude Code 的 `/usage` 取得

- 狀態：**已採用**（取代 [ADR-0005](0005-delegate-claude-token-refresh.md)）
- 日期：2026-10-21
- 相關需求：FR-4（自動排程收集）、FR-14（各模型的每週額度）、NFR-1（token 不離開 Mac）

## 背景

原本收集器從 macOS Keychain `Claude Code-credentials` 讀出 Claude Code 的 OAuth token，自己呼叫 `https://api.anthropic.com/api/oauth/usage`；token 過期時再依 ADR-0005 委派 Claude Code 續期。

Claude Code 官方的 [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance.md) 規定，OAuth 訂閱登入只供一般使用 Claude Code 與 Anthropic 原生應用程式，不得讓第三方程式收集、儲存或中介 Claude.ai 的憑證或 session token。收集器讀 Keychain 再拿 token 打端點，正好落在這條規定的範圍內。使用者決定遵守這個條款（雲端收集也因此不採用，見 ADR-0003 與 kevin930326/ai-usage-monitor#38）。

## 決定

收集器改為執行**未修改的** Claude Code，解析它印出的額度：

```
claude -p /usage --safe-mode --no-session-persistence --output-format json
claude auth status --json      # 只取 subscriptionType 當方案名稱
```

收集器不再讀取 `Claude Code-credentials`、不持有 token、不直接呼叫 api.anthropic.com。token 的讀取、續期與 API 呼叫都由 Claude Code 自己完成。

| 細節 | 做法 | 理由 |
|---|---|---|
| 執行環境 | 暫存資料夾、stdin 關閉（`/dev/null`）、30 秒逾時 | `-p` 在 stdin 是開著的管線時會等待輸入；暫存資料夾避免載入任何專案的 CLAUDE.md |
| `--safe-mode` | 略過 hooks、外掛、MCP 與自訂指令 | 不觸發使用者的自訂流程，啟動也較快 |
| `--no-session-persistence` | 不留下 session 紀錄 | 避免每 5 分鐘在 `claude --resume` 清單多一筆 |
| `--output-format json` | 取 `result` 欄位（就是 `/usage` 的文字），並檢查 `is_error` | JSON 外層的結構比純文字穩定；不是 JSON 時（例如舊版）直接把 stdout 當文字解析 |
| claude 路徑 | 沿用 `config.json` 的 `claude_path`（安裝腳本偵測），手動執行時退回 PATH | launchd 的 PATH 只有系統目錄 |
| 個人資訊 | 只取認得的額度行與 `subscriptionType`；stdout、stderr 一律不寫入日誌、快照或錯誤訊息 | `claude auth status` 的輸出含 email、組織名稱與 ID；`/usage` 的 JSON 含 session id，文字最後一段列出本機用過的 skill、MCP 名稱 |
| 方案名稱 | `claude auth status --json` 的 `subscriptionType`（`max` → `Max`）；失敗時 `plan` 為 `null`，不算錯誤 | `/usage` 的輸出沒有方案名稱 |
| 登入偵測 | `scripts/detect-providers.sh` 改為執行 `claude auth status`（登入時結束碼 0、未登入為 1），不再查 Keychain 項目 | 安裝腳本也不碰 Claude Code 的憑證 |

JSON 格式與 `schema_version` 不變，iPhone、手錶、Mac App 與中繼都不需要修改。

### `/usage` 的輸出

Claude Code 2.1.306 的實際輸出（`--output-format text`，最後的「What's contributing」段落省略）：

```
You are currently using your subscription to power your Claude Code usage

Current session: 45% used · resets Oct 22 at 1am (Asia/Taipei)
Current week (all models): 12% used · resets Oct 28 at 7am (Asia/Taipei)
Current week (Fable): 0% used · resets Oct 28 at 7am (Asia/Taipei)
```

`--output-format json` 不提供結構化的額度欄位，`result` 是同一段文字；外層另有 `is_error`、`total_cost_usd`、`num_turns`、`local_command: "usage"` 等欄位。

| 需要的資料 | 是否取得 | 對應 |
|---|---|---|
| 5 小時額度 | ✅ | `Current session` → `five_hour` |
| 每週額度 | ✅ | `Current week (all models)` → `weekly` |
| 各模型的每週額度 | ✅ | `Current week (Fable)` → `weekly_fable`（hidden）；Max／Team 另有 `Current week (Sonnet only)` → `weekly_sonnet`（hidden） |
| 重置時間 | ✅ 可換算成絕對時間 | 見下方 |
| 方案名稱 | ❌ 不在 `/usage` 中 | 改用 `claude auth status --json` |
| email、帳號 ID | `/usage` 沒有；`auth status` 有 | 不保留 |

從 Claude Code 執行檔中的格式化程式確認的規則（2.1.306）：

- 每一行是 `{標題}: {Math.floor(utilization)}% used`，有重置時間時加上 ` · resets {時間}`；`utilization` 為 `null` 的額度整行不印。
- 重置時間固定以「日期＋時間」顯示（`Oct 22 at 1am`），分鐘為 0 時省略分鐘（`11:30pm`），**只有不是今年時才顯示年份**（`Jan 2, 2027 at 12am`），最後附上系統時區名稱（`(Asia/Taipei)`）。因此年份可以精確推回：沒有年份就是該時區的今年。
- 沒有用 Claude 訂閱登入（未登入或用 API key）時只印出這次執行的成本摘要（`Total cost: $0.0000 …`），結束碼仍為 0。
- 用到超額時第一行改為 `You are currently using your overages …`，額度行格式不變。
- 查不到額度（例如端點暫時失敗）時只有第一行，沒有任何 `Current …` 行。

精確度與現行做法的差異：使用率只到整數（無條件捨去）、重置時間只到分鐘（秒數捨去）。本次實測 API 回傳的使用率都是整數、重置時間都在整點，換算結果與 API 相同。

### 實測：耗時與不消耗額度

2026-10-21 在 Claude Code 2.1.306、Max 方案上測試：

| 項目 | 結果 |
|---|---|
| `-p /usage` 耗時 | 7 次 1.49～1.82 秒（text 1.82、json 1.62，之後 json 連續 5 次 1.69／1.49／1.55／1.55／1.53） |
| `auth status --json` 耗時 | 0.13 秒 |
| 未登入時的耗時 | 0.48 秒（`CLAUDE_CONFIG_DIR` 指向空資料夾） |
| 每次的 `total_cost_usd`、`num_turns`、`duration_api_ms`、所有 token 計數 | 全部為 0，`modelUsage` 為空 |
| 連續 5 次前後與 60 秒後的用量 | 5 小時 46%、每週 12%、Fable 0%，沒有變化 |

`/usage` 在 `-p` 模式是本機指令（`local_command: "usage"`），不呼叫模型。

與現行收集器的數字比對（2026-10-21 23:35 台北，同一秒內分別執行新舊版收集器，都不加 `--upload`、`--write-local`）：

| | 方案 | 5 小時 | 每週 | 每週 Fable | Codex |
|---|---|---|---|---|---|
| 現行版（API） | Max | 50%，`2026-10-21T16:59:59Z` | 12%，`2026-10-27T22:59:59Z` | 0%，`2026-10-27T23:00:00Z` | — |
| 新版（`/usage`） | Max | 50%，`2026-10-21T17:00:00Z` | 12%，`2026-10-27T23:00:00Z` | 0%，`2026-10-27T23:00:00Z` | 與現行版完全相同 |

使用率與方案相同。重置時間差 1 秒：API 的 `resets_at` 在整點前後帶小數秒，不同次查詢會落在 `16:59:59Z` 或 `17:00:00Z`（同一天稍早的快照就是 `17:00:00Z`），`/usage` 顯示為整點。對倒數顯示沒有影響。

## 與現行做法比較

| | 讀 token 呼叫端點（ADR-0005 之前與之後） | 執行 `claude -p /usage`（本 ADR） |
|---|---|---|
| 條款 | 第三方程式讀取並使用 OAuth token，不符合 Legal and compliance | 只執行 Claude Code 本身，收集器不接觸憑證 |
| token 過期 | 要委派續期（ADR-0005），依賴未寫入文件的「`-p` 啟動時會續期」行為，還需要節流與通知 | Claude Code 啟動時自己處理，收集器不需要知道 |
| Keychain 授權視窗 | 第一次讀取時 macOS 會詢問 | 不再出現 |
| 穩定性 | 依賴非公開的 `/api/oauth/usage` 與 `anthropic-beta` 標頭 | 依賴 `/usage` 的文字格式（同樣沒有文件保證）；格式改變時收集器回報錯誤而不是顯示錯的數字 |
| 方案名稱 | Keychain 的 `subscriptionType` | `claude auth status --json` 的 `subscriptionType` |
| 精確度 | 使用率可能有小數、重置時間到秒 | 使用率整數、重置時間到分鐘 |
| 每次耗時 | 一個 HTTPS 請求（token 過期時另加一次約 1.5 秒的委派續期） | 約 1.7 秒（啟動 Claude Code 兩次：`/usage` 約 1.5 秒＋`auth status` 0.13 秒），每 5 分鐘一次可接受 |
| 程式量 | provider＋續期模組＋狀態檔＋通知 | 一個 provider，移除 `claude_refresh.py` 與 `claude-refresh.json` |

## 考慮過的其他做法

- **維持讀 token 呼叫端點**（不採用）：不符合條款，是這次修改的原因。
- **`claude setup-token` 的長效 token**（不採用）：token 只有 `user:inference` 權限，缺少用量端點需要的 `user:profile`（ADR-0005 選項 B）；而且仍是第三方程式保管憑證。
- **Agent SDK 的用量 API**（暫不採用）：目前是 `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()`，而且收集器只用 Python 標準函式庫，引入 SDK 會增加安裝門檻。日後有穩定版時可以替換，見下方「失效時的備案」。

## 風險：`/usage` 的輸出格式沒有文件保證

`/usage` 是給人看的輸出，未來版本可能改字、改順序、改時間格式或加上顏色碼。收集器的處理方式是**寧可回報錯誤，也不顯示錯的數字**：

| 情況 | 偵測 | 表現 |
|---|---|---|
| 有 `Current …` 行但格式認不得（例如改成 `45 percent used`、重置時間改成相對時間） | 該行不符合正規表示式 | 整個 Claude 回報「Claude Code 的 /usage 輸出格式已改變，請更新收集器」，**不會**只略過那一行，也不會把缺少的欄位當成 0% |
| 重置時間的時區名稱認不得 | `zoneinfo` 找不到 | 同上 |
| 只剩各模型額度，沒有 5 小時也沒有每週 | 沒有主要額度 | 同上 |
| JSON 外層改變（沒有 `result`） | 外層檢查 | 同上 |
| 標題改名（例如 `Current session` 改成別的字） | 沒有任何 `Current …` 行，也不是已知的未登入／查不到額度輸出 | 同上 |
| 只少了其中一個額度（5 小時或每週） | — | 照常輸出有的額度，與現行收集器相同（API 回傳 `null` 時本來就略過） |
| 參數改名或移除、Claude Code 執行失敗 | 結束碼非 0 | 「Claude Code 執行 /usage 失敗（結束碼 N）」，不帶出 stderr |
| 卡住 | 30 秒逾時 | 「Claude Code 執行逾時（30 秒）」 |
| `-p /usage` 開始呼叫模型（消耗額度） | `total_cost_usd`、`num_turns` 不再是 0（收集器目前不檢查） | 每 5 分鐘一次會明顯出現在用量中；發現後應停用 Claude provider |

錯誤訊息會出現在 App 上與 `collector.log`。測試以錄下的真實輸出（已遮蔽）與依格式化程式手寫的輸出為 fixture（`collector/tests/fixtures/claude/`），升級 Claude Code 後可以重新錄一份比對。

### 失效時的備案

1. 依新格式更新正規表示式與 fixture（最常見）。
2. 改用 Claude Code 日後提供的正式介面，例如 Agent SDK 穩定版的用量 API，或 `/usage` 的結構化 JSON 輸出。
3. 停用 Claude provider（`enabled_providers` 只留 `codex`）。

不考慮退回讀取 token。

## 影響

- `collector/usage_collector/providers/claude.py` 改寫；移除 `claude_refresh.py`、它的測試與 `paths.CLAUDE_REFRESH_STATE_PATH`。
- 已存在的 `~/Library/Application Support/AIUsageMonitor/claude-refresh.json` 不再使用，可以刪除（只有時間戳記，不含 token）。
- `scripts/detect-providers.sh` 改用 `claude auth status`；`install-launchd.sh` 先找 claude 路徑再偵測。
- **不需要重新安裝 launchd**：plist 只指定 Python 與 `collector/` 資料夾，下一次排程執行就會用新程式；`config.json` 已有 `claude_path`（ADR-0005 時寫入）。只有從沒寫入過 `claude_path`、而 claude 又不在 launchd 的 PATH 時，才要重新執行 `scripts/install-launchd.sh`，此時 App 會顯示「找不到 claude 執行檔」。
- ADR-0005 的委派續期不再需要，標記為被本 ADR 取代。

## 附錄：Codex 是否有類似的本機指令（只調查，不實作）

現有 Codex provider 讀 `~/.codex/auth.json` 呼叫 `https://chatgpt.com/backend-api/wham/usage`，本 ADR 不修改。調查 Codex CLI 0.163.0-alpha.10.2（隨 ChatGPT.app 安裝在 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`）：

| 候選 | 結果 |
|---|---|
| TUI 的 `/status` | 只在互動介面中可用；`codex exec "/status"` 會把它當成提示送給模型，**會消耗額度**，沒有執行 |
| `codex login status` | 只顯示登入狀態，沒有額度 |
| `codex doctor` | 診斷安裝與設定，沒有額度 |
| **`codex app-server` 的 `account/rateLimits/read`** | ✅ 可用。標準輸入輸出上的 JSON-RPC：`initialize` → `initialized` → `account/rateLimits/read`，不開啟對話、不呼叫模型 |

`account/rateLimits/read` 的實測（2026-10-21）：

- 耗時：啟動與 `initialize` 0.14 秒，查詢 0.71 秒，合計約 0.85 秒。
- 回應是結構化 JSON：`rateLimits.primary`／`secondary` 各有 `usedPercent`、`windowDurationMins`（300、10080）、`resetsAt`（Unix 秒），另有 `planType`（`team`）、`credits`、`rateLimitReachedType`、`rateLimitsByLimitId`。
- 數字與現行 Codex provider 完全一致：5 小時 34%、重置 `2026-10-21T16:13:31Z`；每週 8%、重置 `2026-10-27T09:45:10Z`。
- 回應含 `accountId`（帳號 ID），若採用只能取額度欄位。
- 執行後 `~/.codex/auth.json` 的修改時間沒有變（仍是 2026-10-19），沒有觸發續期。
- 限制：`app-server` 標示為 **experimental**，協定可能變更；需要寫一個小的 JSON-RPC 用戶端（標準函式庫即可）；路徑與 Claude 一樣要由安裝腳本偵測。

結論：Codex 有不消耗額度、結構化、含重置時間的本機介面，比 Claude 的文字輸出更適合解析。是否改用（以及 OpenAI 的條款是否有類似要求，本次沒有查證）由另一個 ADR 決定。
