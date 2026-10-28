# fixtures

三個元件共用的範例資料，確保收集器輸出、中繼存取與 App 解析的是同一個格式（`schema_version` 1）。

| 檔案 | 內容 | 使用的測試 |
|---|---|---|
| `usage-sample.json` | Claude 正常（含 `hidden` 額度、`resets_at` 為 null 的額度、30 分鐘後重置的 5 小時額度）；Codex 失敗（只有 `error`） | `collector/tests/test_fixture.py`、`relay/test/fixture.test.ts`、`apple/UsageKit/Tests/UsageKitTests/FixtureTests.swift` |
| `usage-codex-only.json` | 只啟用 Codex（沒有 `claude` 鍵）、成功但 `plan` 為 null、5 小時額度已用 112.5%（超過 100%，畫面以剩 0% 顯示）；重置卷 3 張，明細只有 2 張（一張 10/23 到期、一張不會到期） | 同上 |
| `usage-no-providers.json` | `providers` 為空（沒有啟用任何服務，畫面顯示提示而不是錯誤） | 同上 |

改格式時三邊的測試會一起失敗；`schema_version` 的變更規則見 FR-13。

## logic、mascot

- `logic/`：Mac（UsageKit）與 Windows（UsageCore）的計算一致性（ADR-0015 第 4 節）。
- `mascot/`：角色狀態機的事件串與播放紀錄（ADR-0016 第 3 節）。時間參數讀 `shared/mascot-anim.json`；golden 由 Swift 產生（`AUM_UPDATE_GOLDEN=1 swift test --filter MascotGoldenTests`），C# 的 `MascotGoldenTests` 比對同一份。
