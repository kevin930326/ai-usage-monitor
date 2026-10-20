import ActivityKit
import UsageKit

/// Live Activity 的型別，App 與 Widget 擴充共用（見 docs/02-architecture.md 2.3）。
/// 卡片沒有固定屬性，所有內容都在會更新的 `ContentState`。
struct UsageActivityAttributes: ActivityAttributes {
    typealias ContentState = UsageActivityState
}
