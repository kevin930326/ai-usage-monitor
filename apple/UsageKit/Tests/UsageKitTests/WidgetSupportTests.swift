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

    // MARK: 重新整理節流

    @Test func firstSnapshotAlwaysReloads() {
        var throttle = WidgetReloadThrottle()
        let reloaded = throttle.shouldReload(for: snapshot(updatedAt: now), now: now)
        #expect(reloaded)
    }

    @Test func collectorRunsWithSameNumbersDoNotReload() {
        var throttle = WidgetReloadThrottle()
        _ = throttle.shouldReload(for: snapshot(updatedAt: now), now: now)
        // 收集器每 5 分鐘寫一次、數字沒變
        for minutes in stride(from: 5.0, through: 20, by: 5) {
            let t = now.addingTimeInterval(minutes * 60)
            let reloaded = throttle.shouldReload(for: snapshot(updatedAt: t), now: t)
            #expect(!reloaded)
        }
        // 25 分鐘時強制更新一次，小工具上的資料時間才不會超過 30 分鐘而誤顯示「已過期」
        let t = now.addingTimeInterval(25 * 60)
        let reloaded = throttle.shouldReload(for: snapshot(updatedAt: t), now: t)
        #expect(reloaded)
    }

    @Test func changedNumbersWaitForMinimumInterval() {
        var throttle = WidgetReloadThrottle()
        _ = throttle.shouldReload(for: snapshot(updatedAt: now), now: now)
        let t5 = now.addingTimeInterval(5 * 60)
        let reloaded = throttle.shouldReload(for: snapshot(updatedAt: t5, used: 60), now: t5)
        #expect(!reloaded)
        // 之後的計時器檢查：內容仍與上次重新整理時不同，滿 15 分鐘就更新
        let t15 = now.addingTimeInterval(15 * 60)
        let reloadedLater = throttle.shouldReload(for: snapshot(updatedAt: t5, used: 60), now: t15)
        #expect(reloadedLater)
    }

    @Test func providerErrorCountsAsVisibleChange() {
        var throttle = WidgetReloadThrottle()
        _ = throttle.shouldReload(for: snapshot(updatedAt: now), now: now)
        let t = now.addingTimeInterval(16 * 60)
        let reloaded = throttle.shouldReload(for: snapshot(updatedAt: t, error: "token 過期"), now: t)
        #expect(reloaded)
    }

    @Test func hiddenWindowsAndUpdatedAtAreIgnored() {
        var a = snapshot(updatedAt: now)
        var b = snapshot(updatedAt: now.addingTimeInterval(300))
        a.providers["claude"]?.windows[1].usedPct = 10
        b.providers["claude"]?.windows[1].usedPct = 90
        #expect(WidgetReloadThrottle.signature(of: a) == WidgetReloadThrottle.signature(of: b))
    }

    @Test func dailyReloadsStayWithinBudget() {
        // 最壞情況：Mac 整天開著、數字每 5 分鐘都在變
        var throttle = WidgetReloadThrottle()
        var count = 0
        for i in 0..<(24 * 12) {
            let t = now.addingTimeInterval(Double(i) * 300)
            if throttle.shouldReload(for: snapshot(updatedAt: t, used: Double(i % 100)), now: t) { count += 1 }
        }
        #expect(count <= 96)
        // 數字整天不變（例如沒在用）：每 25 分鐘一次
        var idle = WidgetReloadThrottle()
        var idleCount = 0
        for i in 0..<(24 * 12) {
            let t = now.addingTimeInterval(Double(i) * 300)
            if idle.shouldReload(for: snapshot(updatedAt: t), now: t) { idleCount += 1 }
        }
        #expect(idleCount <= 58)
        print("widget reloads per day: changing every 5 min \(count), unchanged \(idleCount) (unthrottled: 288)")
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

    @Test func timelineSkipsPastAndHiddenEvents() {
        let snap = snapshot(updatedAt: now.addingTimeInterval(-3 * 3600), resetsIn: -60)
        let dates = UsageTimelineSchedule.entryDates(now: now, snapshot: snap)
        #expect(dates.count == 4)
    }
}
