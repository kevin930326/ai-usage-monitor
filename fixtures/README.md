# fixtures

三個元件共用的範例資料，確保收集器輸出、中繼存取與 App 解析的是同一個格式（`schema_version` 1）。

| 檔案 | 內容 | 使用的測試 |
|---|---|---|
| `usage-sample.json` | Claude 正常（含 `hidden` 額度、`resets_at` 為 null 的額度、30 分鐘後重置的 5 小時額度）；Codex 失敗（只有 `error`） | `collector/tests/test_fixture.py`、`relay/test/fixture.test.ts`、`apple/UsageKit/Tests/UsageKitTests/FixtureTests.swift` |
| `usage-codex-only.json` | 只啟用 Codex（沒有 `claude` 鍵）、成功但 `plan` 為 null、5 小時額度已用 112.5%（超過 100%，畫面以剩 0% 顯示）；重置卷 3 張，明細只有 2 張（一張 10/23 到期、一張不會到期） | 同上 |
| `usage-no-providers.json` | `providers` 為空（沒有啟用任何服務，畫面顯示提示而不是錯誤） | 同上 |
| `usage-forecast-incidents.json` | 選填欄位（ADR-0018）：額度的 `forecast`（有倍數與沒有倍數）、服務的 `incidents`（一筆事故與空陣列＝查過沒有事故） | 同上 |

另外 `agent-jump/cases.json` 是點工作階段跳回那個 session 的規則（ADR-0017 第 10 節）：假的程序樹（PID、父 PID、開始時間、名稱、bundle ID、tty、有沒有視窗）與 Mac／Windows 各自該找到的宿主、tmux 兩個指令的輸出與該執行的動作、tty 的格式；Swift `AgentJumpTests` 與 C# `AgentJumpTests` 比對同一份（Windows 只看 `windows`）。

另外 `incident-links.json` 是事故頁連結的規則（ADR-0015 第 2 節、ADR-0018 第 4 節）：每一項的 `url` 與應得的 `link`（不接受時 null），Swift `FixtureTests.incidentLinksMatchSharedCases` 與 C# `IncidentTests.LinksMatchSharedCases` 比對同一份。

改格式時三邊的測試會一起失敗；`schema_version` 的變更規則見 FR-13。

## logic、mascot、mascot-director、forecast、level

- `forecast/`：額度預測（ADR-0018 第 1 節），Swift、C# 與收集器的 Python 跑同一份；golden 由 Swift 產生（`AUM_UPDATE_GOLDEN=1 swift test --filter ForecastGoldenTests`）。
- `level/`：角色等級（ADR-0020 第 2、3 節），Swift 與 C# 跑同一份；golden 由 Swift 產生（`AUM_UPDATE_GOLDEN=1 swift test --filter LevelGoldenTests`）。`runs` 是連續的日子（從 `from` 起 `count` 天）。`stored` 是 `level.json` 的原始內容（ADR-0020 第 1 節），和 `days` 每天取較大值後計算；golden 的 `stored_ok` 記它讀不讀得懂（讀不懂時只用 `days`）。
- `logic/`：Mac（UsageKit）與 Windows（UsageCore）的計算一致性（ADR-0015 第 4 節）。
- `mascot/`：角色狀態機的事件串與播放紀錄（ADR-0016 第 3 節）。時間參數讀 `shared/mascot-anim.json`；golden 由 Swift 產生（`AUM_UPDATE_GOLDEN=1 swift test --filter MascotGoldenTests`），C# 的 `MascotGoldenTests` 比對同一份。
- `mascot-director/`：角色畫面（`MascotDirector`）的事件串與取樣（winmascot-release 第 1 部分，Windows 角色和 Mac 看起來、動起來一樣的依據）：每個取樣一行，依 `columns` 的順序列出眼睛、表情、眨眼、視線、面板外形、內容、特效、漣漪與 31 個姿勢參數，數字取 6 位小數、兩邊容許 1e-6。golden 由 Swift 產生（`AUM_UPDATE_GOLDEN=1 swift test --filter MascotDirectorGoldenTests`），C# 的 `MascotDirectorGoldenTests` 比對同一份。
