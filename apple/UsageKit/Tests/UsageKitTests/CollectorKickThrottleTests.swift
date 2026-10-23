import Foundation
import Testing
@testable import UsageKit

@Suite struct CollectorKickThrottleTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstKickIsAllowed() {
        #expect(CollectorKickThrottle().decision(at: start) == .kick)
    }

    @Test func onlyOneKickPerMinute() {
        var throttle = CollectorKickThrottle()
        throttle.record(at: start)
        #expect(throttle.decision(at: start.addingTimeInterval(1)) == .tooSoon)
        #expect(throttle.decision(at: start.addingTimeInterval(59.9)) == .tooSoon)
        #expect(throttle.decision(at: start.addingTimeInterval(60)) == .kick)
    }

    @Test func dailyLimitOverRolling24Hours() {
        var throttle = CollectorKickThrottle()
        for i in 0..<CollectorKickThrottle.dailyLimit {
            let t = start.addingTimeInterval(Double(i) * 61)
            #expect(throttle.decision(at: t) == .kick)
            throttle.record(at: t)
        }
        let next = start.addingTimeInterval(Double(CollectorKickThrottle.dailyLimit) * 61)
        #expect(throttle.decision(at: next) == .dailyLimitReached)
        // 第一次觸發滿 24 小時後空出一次
        #expect(throttle.decision(at: start.addingTimeInterval(24 * 3600)) == .kick)
    }

    @Test func keepsAtMostDailyLimitEntries() {
        var throttle = CollectorKickThrottle()
        for i in 0..<(CollectorKickThrottle.dailyLimit + 20) {
            throttle.record(at: start.addingTimeInterval(Double(i) * 61))
        }
        #expect(throttle.kicks.count == CollectorKickThrottle.dailyLimit)
        // 超過 24 小時的舊紀錄會被丟掉
        throttle.record(at: start.addingTimeInterval(10 * 86400))
        #expect(throttle.kicks.count == 1)
    }

    @Test func clockMovedBackwardsWaitsInsteadOfKicking() {
        var throttle = CollectorKickThrottle()
        throttle.record(at: start)
        #expect(throttle.decision(at: start.addingTimeInterval(-3600)) == .tooSoon)
    }

    @Test func roundTripsThroughJSON() throws {
        var throttle = CollectorKickThrottle()
        throttle.record(at: start)
        let decoded = try JSONDecoder().decode(CollectorKickThrottle.self, from: JSONEncoder().encode(throttle))
        #expect(decoded == throttle)
        #expect(decoded.decision(at: start.addingTimeInterval(30)) == .tooSoon)
    }
}
