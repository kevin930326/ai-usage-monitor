# AI Usage Monitor

[![CI](https://github.com/kevin930326/ai-usage-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/kevin930326/ai-usage-monitor/actions/workflows/ci.yml)

在 iPhone 鎖定畫面用 Live Activity 隨時查看 **Claude** 與 **Codex** 的剩餘使用額度（5 小時／每週），並可一鍵更新。Mac 選單列 App 與桌面小工具直接讀取本機資料，與 iPhone 共用同一套 Swift 程式碼。

> 🚧 開發中（目前 v0.3：Mac 收集器、中繼 API 與 iOS App 主畫面已可運作，下一步是鎖定畫面 Live Activity），進度見 [CHANGELOG](CHANGELOG.md)。

## 系統概觀

```
Mac 收集器 (Python, launchd) ──POST──▶ Cloudflare Worker (KV) ◀──GET── iOS App (Live Activity)
                                                                      ▲
                                                    iOS 捷徑自動化：定時重開 Live Activity
```

- **token 永遠留在 Mac**，上傳的只有用量百分比與重置時間。
- 不需付費 Apple Developer 帳號：用「捷徑定時重開 + 按鈕手動更新」繞過 Live Activity 的 8 小時上限。

## 文件

| 文件 | 內容 |
|---|---|
| [需求規格](docs/01-requirements.md) | 功能需求、非功能需求、範圍 |
| [系統架構](docs/02-architecture.md) | 元件、資料格式、失敗處理 |
| [開發流程](docs/03-development-workflow.md) | 分支、commit、PR 規範 |
| [相關專案調查](docs/04-related-work.md) | 既有開源方案比較與本專案定位 |
| [架構決策紀錄 (ADR)](docs/adr/) | 重要技術選擇的理由 |

## 專案結構

```
collector/   Mac 端用量收集器 (Python)
relay/       Cloudflare Worker 中繼 API
apple/       UsageKit 共用套件、iOS App + Live Activity、Mac 選單列 App、Apple Watch App
docs/        需求、架構、ADR
```

## 隱私與安全

原則：Claude Code 與 Codex 的 OAuth token **只在 Mac 上使用、不會上傳**（NFR-1）；上傳到雲端的只有用量百分比與重置時間；中繼的讀取與寫入密鑰分開（NFR-2）。所有網路請求都是 HTTPS，各 App 沒有 ATS 例外。

### 網路請求

| 發出者 | 目的地 | 認證 | 傳送／取得的內容 | 時機 |
|---|---|---|---|---|
| Mac 收集器 | `https://api.anthropic.com/api/oauth/usage` | Claude Code 的 OAuth token（從 macOS Keychain 讀取） | 取得 Claude 用量 | launchd 每 5 分鐘 |
| Mac 收集器 | `https://chatgpt.com/backend-api/wham/usage` | Codex CLI 的 token（`~/.codex/auth.json`） | 取得 Codex 用量 | launchd 每 5 分鐘 |
| Mac 收集器 | 你的 Cloudflare Worker `POST /usage` | 寫入密鑰 | 用量快照（見下方） | 每 5 分鐘，有設定中繼時 |
| iPhone App（含 Live Activity 的「更新」按鈕與捷徑） | 你的 Worker `GET /usage` | 讀取密鑰 | 取得快照 | 打開 App、回到前景、下拉、按卡片上的「更新」、捷徑自動化 |
| Apple Watch App | 你的 Worker `GET /usage` | 讀取密鑰 | 取得快照 | 打開 App、回到前景、背景重新整理（約每 30 分鐘，受 watchOS 預算限制） |
| Mac 選單列 App、桌面小工具、Live Activity 畫面、錶面複雜功能 | 不連網 | — | 只讀本機檔案或 App 傳來的資料 | — |

上傳到 Worker 的快照只有：`schema_version`、`updated_at`，以及每個服務的方案名稱（如 Max、Team）、錯誤訊息（不含 token）、各額度的 id／名稱／已用 %／重置時間／是否隱藏。不含 token、email、帳號 ID、對話內容。Worker 只保存最新一筆（KV 的 `latest`），回應帶 `Cache-Control: no-store`。

### 資料存放位置

| 裝置 | 位置 | 內容 |
|---|---|---|
| Mac | Keychain `AIUsageMonitor-relay-write` | 中繼**寫入**密鑰（只有收集器使用） |
| Mac | `~/Library/Application Support/AIUsageMonitor/usage.json` | 最新快照（選單列 App 讀取） |
| Mac | `~/Library/Application Support/AIUsageMonitor/config.json` | 中繼網址（不含密鑰） |
| Mac | `~/Library/Logs/AIUsageMonitor/collector.log` | 收集器 log（錯誤訊息，不含 token） |
| Mac | App Group `~/Library/Group Containers/group.io.github.kevin930326.AIUsageMonitor/usage.json` | 快照複本給桌面小工具；只有以 Team 簽署、帶 App Group entitlement 時才寫入 |
| Cloudflare | Worker KV `latest`；Worker secrets `READ_TOKEN`、`WRITE_TOKEN` | 最新快照；兩把密鑰 |
| iPhone | Keychain（`AfterFirstUnlockThisDeviceOnly`，不同步到 iCloud） | 中繼**讀取**密鑰 |
| iPhone | UserDefaults | 中繼網址、顯示已用／剩餘 |
| iPhone | Live Activity 內容（鎖定畫面、動態島） | 各額度百分比、重置時間、方案、錯誤訊息；**鎖定時也看得到** |
| iPhone、Apple Watch | WatchConnectivity application context | 中繼網址與**讀取密鑰**。由系統存在兩端 App 的容器中（不在 Keychain），供手錶下次啟動時取得（FR-30） |
| Apple Watch | Keychain（`AfterFirstUnlockThisDeviceOnly`）、UserDefaults | 讀取密鑰、中繼網址 |
| Apple Watch | App Group `group.io.github.kevin930326.AIUsageMonitor` 的 `usage.json` | 最新快照，給錶面複雜功能讀取；**錶面上隨時看得到**百分比 |

寫入密鑰只存在 Mac 的 Keychain 與 Cloudflare，不會傳到 iPhone 或手錶。Debug 版本的示範模式、截圖工具與環境變數覆寫（`AUM_*`）都以 `#if DEBUG` 排除，Release 版本不包含（`scripts/verify-all.sh` 會檢查 Release 執行檔中沒有這些字串）。`AI_USAGE_MONITOR_HOME` 在 Release 也有效，與收集器相同，只影響讀取本機檔案的位置。

### 已知取捨

- 讀取密鑰經 WatchConnectivity 傳到手錶時，系統會保留最後一份 application context，因此除了 Keychain 之外還有一份在系統管理的儲存區。讀取密鑰只能讀取用量百分比；若在意，可在 Cloudflare 更換 `READ_TOKEN` 後重新設定。
- Mac 選單列 App 不開沙盒（需要讀取 `~/Library/Application Support`），以 Sign to Run Locally 簽署、未開 Hardened Runtime。它不連網，也不讀任何 token。

## 免責聲明

本專案為個人學習作品，與 Anthropic、OpenAI 無關。用量資料取自 Claude Code 與 Codex CLI 使用的**非公開介面**，可能隨時變更或失效。
