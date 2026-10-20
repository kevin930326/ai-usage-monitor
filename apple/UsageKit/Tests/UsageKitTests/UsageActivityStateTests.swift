import Foundation
import Testing
@testable import UsageKit

@Suite struct UsageActivityStateTests {
    let snap = try! UsageDecoder.decode(Data(sampleJSON.utf8))
    var updated: Date { snap.updatedAt }

    @Test func keepsProviderOrderAndOnlyVisibleWindows() {
        let state = UsageActivityState(snapshot: snap, mode: .remaining)
        #expect(state.providers.map(\.key) == ["claude", "codex"])
        #expect(state.providers[0].windows.map(\.id) == ["five_hour", "weekly"])
        #expect(state.providers[0].displayName == "Claude")
        #expect(state.mode == .remaining)
        #expect(state.updatedAt == updated)
    }

    @Test func roundTripsThroughSnapshot() {
        let state = UsageActivityState(snapshot: snap, mode: .used)
        #expect(state.snapshot.providers["codex"]?.plan == "Team")
        #expect(state.snapshot.providers["claude"]?.windows.count == 2)
    }

    @Test func tightestMatchesSnapshot() {
        let state = UsageActivityState(snapshot: snap, mode: .remaining)
        let t = state.tightest(at: updated)
        #expect(t?.provider == "claude")
        #expect(t?.window.id == "five_hour")
    }

    @Test func staleAfterThirtyMinutes() {
        let state = UsageActivityState(snapshot: snap, mode: .remaining)
        #expect(!state.isStale(at: updated.addingTimeInterval(29 * 60)))
        #expect(state.isStale(at: updated.addingTimeInterval(31 * 60)))
    }

    @Test func staleDateIsExpiryWhenNoResetIsSooner() {
        let state = UsageActivityState(snapshot: snap, mode: .remaining)
        // sample 最早的重置在 19:00，晚於 16:36 + 30 分
        #expect(state.staleDate(now: updated) == updated.addingTimeInterval(30 * 60))
    }

    @Test func staleDateIsNextResetWhenSooner() {
        var s = snap
        let soon = updated.addingTimeInterval(10 * 60)
        s.providers["codex"]?.windows[0].resetsAt = soon
        let state = UsageActivityState(snapshot: s, mode: .remaining)
        #expect(state.staleDate(now: updated) == soon)
    }

    @Test func staleDateIgnoresPastResets() {
        var s = snap
        s.providers["codex"]?.windows[0].resetsAt = updated.addingTimeInterval(-60)
        let state = UsageActivityState(snapshot: s, mode: .remaining)
        #expect(state.staleDate(now: updated) == updated.addingTimeInterval(30 * 60))
    }

    @Test func staleDateSkipsPassedExpiry() {
        // 45 分鐘前的資料：過期時間已過，改用下一個重置時間（sample 最早 19:00）
        let now = updated.addingTimeInterval(45 * 60)
        let state = UsageActivityState(snapshot: snap, mode: .remaining)
        let next = state.staleDate(now: now)
        #expect(next != nil)
        #expect(next! > now)
    }

    @Test func staleDateIsNilWhenEverythingPassed() {
        let state = UsageActivityState(snapshot: snap, mode: .remaining)
        #expect(state.staleDate(now: updated.addingTimeInterval(30 * 24 * 3600)) == nil)
    }

    @Test func partialFailureKeepsHealthyProvider() {
        var s = snap
        s.providers["codex"] = ProviderUsage(error: "token 過期，請在 Mac 上重新登入 Codex", windows: [])
        let state = UsageActivityState(snapshot: s, mode: .remaining)
        #expect(state.hasPartialFailure)
        #expect(state.providers[1].error != nil)
        #expect(state.tightest(at: updated)?.provider == "claude")
    }

    @Test func noPartialFailureWhenAllHealthy() {
        #expect(!UsageActivityState(snapshot: snap, mode: .used).hasPartialFailure)
    }

    @Test func longErrorsAreTruncated() {
        var s = snap
        s.providers["codex"] = ProviderUsage(error: String(repeating: "錯", count: 500))
        let state = UsageActivityState(snapshot: s, mode: .used)
        #expect(state.providers[1].error?.count == UsageActivityState.maxErrorLength)
    }

    @Test func encodedStateFitsActivityKitLimit() throws {
        // 最壞情況：多個服務、每個都有多個額度與最長錯誤訊息
        var providers: [String: ProviderUsage] = [:]
        for name in ["claude", "codex", "gemini", "cursor"] {
            providers[name] = ProviderUsage(
                plan: "Enterprise Plus",
                error: String(repeating: "錯誤", count: 100),
                windows: (0..<4).map { UsageWindow(id: "window_\($0)", label: "每週 Opus \($0)", usedPct: 99.9, resetsAt: .now) }
            )
        }
        let state = UsageActivityState(snapshot: UsageSnapshot(updatedAt: .now, providers: providers), mode: .remaining)
        #expect(try state.encodedSize() < UsageActivityState.maxEncodedBytes)
    }

    @Test func codableRoundTrip() throws {
        let state = UsageActivityState(snapshot: snap, mode: .used)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(UsageActivityState.self, from: data) == state)
    }
}
