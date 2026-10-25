# 系統架構

## 1. 總覽

```
┌──────────── Mac ────────────┐      ┌──── Cloudflare Worker ────┐      ┌──────────── iPhone ─────────────┐
│ launchd（每 5 分鐘）＊       │      │ POST /usage  (寫入密鑰)    │      │ 捷徑自動化 07:00/15:00/23:00     │
│   └ collector               │─────▶│ GET  /usage  (讀取密鑰)    │◀─────│   └ RestartUsageActivityIntent  │
│      ├ Claude provider      │ 只送 │ KV 存最新一筆 usage.json   │      │                                 │
│      └ Codex provider       │ 數字 └───────────────────────────┘      │ Live Activity「更新」按鈕         │
│   收集器不讀取任何 token     │                                         │   └ RefreshUsageIntent          │
│        │ 寫入本機檔案         │                                         └─────────────────────────────────┘
│        ▼                    │
│   usage.json ──▶ 選單列 App │  （v1.2，與 iOS App 共用 UsageKit）
└─────────────────────────────┘
```

＊ 排程是 App 內建收集器的 LaunchAgent（發布版，ADR-0013），或 `install-launchd.sh` 裝的 LaunchAgent（從原始碼安裝）；兩者不會同時執行。

## 2. 元件

### 2.1 Mac 收集器 (`collector/`)
- Python 3，僅使用標準函式庫，降低安裝門檻。
- 每家服務一個 provider，介面一致：輸入無，輸出 `ProviderUsage` 或錯誤。
- Claude：執行未修改的 Claude Code `claude -p /usage --safe-mode --no-session-persistence --output-format json`（暫存資料夾、stdin 關閉、30 秒逾時；本機指令，不呼叫模型、不消耗額度），解析印出的額度與重置時間；方案名稱取自 `claude auth status --json` 的 `subscriptionType`。**收集器不讀取 Claude 的 token**、不直接呼叫 Anthropic 的端點，token 由 Claude Code 自己續期。輸出格式認不得時回報錯誤，不猜測。claude 的完整路徑由安裝腳本寫進 `config.json`。理由與風險見 [ADR-0006](adr/0006-claude-usage-via-cli.md)（取代 ADR-0005 的委派續期）。
- Codex：執行未修改的 Codex CLI `codex app-server --listen stdio://`（Codex 給桌面 App 與編輯器外掛用的本機 JSON-RPC 介面），只送 `initialize` 與 `account/rateLimits/read`：不開對話、不消耗額度、不使用重置次數卷（只讀張數與到期時間，FR-58），約 0.7 秒；暫存資料夾、30 秒逾時，結束時關閉 stdin，必要時結束整個 process group，不留下背景程序。**收集器不讀取 `~/.codex/auth.json`、不持有 token**、不直接呼叫 chatgpt.com，token 由 Codex CLI 自己續期。回應中的帳號 ID 等資料不保留；格式認不得時回報錯誤，不猜測。codex 的完整路徑由安裝腳本寫進 `config.json`。理由與風險見 [ADR-0007](adr/0007-codex-usage-via-app-server.md)。
- 只收集啟用的服務：`config.json` 的 `enabled_providers`（例如 `["claude"]`）由安裝腳本依 Mac 上的登入資訊偵測後寫入（`claude auth status` 回報已登入 → claude；`codex login status` 回報用 ChatGPT 登入 → codex；找不到指令且沒有設定資料夾 → 沒用過；任一服務判斷不出來時不更動設定）。未啟用的服務不查詢、不輸出、不寫日誌；已啟用但沒有登入才是錯誤（該服務的 `error`）。沒有設定檔或沒有這個欄位時全部啟用，舊安裝不受影響。
- 由 launchd 每 5 分鐘觸發：發布版由 App 以 `SMAppService` 註冊 App 內的 LaunchAgent（`--agent app`），從原始碼安裝時由 `install-launchd.sh` 註冊；內建收集器偵測到舊的 launchd 工作時不收集（ADR-0013）。
- 除了上傳中繼 API，也寫入本機 `~/Library/Application Support/AIUsageMonitor/usage.json`（先寫暫存檔再改名，避免讀到寫一半的檔案），供 Mac 選單列 App 讀取（FR-20）。

### 2.2 中繼 API (`relay/`)
- Cloudflare Worker + KV。
- `POST /usage`：需 `Authorization: Bearer <WRITE_TOKEN>`。
- `GET /usage`：需 `Authorization: Bearer <READ_TOKEN>`。
- `POST /pair`（寫入密鑰）、`POST /pair/claim`（一次性短碼換讀取密鑰）：iPhone 配對的輔助方式（[ADR-0012](adr/0012-iphone-pairing.md)）。
- 理由見 [ADR-0001](adr/0001-cloudflare-worker-relay.md)。

### 2.3 iOS App (`apple/iOSApp/`)
| 部分 | 作用 |
|---|---|
| `UsageSource`、UsageKit `RelayClient` | 呼叫 `GET /usage`，讀取密鑰存於 Keychain（App、Intent 與小工具共用） |
| `UsageActivityAttributes` | Live Activity 資料結構，App 與 Widget 共用 |
| Widget Extension | 繪製鎖定畫面／動態島卡片；主畫面與鎖定畫面小工具 `UsageHomeWidget`（FR-31、FR-32）也在這個擴充，自己呼叫中繼 |
| `RefreshUsageIntent` | 「更新」按鈕：抓資料後 `activity.update()` |
| `RestartUsageActivityIntent` | 捷徑用：抓資料、開新卡片，成功後才結束舊卡片 |
| 設定 | 中繼網址與讀取密鑰（手動貼上、掃描 Mac 上的配對 QR 碼，或輸入中繼發的短碼，[ADR-0012](adr/0012-iphone-pairing.md)）、已用／剩餘、外觀（FR-52） |

兩個 Intent 皆為 `LiveActivityIntent`，在背景執行不開 App；Live Activity 的資料透過 ActivityKit state 傳給 Widget。主畫面與鎖定畫面小工具不經過 ActivityKit：網址、顯示模式與最後一份資料放在 App Group，讀取密鑰放在 App 與擴充共用的 Keychain 項目（見 [`apple/iOSApp/README.md`](../apple/iOSApp/README.md#主畫面與鎖定畫面小工具)）。

Live Activity 以 `.supplementalActivityFamilies([.small])` 提供手錶版面，watchOS 11 以上會自動出現在 Apple Watch 智慧型堆疊（FR-27），不需要另外的手錶 App。

### 2.4 捷徑自動化
`AppShortcutsProvider` 公開「重新啟動用量監看」，於捷徑 App 建立 3 個定時自動化（間隔 ≤ 8 小時）。理由見 [ADR-0002](adr/0002-shortcut-restart-live-activity.md)。

### 2.5 共用套件 UsageKit (`apple/UsageKit/`)
Swift Package，iOS、watchOS 與 Mac App 共用（NFR-7；v1.4 起套件平台加入 watchOS）：
- `UsageSnapshot` 等資料模型與 JSON 解析（含 `schema_version` 檢查）
- 剩餘最少的額度的挑選邏輯、顏色規則與色值（FR-15、FR-16）
- 共用的 SwiftUI 元件：額度進度條、重置倒數

### 2.6 Mac 選單列 App (`apple/MacMenuBar/`，v1.2)
| 部分 | 作用 |
|---|---|
| 選單列圖示 | `MenuBarExtra` 顯示剩餘最少的額度的 % 與顏色（FR-21） |
| 面板 | `.window` 樣式，單一長版、卡片式：剩餘最少的額度、所有額度與預期進度、倒數、更新時間；區塊可開關、排序、收合（FR-22、FR-34～FR-36）；走勢與統計見 ADR-0008 的階段 |
| 動態視覺 | SwiftUI 內建動畫，只在面板或統計視窗開啟時執行、尊重「減少動態效果」（FR-25、[ADR-0010](adr/0010-mac-animation-principles.md)）；不用 Metal／SceneKit |
| 設定視窗 | 選單列圖示樣式、面板區塊的開關與排序（FR-35，[ADR-0008](adr/0008-mac-panel-layout.md)） |

- 資料來源：監看本機 `usage.json` 的變更，不經過網路，也不需要讀取密鑰。面板的「更新」按鈕另以 `launchctl kickstart` 請 launchd 提早執行收集器（60 秒內一次、24 小時最多 100 次，FR-50）；連網的仍只有收集器。
- 歷史與統計（[ADR-0009](adr/0009-local-history-and-token-stats.md)）：收集器另寫本機 `history.sqlite3`（額度歷史、這台 Mac 的每日 Token 加總），App 唯讀；不上傳。多裝置合併見 [ADR-0011](adr/0011-multi-device-usage.md)。
- 以「Sign to Run Locally」簽署，不需付費帳號，也沒有 7 天期限。
- 發布版（[ADR-0013](adr/0013-download-and-install.md)，已採用）：App 內嵌 Python 執行環境與收集器，以 `SMAppService` 註冊 App 內的 LaunchAgent 取代 `install-launchd.sh`；偵測到舊安裝時不註冊、只提示遷移。App 仍不連網、不持有密鑰。開發版（`scripts/install-mac-app.sh`）不含內建收集器，行為不變。

### 2.7 Apple Watch (`apple/WatchApp/`，v1.4)
| 部分 | 作用 |
|---|---|
| 錶面複雜功能 | WidgetKit `accessoryCircular`／`accessoryRectangular`／`accessoryInline`，顯示剩餘最少的額度的剩餘 % 與顏色（FR-28） |
| 手錶 App | 列出所有可見額度與重置倒數（FR-29） |
| 設定同步 | 手錶 App 開啟時以 WatchConnectivity 的 `sendMessage` 向 iPhone 要中繼網址與讀取密鑰（iPhone 儲存時若手錶 App 開著也會推送），手錶存入自己的 Keychain（FR-30）；不用 application context，系統不另存副本 |

- 資料來源：手錶直接呼叫中繼 `GET /usage`（透過 iPhone 或 Wi-Fi 連網），使用 UsageKit 的 `RelayClient`。
- 複雜功能的更新時機由 watchOS 決定；重置倒數依絕對時間在手錶上自行計算。

```
apple/
├── UsageKit/      # 共用 Swift Package
├── iOSApp/        # iPhone App + Live Activity Widget（含手錶版面）
├── WatchApp/      # Apple Watch App + 錶面複雜功能（v1.4）
└── MacMenuBar/    # Mac 選單列 App
```

## 3. 資料格式

```json
{
  "schema_version": 1,
  "updated_at": "2026-10-20T09:30:00Z",
  "providers": {
    "claude": {
      "plan": "Max",
      "error": null,
      "windows": [
        { "id": "five_hour",    "label": "5 小時",     "used_pct": 0,  "resets_at": "2026-10-20T10:00:00Z", "hidden": false },
        { "id": "weekly",       "label": "每週",       "used_pct": 63, "resets_at": "2026-10-26T15:00:00Z", "hidden": false },
        { "id": "weekly_fable", "label": "每週 Fable", "used_pct": 5,  "resets_at": "2026-10-26T15:00:00Z", "hidden": true }
      ]
    },
    "codex": {
      "plan": "Team",
      "error": null,
      "windows": [
        { "id": "five_hour", "label": "5 小時", "used_pct": 0,  "resets_at": "2026-10-20T14:00:00Z", "hidden": false },
        { "id": "weekly",    "label": "每週",   "used_pct": 41, "resets_at": "2026-10-27T01:00:00Z", "hidden": false }
      ],
      "reset_credits": { "available": 3, "credits": [{ "expires_at": "2026-10-22T09:30:00Z", "count": 2 }, { "expires_at": null, "count": 1 }] }
    }
  }
}
```

- `schema_version`：欄位有不相容變更時遞增，iOS 端遇到不支援的版本就提示更新 App（FR-13，v0.2 實作）。
- `resets_at` 存絕對時間（UTC ISO 8601），iOS 端用 `Text(date, style: .relative)` 自動倒數。
- `hidden`：次要額度（如各模型的每週上限），iOS／Mac 端預設不顯示（FR-14）。
- 失敗的 provider：`windows` 為空陣列、`error` 為簡短訊息。
- `reset_credits`（選填，目前只有 Codex，FR-58）：可用的重置次數卷張數與到期時間，依到期時間分組（`count` 張同時到期，沒有 `count` 時當 1 張；`null`＝不會到期），最早到期的在前、最多 16 組；明細可能比 `available` 少（後端沒給或有上限）。舊版收集器沒有這個欄位、讀不到時也不輸出；同一個 `schema_version` 新增，舊版 App 略過不認得的欄位。中繼以白名單重建快照，新增這類欄位時要先更新中繼並重新部署，否則欄位會被移除（iPhone 看不到，Mac 讀本機快照不受影響）。
- `providers` 只包含收集器啟用的服務，可能只有一個或是空物件；這不是錯誤，也不是格式變更，`schema_version` 不變。各平台照常顯示現有的服務，不為缺少的服務留空位；`providers` 為空時顯示「沒有啟用任何服務」的提示。

## 4. 失敗處理

| 情況 | 行為 |
|---|---|
| Mac 關機、睡眠或離線 | 顯示最後一筆與「更新於 N 分鐘前」，超過 30 分鐘變灰（手錶 45 分鐘，FR-11）；重置時間已過的額度標示「已重置」（FR-26） |
| 某家 API 改版或失敗 | 該欄顯示「—」，另一家照常 |
| 使用者沒有用某個服務 | 安裝腳本不啟用它，`providers` 中沒有該服務，畫面上不出現、不算錯誤 |
| Live Activity 被系統結束 | 下次捷徑排程重開 |
| 免費帳號簽署過期 | 以 Xcode 重新安裝 |
