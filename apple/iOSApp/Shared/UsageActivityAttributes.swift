import ActivityKit
import UsageKit

/// Live Activity 的型別，App 與 Widget 擴充共用（見 docs/02-architecture.md 2.3）。
/// 所有用量內容都在會更新的 `ContentState`。
struct UsageActivityAttributes: ActivityAttributes {
    typealias ContentState = UsageActivityState

    /// DEBUG 示範模式的情境名稱。卡片上的按鈕觸發 Intent 時，系統在 App 程序中執行，
    /// 不會帶啟動時的環境變數，所以情境要跟著卡片保存；正式使用時永遠是 nil。
    var demoScenario: String?
}
