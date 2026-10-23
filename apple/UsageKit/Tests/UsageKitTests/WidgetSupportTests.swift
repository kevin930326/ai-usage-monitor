import Foundation
import Testing
@testable import UsageKit

@Suite struct WidgetSupportTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(updatedAt: Date, used: Double = 40, resetsIn: TimeInterval = 3 * 3600, error: String? = nil) -> UsageSnapshot {
        UsageSnapshot(updatedAt: updatedAt, providers: [
            "claude": ProviderUsage(plan: "Max", windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: used, resetsAt: now.addingTimeInterval(resetsIn)),
                UsageWindow(id: "weekly_opus", label: "每週 Opus", usedPct: 99, resetsAt: nil, hidden: true),
            ]),
            "codex": ProviderUsage(error: error),
        ])
    }

    // MARK: 共用檔案的編碼

    @Test func encoderRoundTripsThroughDecoder() throws {
        let original = snapshot(updatedAt: now)
        let decoded = try UsageDecoder.decode(UsageEncoder.encode(original))
        #expect(decoded == original)
        #expect(decoded.providers["claude"]?.windows[1].hidden == true)
        #expect(decoded.providers["claude"]?.windows[1].resetsAt == nil)
        #expect(decoded.providers["codex"]?.windows.isEmpty == true)
    }

    // MARK: 時間軸

    @Test func timelineHasQuarterHourEntries() {
        let dates = UsageTimelineSchedule.entryDates(now: now, snapshot: nil)
        #expect(dates == [0, 15, 30, 45].map { now.addingTimeInterval($0 * 60) })
    }

    @Test func timelineAddsResetAndStaleMoments() {
        // 7 分鐘後重置、資料 10 分鐘前更新 → 20 分鐘後過期
        let snap = snapshot(updatedAt: now.addingTimeInterval(-10 * 60), resetsIn: 7 * 60)
        let dates = UsageTimelineSchedule.entryDates(now: now, snapshot: snap)
        #expect(dates.contains(now.addingTimeInterval(7 * 60)))
        #expect(dates.contains(now.addingTimeInterval(20 * 60)))
        #expect(dates == dates.sorted())
        #expect(dates.first == now)
        #expect(dates.allSatisfy { $0 < now.addingTimeInterval(3600) })
    }

    @Test func timelineUsesWatchStaleThreshold() {
        // 複雜功能：資料 10 分鐘前更新 → 35 分鐘後（45 分鐘門檻）才加過期的時間點
        let snap = snapshot(updatedAt: now.addingTimeInterval(-10 * 60))
        let dates = UsageTimelineSchedule.entryDates(now: now, snapshot: snap, staleAfter: UsageSnapshot.watchStaleAfter)
        #expect(dates.contains(now.addingTimeInterval(35 * 60)))
        #expect(!dates.contains(now.addingTimeInterval(20 * 60)))
    }

    @Test func timelineSkipsPastAndHiddenEvents() {
        let snap = snapshot(updatedAt: now.addingTimeInterval(-3 * 3600), resetsIn: -60)
        let dates = UsageTimelineSchedule.entryDates(now: now, snapshot: snap)
        #expect(dates.count == 4)
    }
}
