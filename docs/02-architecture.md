# 系統架構

## 1. 總覽

```
┌──────────── Mac ────────────┐      ┌──── Cloudflare Worker ────┐      ┌──────────── iPhone ─────────────┐
│ launchd（每 5 分鐘）         │      │ POST /usage  (寫入密鑰)    │      │ 捷徑自動化 07:00/15:00/23:00     │
│   └ collector               │─────▶│ GET  /usage  (讀取密鑰)    │◀─────│   └ RestartUsageActivityIntent  │
│      ├ Claude provider      │ 只送 │ KV 存最新一筆 usage.json   │      │                                 │
│      └ Codex provider       │ 數字 └───────────────────────────┘      │ Live Activity「更新」按鈕         │
│   OAuth token 永遠留在 Mac   │                                         │   └ RefreshUsageIntent          │
└─────────────────────────────┘                                         └─────────────────────────────────┘
```

## 2. 元件

### 2.1 Mac 收集器 (`collector/`)
- Python 3，僅使用標準函式庫，降低安裝門檻。
- 每家服務一個 provider，介面一致：輸入無，輸出 `ProviderUsage` 或錯誤。
- 每次執行都重新讀取 token，**不自行刷新 token**，避免與 Claude Code / Codex CLI 互搶。
- 由 launchd 每 5 分鐘觸發。

### 2.2 中繼 API (`relay/`)
- Cloudflare Worker + KV。
- `POST /usage`：需 `Authorization: Bearer <WRITE_TOKEN>`。
- `GET /usage`：需 `Authorization: Bearer <READ_TOKEN>`。
- 理由見 [ADR-0001](adr/0001-cloudflare-worker-relay.md)。

### 2.3 iOS App (`ios/`)
| 部分 | 作用 |
|---|---|
| `UsageService` | 呼叫 `GET /usage`，讀取密鑰存於 Keychain |
| `UsageAttributes` | Live Activity 資料結構，App 與 Widget 共用 |
| Widget Extension | 只負責繪製鎖定畫面／動態島卡片 |
| `RefreshUsageIntent` | 「更新」按鈕：抓資料後 `activity.update()` |
| `RestartUsageActivityIntent` | 捷徑用：結束舊卡片、開新卡片 |

兩個 Intent 皆為 `LiveActivityIntent`，在背景執行不開 App；資料透過 ActivityKit state 傳給 Widget，不需 App Group。

### 2.4 捷徑自動化
`AppShortcutsProvider` 公開「重新啟動用量監看」，於捷徑 App 建立 3 個定時自動化（間隔 ≤ 8 小時）。理由見 [ADR-0002](adr/0002-shortcut-restart-live-activity.md)。

## 3. 資料格式

```json
{
  "updated_at": "2026-10-20T09:30:00Z",
  "providers": {
    "claude": {
      "plan": "Team",
      "error": null,
      "windows": [
        { "id": "five_hour", "label": "5 小時", "used_pct": 0,  "resets_at": "2026-10-20T10:00:00Z" },
        { "id": "weekly",    "label": "每週",   "used_pct": 63, "resets_at": "2026-10-26T15:00:00Z" }
      ]
    },
    "codex": {
      "plan": "Pro Lite",
      "error": null,
      "windows": [
        { "id": "weekly", "label": "每週", "used_pct": 41, "resets_at": "2026-10-27T01:00:00Z" }
      ]
    }
  }
}
```

- `resets_at` 存絕對時間（UTC ISO 8601），iOS 端用 `Text(date, style: .relative)` 自動倒數。
- 失敗的 provider：`windows` 為空陣列、`error` 為簡短訊息。

## 4. 失敗處理

| 情況 | 行為 |
|---|---|
| Mac 關機或離線 | 顯示最後一筆與「更新於 N 分鐘前」，超過 30 分鐘變灰 |
| 某家 API 改版或失敗 | 該欄顯示「—」，另一家照常 |
| Live Activity 被系統結束 | 下次捷徑排程重開 |
| 免費帳號簽署過期 | 以 Xcode 重新安裝 |
