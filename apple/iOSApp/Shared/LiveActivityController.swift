import ActivityKit
import Foundation
import UsageKit

/// 開始、更新、結束 Live Activity。App 畫面與 Intent（在 App 程序中執行）共用。
@MainActor
enum LiveActivityController {
    typealias UsageActivity = Activity<UsageActivityAttributes>

    static var activities: [UsageActivity] { UsageActivity.activities }
    static var isRunning: Bool { !activities.isEmpty }

    nonisolated static func content(for snapshot: UsageSnapshot, mode: UsageDisplayMode) -> ActivityContent<UsageActivityState> {
        let state = UsageActivityState(snapshot: snapshot, mode: mode)
        // staleDate 讓系統在資料過期或額度重置時重繪卡片（FR-11、FR-26）
        return ActivityContent(state: state, staleDate: state.staleDate())
    }

    /// 開一張新卡片；已有卡片時先全部結束，保持只有一張。
    @discardableResult
    static func start(snapshot: UsageSnapshot, mode: UsageDisplayMode, demoScenario: String? = nil) async throws -> UsageActivity {
        await endAll()
        let activity = try UsageActivity.request(
            attributes: UsageActivityAttributes(demoScenario: demoScenario),
            content: content(for: snapshot, mode: mode),
            pushType: nil
        )
        ActivityLog.record("start", activity: activity, updatedAt: snapshot.updatedAt)
        return activity
    }

    // Activity 不是 Sendable，更新與結束都在非隔離的情境逐一處理，避免跨 actor 傳遞
    nonisolated static func update(snapshot: UsageSnapshot, mode: UsageDisplayMode) async {
        for activity in UsageActivity.activities {
            await activity.update(content(for: snapshot, mode: mode))
            ActivityLog.record("update", activity: activity, updatedAt: snapshot.updatedAt)
        }
    }

    nonisolated static func endAll() async {
        for activity in UsageActivity.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            ActivityLog.record("end", activity: activity, updatedAt: nil)
        }
    }

    /// 卡片上的「更新」按鈕（FR-9）：重新抓資料後更新所有卡片。
    static func refresh() async throws {
        guard let activity = activities.first else { return }
        let snapshot = try await UsageSource.fetch(demoScenario: activity.attributes.demoScenario)
        await update(snapshot: snapshot, mode: activity.content.state.mode)
    }
}

/// DEBUG：把 Live Activity 的事件寫到 App 容器的 Documents/activity-log.json，
/// 供 `xcrun simctl get_app_container` 讀出驗證（卡片 ID、狀態、資料時間）。
enum ActivityLog {
    static func record(_ event: String, activity: Activity<UsageActivityAttributes>, updatedAt: Date?) {
        #if DEBUG
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "activity-log.json")
        var entries = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        entries.append([
            "event": event,
            "id": activity.id,
            "state": "\(activity.activityState)",
            "updatedAt": updatedAt.map(iso.string) ?? NSNull(),
            "activeCount": Activity<UsageActivityAttributes>.activities.filter { $0.activityState == .active }.count,
            "at": iso.string(from: .now),
        ])
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        #endif
    }
}
