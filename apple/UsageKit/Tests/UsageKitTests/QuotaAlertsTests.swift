import Foundation
import Testing
@testable import UsageKit

@Suite struct QuotaAlertsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(used: Double, resetsIn: TimeInterval?, id: String = "five_hour", updatedAgo: TimeInterval = 60,
                  error: String? = nil) -> UsageSnapshot {
        UsageSnapshot(updatedAt: now.addingTimeInterval(-updatedAgo), providers: [
            "claude": ProviderUsage(plan: "Max", error: error, windows: [
                UsageWindow(id: id, label: "5 小時", usedPct: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) }),
            ]),
        ])
    }

    @Test func lowFiresOncePerCycle() {
        let s = snapshot(used: 85, resetsIn: 3600)
        let alerts = QuotaAlerts.detect(snapshot: s, now: now, sent: [])
        let low = alerts.first { $0.kind == .low }
        #expect(low?.title == "Claude 5 小時 剩不到 20%")
        #expect(low?.body.hasPrefix("剩 15%") == true)
        #expect(low?.cardID == "quota")
        let sent = Set(alerts.map(\.key))
        #expect(QuotaAlerts.detect(snapshot: s, now: now.addingTimeInterval(300), sent: sent).filter { $0.kind == .low }.isEmpty)
        // 下一輪又剩不到 20%：再通知一次
        let next = snapshot(used: 90, resetsIn: 3600 + 5 * 3600)
        #expect(QuotaAlerts.detect(snapshot: next, now: now, sent: sent).contains { $0.kind == .low })
    }

    @Test func tooFastNeedsEnoughElapsed() {
        // 5 小時額度過了 2 小時（40%）已用 70%：照速度約 51 分鐘後用完，早於 3 小時後的重置
        let fast = QuotaAlerts.detect(snapshot: snapshot(used: 70, resetsIn: 3 * 3600), now: now, sent: [])
        #expect(fast.contains { $0.kind == .tooFast && $0.title == "Claude 5 小時 用得太快" })
        #expect(!fast.contains { $0.kind == .low })
        // 才開始 5%：不判斷
        #expect(QuotaAlerts.detect(snapshot: snapshot(used: 30, resetsIn: 4.75 * 3600), now: now, sent: []).isEmpty)
    }

    @Test func resetOnlyAfterALowCycle() {
        let cycle = Int64(now.addingTimeInterval(-60).timeIntervalSince1970)
        let lowKey = "low|claude|five_hour|\(cycle)"
        // 上一輪剩不到 20%，重置時間已過、新的一輪剛開始
        let fresh = snapshot(used: 1, resetsIn: 5 * 3600 - 60)
        let alerts = QuotaAlerts.detect(snapshot: fresh, now: now, sent: [lowKey])
        #expect(alerts.map(\.kind) == [.reset])
        #expect(alerts.first?.title == "Claude 5 小時 已重置")
        #expect(alerts.first?.cardID == "resets")
        // 已通知過：不再送
        #expect(QuotaAlerts.detect(snapshot: fresh, now: now, sent: [lowKey, alerts[0].key]).isEmpty)
        // 收集器還沒拿到新的重置時間（舊快照、重置時間已過）也算
        let stalePct = snapshot(used: 95, resetsIn: -60)
        #expect(QuotaAlerts.detect(snapshot: stalePct, now: now, sent: [lowKey]).map(\.kind) == [.reset])
        // 沒有剩不到 20% 的紀錄：重置不通知
        #expect(QuotaAlerts.detect(snapshot: fresh, now: now, sent: []).isEmpty)
    }

    @Test func staleOrErrorDoesNothing() {
        #expect(QuotaAlerts.detect(snapshot: snapshot(used: 95, resetsIn: 3600, updatedAgo: 3600), now: now, sent: []).isEmpty)
        #expect(QuotaAlerts.detect(snapshot: snapshot(used: 95, resetsIn: 3600, error: "x"), now: now, sent: []).isEmpty)
    }

    @Test func pruneDropsOldCycles() {
        let old = "low|claude|weekly|\(Int64(now.addingTimeInterval(-9 * 86400).timeIntervalSince1970))"
        let recent = "low|claude|weekly|\(Int64(now.addingTimeInterval(-86400).timeIntervalSince1970))"
        #expect(QuotaAlerts.pruned([old, recent, "low|claude|x|0", "garbage"], now: now) == [recent, "low|claude|x|0"])
    }
}
