# fixtures

三個元件共用的範例資料，確保收集器輸出、中繼存取與 App 解析的是同一個格式（`schema_version` 1）。

| 檔案 | 內容 | 使用的測試 |
|---|---|---|
| `usage-sample.json` | Claude 正常（含 `hidden` 額度、`resets_at` 為 null 的額度、30 分鐘後重置的 5 小時額度）；Codex 失敗（只有 `error`） | `collector/tests/test_fixture.py`、`relay/test/fixture.test.ts`、`apple/UsageKit/Tests/UsageKitTests/FixtureTests.swift` |

改格式時三邊的測試會一起失敗；`schema_version` 的變更規則見 FR-13。
