# UsageKit

iOS App、Live Activity 與 Mac 選單列 App 共用的 Swift Package（NFR-7）。

| Target | 內容 |
|---|---|
| `UsageKit` | 資料模型、JSON 解析與 `schema_version` 檢查、最吃緊額度、顏色分級、過期判斷、`RelayClient` |
| `UsageKitUI` | 共用 SwiftUI 元件：`UsageWindowRow`、分級顏色 |

## 使用

```swift
import UsageKit

let client = try RelayClient(urlString: "ai-usage-relay.<帳號>.workers.dev", readToken: token)
let snapshot = try await client.fetch()

snapshot.tightestWindow        // 所有可見額度中剩餘最少的一項（FR-15）
snapshot.isStale()             // 超過 30 分鐘沒更新（FR-11）
window.severity                // .normal / .warning / .critical（FR-16）
```

## 規則

| 規則 | 定義 |
|---|---|
| 顏色分級 | 剩餘 > 50% 正常、20–50% 警告、< 20% 危險 |
| 最吃緊額度 | 排除 `hidden` 與有錯誤的服務，取剩餘最少者；同分取較早重置 |
| 過期 | `updated_at` 距今超過 30 分鐘 |
| 服務順序 | Claude、Codex，其他依名稱排序 |

## 測試

```bash
swift test   # 需要 Xcode（Swift Testing）；只有 Command Line Tools 時可用 swift build 確認編譯

# 在 Linux 容器中執行（與 CI 相同）
docker run --rm -v "$PWD":/pkg -w /pkg swift:6.2 swift test
```

CI 在 Linux 的 `swift:6.2` 容器中執行。Linux 沒有 SwiftUI，`UsageKitUI` 以 `#if canImport(SwiftUI)` 包住，在 Linux 上會編譯成空模組；畫面元件由建置 iOS App 確認。
