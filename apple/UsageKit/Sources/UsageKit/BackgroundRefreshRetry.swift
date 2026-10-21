import Foundation

/// 手錶背景重新整理的排程重試（FR-28）。下一次背景更新只在背景工作結束時排，
/// 排程失敗又不重試的話，使用者沒再打開 App 前複雜功能都不會更新。
/// 失敗時延後重試，次數有上限，避免快速重複呼叫。
public enum BackgroundRefreshRetry {
    public static let maxAttempts = 3
    static let delays: [TimeInterval] = [60, 5 * 60, 15 * 60]

    /// 連續失敗 `failures` 次後要等多久再試；超過上限回傳 nil。
    public static func delay(afterFailures failures: Int) -> TimeInterval? {
        guard failures >= 1, failures <= maxAttempts else { return nil }
        return delays[failures - 1]
    }

    /// 呼叫 `attempt` 排程（成功回傳 true），失敗時依 `delay(afterFailures:)` 等待後重試。
    /// 在呼叫端的 actor 上執行（手錶 App 在 MainActor 呼叫 WatchKit）。
    public static func schedule(
        isolation: isolated (any Actor)? = #isolation,
        attempt: () async -> Bool,
        sleep: (TimeInterval) async -> Void
    ) async {
        var failures = 0
        while !(await attempt()) {
            failures += 1
            guard let delay = delay(afterFailures: failures) else { return }
            await sleep(delay)
        }
    }
}
