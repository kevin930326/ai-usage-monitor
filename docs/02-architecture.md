# 系統架構

## 1. 總覽

```
┌──────────── Mac ────────────┐      ┌──── Cloudflare Worker ────┐      ┌──────────── iPhone ─────────────┐
│ launchd（每 5 分鐘）         │      │ POST /usage  (寫入密鑰)    │      │ 捷徑自動化 07:00/15:00/23:00     │
│   └ collector               │─────▶│ GET  /usage  (讀取密鑰)    │◀─────│   └ RestartUsageActivityIntent  │
│      ├ Claude provider      │ 只送 │ KV 存最新一筆 usage.json   │      │                                 │
│      └ Codex provider       │ 數字 └───────────────────────────┘      │ Live Activity「更新」按鈕         │
│   OAuth token 永遠留在 Mac   │                                         │   └ RefreshUsageIntent          │
│        │ 寫入本機檔案         │                                         └─────────────────────────────────┘
│        ▼                    │
│   usage.json ──▶ 選單列 App │  （v1.2，與 iOS App 共用 UsageKit）
└─────────────────────────────┘
```

## 2. 元件

### 2.1 Mac 收集器 (`collector/`)
- Python 3，僅使用標準函式庫，降低安裝門檻。
- 每家服務一個 provider，介面一致：輸入無，輸出 `ProviderUsage` 或錯誤。
- 每次執行都重新讀取 token，**不自行刷新 token**，避免與 Claude Code / Codex CLI 互搶。
- 由 launchd 每 5 分鐘觸發。
- 除了上傳中繼 API，也寫入本機 `~/Library/Application Support/AIUsageMonitor/usage.json`（先寫暫存檔再改名，避免讀到寫一半的檔案），供 Mac 選單列 App 讀取（FR-20）。

### 2.2 中繼 API (`relay/`)
- Cloudflare Worker + KV。
- `POST /usage`：需 `Authorization: Bearer <WRITE_TOKEN>`。
- `GET /usage`：需 `Authorization: Bearer <READ_TOKEN>`。
- 理由見 [ADR-0001](adr/0001-cloudflare-worker-relay.md)。

### 2.3 iOS App (`apple/iOSApp/`)
| 部分 | 作用 |
|---|---|
| `UsageService` | 呼叫 `GET /usage`，讀取密鑰存於 Keychain |
| `UsageAttributes` | Live Activity 資料結構，App 與 Widget 共用 |
| Widget Extension | 只負責繪製鎖定畫面／動態島卡片 |
| `RefreshUsageIntent` | 「更新」按鈕：抓資料後 `activity.update()` |
| `RestartUsageActivityIntent` | 捷徑用：抓資料、開新卡片，成功後才結束舊卡片 |

兩個 Intent 皆為 `LiveActivityIntent`，在背景執行不開 App；資料透過 ActivityKit state 傳給 Widget，不需 App Group。

Live Activity 以 `.supplementalActivityFamilies([.small])` 提供手錶版面，watchOS 11 以上會自動出現在 Apple Watch 智慧型堆疊（FR-27），不需要另外的手錶 App。

### 2.4 捷徑自動化
`AppShortcutsProvider` 公開「重新啟動用量監看」，於捷徑 App 建立 3 個定時自動化（間隔 ≤ 8 小時）。理由見 [ADR-0002](adr/0002-shortcut-restart-live-activity.md)。

### 2.5 共用套件 UsageKit (`apple/UsageKit/`)
Swift Package，iOS、watchOS 與 Mac App 共用（NFR-7；v1.4 起套件平台加入 watchOS）：
- `UsageSnapshot` 等資料模型與 JSON 解析（含 `schema_version` 檢查）
- 最吃緊額度的挑選邏輯、顏色規則與色值（FR-15、FR-16）
- 共用的 SwiftUI 元件：額度進度條、重置倒數

### 2.6 Mac 選單列 App (`apple/MacMenuBar/`，v1.2)
| 部分 | 作用 |
|---|---|
| 選單列圖示 | `MenuBarExtra` 顯示最吃緊額度的 % 與顏色（FR-21） |
| 面板 | `.window` 樣式，顯示所有額度、進度條、倒數、更新時間與趨勢圖（FR-22、FR-23） |
| 桌面小工具 | WidgetKit Extension（FR-24） |
| 動態視覺 | SwiftUI 動畫／Metal shader／SceneKit，只在面板開啟時執行（FR-25） |

- 資料來源：監看本機 `usage.json` 的變更，不經過網路，也不需要讀取密鑰。
- 以「Sign to Run Locally」簽署，不需付費帳號，也沒有 7 天期限。

### 2.7 Apple Watch (`apple/WatchApp/`，v1.4)
| 部分 | 作用 |
|---|---|
| 錶面複雜功能 | WidgetKit `accessoryCircular`／`accessoryRectangular`／`accessoryInline`，顯示最吃緊額度的剩餘 % 與顏色（FR-28） |
| 手錶 App | 列出所有可見額度與重置倒數（FR-29） |
| 設定同步 | iPhone App 以 WatchConnectivity 的 application context 傳送中繼網址與讀取密鑰，手錶存入自己的 Keychain（FR-30）；系統會在兩端另存最後一份 context |

- 資料來源：手錶直接呼叫中繼 `GET /usage`（透過 iPhone 或 Wi-Fi 連網），使用 UsageKit 的 `RelayClient`。
- 複雜功能的更新時機由 watchOS 決定；重置倒數依絕對時間在手錶上自行計算。

```
apple/
├── UsageKit/      # 共用 Swift Package
├── iOSApp/        # iPhone App + Live Activity Widget（含手錶版面）
├── WatchApp/      # Apple Watch App + 錶面複雜功能（v1.4）
└── MacMenuBar/    # Mac 選單列 App + 桌面小工具
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
      ]
    }
  }
}
```

- `schema_version`：欄位有不相容變更時遞增，iOS 端遇到不支援的版本就提示更新 App（FR-13，v0.2 實作）。
- `resets_at` 存絕對時間（UTC ISO 8601），iOS 端用 `Text(date, style: .relative)` 自動倒數。
- `hidden`：次要額度（如各模型的每週上限），iOS／Mac 端預設不顯示（FR-14）。
- 失敗的 provider：`windows` 為空陣列、`error` 為簡短訊息。

## 4. 失敗處理

| 情況 | 行為 |
|---|---|
| Mac 關機、睡眠或離線 | 顯示最後一筆與「更新於 N 分鐘前」，超過 30 分鐘變灰（手錶 45 分鐘，FR-11）；重置時間已過的額度標示「已重置」（FR-26） |
| 某家 API 改版或失敗 | 該欄顯示「—」，另一家照常 |
| Live Activity 被系統結束 | 下次捷徑排程重開 |
| 免費帳號簽署過期 | 以 Xcode 重新安裝 |
