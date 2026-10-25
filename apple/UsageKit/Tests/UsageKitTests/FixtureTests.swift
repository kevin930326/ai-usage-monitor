import Foundation
import Testing
@testable import UsageKit

/// 讀 repo 根目錄的 fixtures/usage-sample.json；收集器與中繼的測試讀同一份（fixtures/README.md）。
@Suite struct FixtureTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // UsageKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // UsageKit
        .deletingLastPathComponent()   // apple
        .deletingLastPathComponent()   // repo 根目錄
        .appendingPathComponent("fixtures")
    static let url = folder.appendingPathComponent("usage-sample.json")

    static func load(_ name: String) throws -> UsageSnapshot {
        try UsageDecoder.decode(Data(contentsOf: folder.appendingPathComponent(name)))
    }

    let snapshot: UsageSnapshot
    let updatedAt = Date(timeIntervalSince1970: 1_792_551_600) // 2026-10-21T03:00:00Z

    init() throws {
        snapshot = try UsageDecoder.decode(Data(contentsOf: Self.url))
    }

    @Test func decodesEveryField() throws {
        #expect(snapshot.updatedAt == updatedAt)
        let claude = try #require(snapshot.providers["claude"])
        #expect(claude.plan == "Max")
        #expect(claude.error == nil)
        #expect(claude.windows.map(\.id) == ["five_hour", "weekly", "weekly_opus", "weekly_fable"])
        #expect(claude.visibleWindows.map(\.id) == ["five_hour", "weekly"])
        #expect(claude.windows[0].usedPct == 62.5)
        #expect(claude.windows[3].resetsAt == nil)

        let codex = try #require(snapshot.providers["codex"])
        #expect(codex.plan == nil)
        #expect(codex.error == "token 過期，請在 Mac 重新登入 Codex")
        #expect(codex.windows.isEmpty)
    }

    @Test func hiddenWindowsAndFailedServicesAreIgnoredForTightest() {
        // weekly_opus 已用 97% 但隱藏；Codex 失敗
        let tightest = snapshot.tightestWindow(at: updatedAt)
        #expect(tightest?.provider == "claude")
        #expect(tightest?.window.id == "five_hour")
    }

    @Test func resetWindowIsNoLongerTightest() {
        // 03:30Z 重置後 5 小時額度視為 100%，剩餘最少的額度換成每週
        let afterReset = updatedAt.addingTimeInterval(31 * 60)
        #expect(snapshot.tightestWindow(at: afterReset)?.window.id == "weekly")
    }

    @Test func liveActivityStateKeepsThePartialFailure() throws {
        let state = UsageActivityState(snapshot: snapshot, mode: .remaining)
        #expect(state.hasPartialFailure)
        #expect(state.providers.map(\.key) == ["claude", "codex"])
        #expect(try state.encodedSize() < UsageActivityState.maxEncodedBytes)
    }

    @Test func encoderRoundTrips() throws {
        let again = try UsageDecoder.decode(UsageEncoder.encode(snapshot))
        #expect(again == snapshot)
    }

    // MARK: - 整合審查 D-i：只有 Codex（plan null、超過 100%）、沒有任何服務

    @Test func codexOnlyOverHundredPercent() throws {
        let codexOnly = try Self.load("usage-codex-only.json")
        #expect(codexOnly.orderedProviderKeys == ["codex"])
        #expect(!codexOnly.hasNoProviders)
        let codex = try #require(codexOnly.providers["codex"])
        #expect(codex.plan == nil)
        #expect(codex.error == nil)
        #expect(codex.windows[0].usedPct == 112.5)
        // 超過 100% 以剩 0% 顯示，且是剩餘最少的額度
        let tightest = try #require(codexOnly.tightestWindow(at: updatedAt))
        #expect(tightest.provider == "codex")
        #expect(tightest.window.id == "five_hour")
        #expect(tightest.window.effectiveRemainingPct(at: updatedAt) == 0)
        let state = UsageActivityState(snapshot: codexOnly, mode: .remaining)
        #expect(!state.hasPartialFailure)
        // 重置卷 3 張，明細 2 張（一張 10/23 03:00Z 到期、一張不會到期）
        let credits = try #require(codex.resetCredits)
        #expect(credits.available == 3)
        #expect(credits.credits.map(\.expiresAt) == [Date(timeIntervalSince1970: 1_792_724_400), nil])
        #expect(try UsageDecoder.decode(UsageEncoder.encode(codexOnly)) == codexOnly)
    }

    @Test func noProvidersIsNotAnError() throws {
        let empty = try Self.load("usage-no-providers.json")
        #expect(empty.hasNoProviders)
        #expect(empty.orderedProviderKeys.isEmpty)
        #expect(empty.tightestWindow(at: updatedAt) == nil)
        let state = UsageActivityState(snapshot: empty, mode: .remaining)
        #expect(!state.hasPartialFailure)
        #expect(state.providers.isEmpty)
        #expect(try UsageDecoder.decode(UsageEncoder.encode(empty)) == empty)
    }
}
