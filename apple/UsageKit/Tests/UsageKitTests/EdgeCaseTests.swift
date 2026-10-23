import Foundation
import Testing
@testable import UsageKit

/// 審查補充的邊界情況：卡片替換順序、過期判斷、時間邊界、空資料。
@Suite struct EdgeCaseTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(updatedAt: Date, _ providers: [String: ProviderUsage]) -> UsageSnapshot {
        UsageSnapshot(updatedAt: updatedAt, providers: providers)
    }

    // MARK: 卡片替換順序（FR-8、FR-10）

    struct StartFailed: Error {}

    @Test func replacementKeepsOldCardsWhenStartFails() async {
        var ended: [String] = []
        await #expect(throws: StartFailed.self) {
            try await ActivityReplacement.replace(start: { () async throws -> String in throw StartFailed() },
                                                  endOthers: { ended.append($0) })
        }
        #expect(ended.isEmpty)
    }

    @Test func replacementEndsOthersAfterNewCardStarts() async throws {
        var events: [String] = []
        let card = try await ActivityReplacement.replace {
            events.append("start")
            return "new"
        } endOthers: { keep in
            events.append("end-except-\(keep)")
        }
        #expect(card == "new")
        #expect(events == ["start", "end-except-new"])
    }

    // MARK: 過期判斷（FR-11）

    @Test func redrawAtExpiryShowsBothResetAndStale() throws {
        // C-01：10 分鐘後重置、30 分鐘後過期。卡片只會在 staleDate 重繪一次，
        // 這一次必須落在過期時間，畫面才會轉灰；重置在同一次重繪中一併顯示
        let resetsAt = now.addingTimeInterval(10 * 60)
        let state = UsageActivityState(snapshot: snapshot(updatedAt: now, [
            "claude": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 80, resetsAt: resetsAt)]),
        ]), mode: .remaining)
        let staleDate = try #require(state.staleDate(now: now))
        #expect(staleDate == now.addingTimeInterval(UsageSnapshot.staleAfter))
        #expect(state.isStale(at: staleDate.addingTimeInterval(0.001)))
        let tightest = try #require(state.tightest(at: staleDate))
        #expect(tightest.window.isReset(at: staleDate))
        #expect(tightest.window.displayedPct(.remaining, at: staleDate) == 100)
    }

    @Test func staleDateFallsBackToNextResetOnceExpired() {
        // 過期後才更新卡片（例如按「更新」但中繼仍是舊資料）：下一次重繪留給重置
        let resetsAt = now.addingTimeInterval(2 * 3600)
        let state = UsageActivityState(snapshot: snapshot(updatedAt: now, [
            "claude": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 80, resetsAt: resetsAt)]),
        ]), mode: .remaining)
        #expect(state.staleDate(now: now.addingTimeInterval(45 * 60)) == resetsAt)
    }

    @Test func updatedAtLaterThanDeviceClockIsNotStale() {
        // 裝置時間比 Mac 慢 10 分鐘：資料時間在「未來」
        let future = now.addingTimeInterval(10 * 60)
        let snap = snapshot(updatedAt: future, ["claude": ProviderUsage(windows: [])])
        #expect(!snap.isStale(now: now))
        let state = UsageActivityState(snapshot: snap, mode: .remaining)
        #expect(state.staleDate(now: now) == future.addingTimeInterval(UsageSnapshot.staleAfter))
    }

    @Test func updatedAtFarInTheFutureIsStale() {
        // C-09：Mac 時鐘快了好幾個小時，舊資料不能一直顯示成新的。
        // 超過門檻的未來時間視為過期；門檻內的小偏差（上一個測試）照常顯示
        for hours: Double in [1, 24, 24 * 30] {
            let snap = snapshot(updatedAt: now.addingTimeInterval(hours * 3600), ["claude": ProviderUsage(windows: [])])
            #expect(snap.isStale(now: now))
            #expect(snap.isStale(now: now, after: UsageSnapshot.watchStaleAfter))
            #expect(UsageActivityState(snapshot: snap, mode: .remaining).isStale(at: now))
        }
    }

    @Test func futureToleranceMatchesThreshold() {
        let snap = snapshot(updatedAt: now.addingTimeInterval(40 * 60), ["claude": ProviderUsage(windows: [])])
        #expect(snap.isStale(now: now))                                          // iPhone、Mac：30 分鐘
        #expect(!snap.isStale(now: now, after: UsageSnapshot.watchStaleAfter))   // 手錶：45 分鐘
    }

    // MARK: 時間邊界（FR-26）

    @Test func resetFlipsExactlyAtResetTime() {
        let w = UsageWindow(id: "five_hour", label: "5 小時", usedPct: 90, resetsAt: now)
        #expect(!w.isReset(at: now.addingTimeInterval(-0.001)))
        #expect(w.effectiveRemainingPct(at: now.addingTimeInterval(-0.001)) == 10)
        #expect(w.isReset(at: now))
        #expect(w.effectiveRemainingPct(at: now) == 100)
    }

    @Test func justPassedResetIsNotUsedAsStaleDate() {
        let state = UsageActivityState(snapshot: snapshot(updatedAt: now.addingTimeInterval(-60), [
            "claude": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 90, resetsAt: now)]),
        ]), mode: .remaining)
        // 重置時間剛好等於現在：不能交給 ActivityKit（過去的 staleDate 會讓卡片從鎖定畫面消失）
        #expect(state.staleDate(now: now)! > now)
    }

    @Test func timeZoneOffsetsDecodeToTheSameInstant() throws {
        // 收集器輸出 UTC（Z），但其他時區的偏移量也必須得到相同的時間點與重置判斷
        func decode(_ resetsAt: String) throws -> UsageWindow {
            let json = """
            {"schema_version":1,"updated_at":"2026-10-21T03:00:00Z","providers":{"claude":{"plan":null,"error":null,
             "windows":[{"id":"five_hour","label":"5 小時","used_pct":50,"resets_at":"\(resetsAt)"}]}}}
            """
            return try #require(try UsageDecoder.decode(Data(json.utf8)).providers["claude"]?.windows.first)
        }
        let utc = try decode("2026-10-21T04:00:00Z")
        let taipei = try decode("2026-10-21T12:00:00+08:00")
        let newYork = try decode("2026-10-21T00:00:00-04:00")
        #expect(utc.resetsAt == taipei.resetsAt)
        #expect(utc.resetsAt == newYork.resetsAt)
        let justAfter = utc.resetsAt!.addingTimeInterval(1)
        #expect([utc, taipei, newYork].allSatisfy { $0.isReset(at: justAfter) })
    }

    // MARK: 剩餘最少的額度（FR-15）

    @Test func tiedResetWindowsPickEarlierReset() {
        let snap = snapshot(updatedAt: now, [
            "claude": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 90, resetsAt: now.addingTimeInterval(-120))]),
            "codex": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 70, resetsAt: now.addingTimeInterval(-60))]),
        ])
        // 兩個都已重置（100%）：同分時取較早重置的
        let t = snap.tightestWindow(at: now)
        #expect(t?.provider == "claude")
        #expect(t?.window.effectiveRemainingPct(at: now) == 100)
    }

    @Test func noVisibleWindowsMeansNoTightest() throws {
        let snap = snapshot(updatedAt: now, [
            "claude": ProviderUsage(windows: [UsageWindow(id: "weekly_opus", label: "每週 Opus", usedPct: 99, hidden: true)]),
            "codex": ProviderUsage(error: "token 過期"),
        ])
        let state = UsageActivityState(snapshot: snap, mode: .remaining)
        #expect(state.tightest(at: now) == nil)
        #expect(state.staleDate(now: now) == now.addingTimeInterval(UsageSnapshot.staleAfter))
        #expect(try state.encodedSize() < UsageActivityState.maxEncodedBytes)
    }

    @Test func emptySnapshotIsHandled() {
        let state = UsageActivityState(snapshot: snapshot(updatedAt: now, [:]), mode: .used)
        #expect(state.providers.isEmpty)
        #expect(state.tightest(at: now) == nil)
        #expect(!state.hasPartialFailure)
    }

    // MARK: 服務標示

    @Test func shortNamesTellProvidersApart() {
        #expect(ProviderInfo.shortName("claude") == "CL")
        #expect(ProviderInfo.shortName("codex") == "CX")
        #expect(ProviderInfo.shortName("claude") != ProviderInfo.shortName("codex"))
        #expect(ProviderInfo.shortName("gemini") == "GE")
        #expect(ProviderInfo.shortName("x") == "X")
    }

    // MARK: 單一服務失敗（FR-12）

    @Test func allProvidersFailingIsNotPartialFailure() {
        let state = UsageActivityState(snapshot: snapshot(updatedAt: now, [
            "claude": ProviderUsage(error: "找不到 Claude Code 登入資訊"),
            "codex": ProviderUsage(error: "token 過期"),
        ]), mode: .remaining)
        #expect(!state.hasPartialFailure)
        #expect(state.tightest(at: now) == nil)
    }

    @Test func failedProviderWindowsAreIgnoredForTightest() {
        let snap = snapshot(updatedAt: now, [
            "claude": ProviderUsage(windows: [UsageWindow(id: "weekly", label: "每週", usedPct: 40)]),
            "codex": ProviderUsage(error: "token 過期", windows: [UsageWindow(id: "weekly", label: "每週", usedPct: 99)]),
        ])
        let state = UsageActivityState(snapshot: snap, mode: .remaining)
        #expect(state.tightest(at: now)?.provider == "claude")
    }
}
