# UsageKit

iOS App、Live Activity 與 Mac 選單列 App 共用的 Swift Package（NFR-7）。

| Target | 內容 |
|---|---|
| `UsageKit` | 資料模型、JSON 解析與 `schema_version` 檢查、最吃緊額度、顏色規則與色值（`UsagePalette`，含對比度計算）、過期判斷、`RelayClient` |
| `UsageKitUI` | 共用 SwiftUI 元件：`UsageWindowRow`、`UsageColors`（三個平台共用的顏色） |

## 使用

```swift
import UsageKit

let client = try RelayClient(urlString: "ai-usage-relay.<帳號>.workers.dev", readToken: token)
let snapshot = try await client.fetch()

snapshot.tightestWindow(at: .now)  // 所有可見額度中剩餘最少的一項，已重置的視為 100%（FR-15、FR-26）
snapshot.isStale()             // 超過 30 分鐘沒更新（FR-11）
snapshot.isStale(after: UsageSnapshot.watchStaleAfter)   // 手錶：超過 45 分鐘
window.barTone(stale: false, at: .now)   // .provider / .critical / .stale（FR-16）
```

## 規則

| 規則 | 定義 |
|---|---|
| 進度條顏色 | 資料過期灰色；剩餘 < 20% 紅色（critical）；其他用服務識別色，20–50% 不另外上色。已重置的額度視為 100% |
| 服務識別色 | Claude 珊瑚橘（深色 `#D97757`／淺色 `#B4532F`）、Codex 青綠（深色 `#5CC2B1`／淺色 `#237A6B`）；進度條對背景 ≥ 3:1 |
| 文字顏色 | 百分比等文字一律 primary／secondary；提示文字（資料已過期、服務錯誤）共用 `notice` 色，淺色與深色都 ≥ 4.5:1 |
| 最吃緊額度 | 排除 `hidden` 與有錯誤的服務，取剩餘最少者；同分取較早重置 |
| 過期 | `updated_at` 距今超過 30 分鐘（iPhone、Mac、Live Activity）；手錶 App 與錶面複雜功能超過 45 分鐘（`watchStaleAfter`，背景更新約每 30 分鐘且常延後） |
| 服務順序 | Claude、Codex，其他依名稱排序 |

## 測試

```bash
swift test   # 需要 Xcode（Swift Testing）；只有 Command Line Tools 時可用 swift build 確認編譯

# 在 Linux 容器中執行（與 CI 相同）；掛載整個 repo，因為 FixtureTests 會讀根目錄的 fixtures/
docker run --rm -v "$PWD/../..":/repo -w /repo/apple/UsageKit swift:6.2 swift test
```

CI 在 Linux 的 `swift:6.2` 容器中執行。Linux 沒有 SwiftUI，`UsageKitUI` 以 `#if canImport(SwiftUI)` 包住，在 Linux 上會編譯成空模組；畫面元件由建置 iOS App 確認。
