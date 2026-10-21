# AI Usage Monitor

[![CI](https://github.com/kevin930326/ai-usage-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/kevin930326/ai-usage-monitor/actions/workflows/ci.yml)

在 iPhone 鎖定畫面用 Live Activity、或用主畫面與鎖定畫面小工具，隨時查看 **Claude** 與 **Codex** 的剩餘使用額度（5 小時／每週），並可一鍵更新。Mac 選單列 App 與桌面小工具直接讀取本機資料，與 iPhone 共用同一套 Swift 程式碼。

> 🚧 開發中（目前 v0.5：Mac 收集器、中繼 API、iOS App、鎖定畫面 Live Activity 與捷徑已可運作；Mac 選單列 App 與 Apple Watch App 為預覽版，下一步是實機驗證與文件（v1.0）），進度見 [CHANGELOG](CHANGELOG.md)。

## 系統概觀

```
Mac 收集器 (Python, launchd) ──POST──▶ Cloudflare Worker (KV) ◀──GET── iOS App (Live Activity)
                                                                      ▲
                                                    iOS 捷徑自動化：定時重開 Live Activity
```

- **收集器不讀取 Claude 的 token**（改由 Claude Code 自己的 `/usage` 查詢）；Codex 的 token 永遠留在 Mac，上傳的只有用量百分比與重置時間。
- 不需付費 Apple Developer 帳號：用「捷徑定時重開 + 按鈕手動更新」繞過 Live Activity 的 8 小時上限。

## 文件

| 文件 | 內容 |
|---|---|
| [需求規格](docs/01-requirements.md) | 功能需求、非功能需求、範圍 |
| [系統架構](docs/02-architecture.md) | 元件、資料格式、失敗處理 |
| [開發流程](docs/03-development-workflow.md) | 分支、commit、PR 規範 |
| [相關專案調查](docs/04-related-work.md) | 既有開源方案比較與本專案定位 |
| [手動測試清單](docs/manual-test-checklist.md) | 模擬器與實機的操作步驟與預期結果 |
| [架構決策紀錄 (ADR)](docs/adr/) | 重要技術選擇的理由 |

## 專案結構

```
collector/   Mac 端用量收集器 (Python)
relay/       Cloudflare Worker 中繼 API
apple/       UsageKit 共用套件、iOS App + Live Activity、Mac 選單列 App、Apple Watch App
fixtures/    三個元件測試共用的範例 usage.json
scripts/     verify-all.sh：一次跑完所有測試與 Debug／Release 建置
docs/        需求、架構、ADR、手動測試清單
```

```bash
scripts/verify-all.sh              # 全部測試 + iOS／Mac／手錶的 Debug 與 Release 建置 + Release 不含 Debug 程式碼的檢查
SKIP_LINUX=1 scripts/verify-all.sh # 沒有 Docker 時略過 Linux 的 UsageKit 測試
```

## 安裝概要

只用 Claude 或只用 Codex 都可以，不必兩個都有。

1. 在 Mac 登入要監看的服務（至少一個）：Claude 在終端機執行 `claude` 並 `/login`；Codex 執行 `codex login`。
2. 部署中繼 API：見 [relay/README.md](relay/README.md)。
3. 設定收集器並安裝排程：
   ```bash
   collector/scripts/set-relay.sh https://ai-usage-relay.<你的帳號>.workers.dev
   collector/scripts/install-launchd.sh
   ```
   安裝腳本會偵測這台 Mac 登入過哪些服務，只收集那些服務，並印出結果，例如「Claude 用量：啟用」「Codex 用量：未啟用（沒有登入過 Codex CLI）」。沒用的服務不會出現在 App 上，也不會被當成錯誤。之後登入了另一個服務，重新執行 `install-launchd.sh` 即可加入。
4. 安裝 iPhone App，在設定中填入中繼網址與讀取密鑰：見 [apple/iOSApp/README.md](apple/iOSApp/README.md)。

細節見 [collector/README.md](collector/README.md)。

## 隱私與安全

原則：收集器**不讀取 Claude Code 的 token**，Claude 用量由 Claude Code 自己的 `/usage` 指令取得（[ADR-0006](docs/adr/0006-claude-usage-via-cli.md)）；Codex 的 OAuth token **只在 Mac 上使用、不會上傳**（NFR-1）；上傳到雲端的只有用量百分比與重置時間；中繼的讀取與寫入密鑰分開（NFR-2）。所有網路請求都是 HTTPS，各 App 沒有 ATS 例外。

### 網路請求

| 發出者 | 目的地 | 認證 | 傳送／取得的內容 | 時機 |
|---|---|---|---|---|
| Mac 收集器 → Claude Code | 收集器本身不連線；執行 `claude -p /usage` 與 `claude auth status`，由 Claude Code 自己向 Anthropic 查詢 | 由 Claude Code 自己處理，收集器不讀取、不持有 token | 取得 Claude 額度與方案名稱（email 等其餘輸出直接丟棄） | launchd 每 5 分鐘 |
| Mac 收集器 | `https://chatgpt.com/backend-api/wham/usage` | Codex CLI 的 token（`~/.codex/auth.json`） | 取得 Codex 用量 | launchd 每 5 分鐘 |
| Mac 收集器 | 你的 Cloudflare Worker `POST /usage` | 寫入密鑰 | 用量快照（見下方） | 每 5 分鐘，有設定中繼時 |
| iPhone App（含 Live Activity 的「更新」按鈕與捷徑） | 你的 Worker `GET /usage` | 讀取密鑰 | 取得快照 | 打開 App、回到前景、下拉、按卡片上的「更新」、捷徑自動化 |
| iPhone 主畫面／鎖定畫面小工具 | 你的 Worker `GET /usage` | 讀取密鑰（與 App 共用的 Keychain 項目） | 取得快照 | 約每 25 分鐘（資料過期時每小時），受 WidgetKit 每日次數限制；按小工具上的「更新」 |
| Apple Watch App | 你的 Worker `GET /usage` | 讀取密鑰 | 取得快照 | 打開 App、回到前景、背景重新整理（約每 30 分鐘，受 watchOS 預算限制） |
| Mac 選單列 App、桌面小工具、Live Activity 畫面、錶面複雜功能 | 不連網 | — | 只讀本機檔案或 App 傳來的資料 | — |

上傳到 Worker 的快照只有：`schema_version`、`updated_at`，以及每個服務的方案名稱（如 Max、Team）、錯誤訊息（不含 token）、各額度的 id／名稱／已用 %／重置時間／是否隱藏。不含 token、email、帳號 ID、對話內容。Worker 會驗證格式並只保存上述欄位，其他欄位一律移除（即使收集器出錯誤帶了其他資料也不會被保存）；Worker 只保存最新一筆（KV 的 `latest`），回應帶 `Cache-Control: no-store`。

### 資料存放位置

| 裝置 | 位置 | 內容 |
|---|---|---|
| Mac | Keychain `AIUsageMonitor-relay-write` | 中繼**寫入**密鑰（只有收集器使用） |
| Mac | `~/Library/Application Support/AIUsageMonitor/usage.json` | 最新快照（選單列 App 讀取） |
| Mac | `~/Library/Application Support/AIUsageMonitor/config.json` | 中繼網址（不含密鑰） |
| Mac | `~/Library/Logs/AIUsageMonitor/collector.log` | 收集器 log（錯誤訊息，不含 token，也不含 Claude Code 的輸出） |
| Mac | App Group `~/Library/Group Containers/group.io.github.kevin930326.AIUsageMonitor/usage.json` | 快照複本給桌面小工具；只有以 Team 簽署、帶 App Group entitlement 時才寫入 |
| Cloudflare | Worker KV `latest`；Worker secrets `READ_TOKEN`、`WRITE_TOKEN` | 最新快照；兩把密鑰 |
| iPhone | Keychain（`AfterFirstUnlockThisDeviceOnly`，不同步到 iCloud） | 中繼**讀取**密鑰；App 與小工具以 Keychain 群組（App 自己的 application identifier）共用同一個項目 |
| iPhone | App Group `group.io.github.kevin930326.AIUsageMonitor`：UserDefaults 與 `usage.json` | 中繼網址、顯示已用／剩餘；最後一份快照（小工具抓不到中繼時顯示）。舊版存在 App 自己的 UserDefaults，第一次啟動時複製過來 |
| iPhone | 主畫面／鎖定畫面小工具 | 各額度百分比與重置時間；**鎖定畫面小工具鎖定時也看得到** |
| iPhone | Live Activity 內容（鎖定畫面、動態島） | 各額度百分比、重置時間、方案、錯誤訊息；**鎖定時也看得到** |
| iPhone → Apple Watch | WatchConnectivity `sendMessage`（不保存） | 中繼網址與**讀取密鑰**。手錶 App 開啟時向 iPhone 要、或 iPhone 儲存設定時手錶 App 正開著才傳送；系統不保存訊息，兩端只存在各自的 Keychain（FR-30）。舊版留下的 application context 會在 iPhone App 啟動時以空內容覆蓋 |
| Apple Watch | Keychain（`AfterFirstUnlockThisDeviceOnly`）、UserDefaults | 讀取密鑰、中繼網址 |
| Apple Watch | App Group `group.io.github.kevin930326.AIUsageMonitor` 的 `usage.json` | 最新快照，給錶面複雜功能讀取；**錶面上隨時看得到**百分比 |

寫入密鑰只存在 Mac 的 Keychain 與 Cloudflare，不會傳到 iPhone 或手錶。Debug 版本的示範模式、截圖工具與環境變數覆寫（`AUM_*`）都以 `#if DEBUG` 排除，Release 版本不包含（`scripts/verify-all.sh` 會檢查 Release 執行檔中沒有這些字串）。`AI_USAGE_MONITOR_HOME` 在 Release 也有效，與收集器相同，只影響讀取本機檔案的位置。

### 已知取捨

- 手錶的設定只在手錶 App 開啟、且 iPhone 在附近時同步（`sendMessage` 需要兩端可連線）。在 iPhone 改了網址或密鑰後，要打開一次手錶 App 才會套用；在那之前手錶的背景更新仍用舊設定。
- Mac 選單列 App 不開沙盒（需要讀取 `~/Library/Application Support`），以 Sign to Run Locally 簽署、未開 Hardened Runtime。它不連網，也不讀任何 token。

## 免責聲明

本專案為個人學習作品，與 Anthropic、OpenAI 無關。Claude 用量取自 Claude Code `/usage` 指令的輸出、Codex 用量取自 Codex CLI 使用的非公開介面，兩者都**沒有文件保證**，可能隨時變更或失效。
