import Foundation
import Testing
@testable import UsageKit

@Suite struct UsagePaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 5 小時額度，已用 `used`%，再 `resetsIn` 秒重置
    func fiveHour(used: Double, resetsIn: TimeInterval?) -> UsageWindow {
        UsageWindow(id: "five_hour", label: "5 小時", usedPct: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    @Test(arguments: [
        ("five_hour", 5 * 3600.0), ("weekly", 7 * 86400.0), ("weekly_fable", 7 * 86400.0),
        ("24h", 86400.0), ("90m", 5400.0),
    ])
    func durationFromID(id: String, expected: Double) {
        #expect(UsageWindow(id: id, label: "", usedPct: 0).duration == expected)
    }

    @Test(arguments: ["monthly", "h", "0h", "-5h", "weeklyish", "xm"])
    func unknownDurationIsNil(id: String) {
        #expect(UsageWindow(id: id, label: "", usedPct: 0).duration == nil)
    }

    @Test func expectedRemainingFollowsElapsedTime() {
        // 5 小時額度還剩 1 小時 → 經過 80%，照時間應剩 20%
        let w = fiveHour(used: 50, resetsIn: 3600)
        #expect(abs(w.elapsedFraction(at: now)! - 0.8) < 1e-9)
        #expect(abs(w.expectedRemainingPct(at: now)! - 20) < 1e-9)
        #expect(abs(w.timeRemainingFraction(at: now)! - 0.2) < 1e-9)
        #expect(w.expectedRemainingDescription(at: now) == "照時間比例，現在應剩 20%")
        // 5 小時額度還剩 6 分鐘 → 應剩 2%
        #expect(fiveHour(used: 50, resetsIn: 360).expectedRemainingDescription(at: now) == "照時間比例，現在應剩 2%")
    }

    @Test func noExpectationWhenResetOrUnknown() {
        #expect(fiveHour(used: 50, resetsIn: -1).expectedRemainingPct(at: now) == nil)
        #expect(fiveHour(used: 50, resetsIn: nil).expectedRemainingPct(at: now) == nil)
        #expect(fiveHour(used: 50, resetsIn: nil).expectedRemainingDescription(at: now) == nil)
        #expect(UsageWindow(id: "monthly", label: "", usedPct: 1, resetsAt: now.addingTimeInterval(60)).elapsedFraction(at: now) == nil)
    }

    @Test func elapsedIsClampedWhenResetIsFurtherThanDuration() {
        // 收集器的重置時間比額度長度還遠（時鐘誤差）時不得出現負數
        #expect(fiveHour(used: 0, resetsIn: 6 * 3600).elapsedFraction(at: now) == 0)
    }

    @Test func tooFastNeedsTenPointsAhead() {
        // 經過 50%（剩 2.5 小時）：已用 60% 超前 10 點 → 太快；59% 不算
        #expect(UsagePace(window: fiveHour(used: 60, resetsIn: 9000), stale: false, now: now)?.isTooFast == true)
        #expect(UsagePace(window: fiveHour(used: 59, resetsIn: 9000), stale: false, now: now)?.isTooFast == false)
    }

    @Test func noPaceEarlyInWindowWhenStaleOrReset() {
        // 經過不到 10%：一次大請求就會超前，不判斷
        #expect(UsagePace(window: fiveHour(used: 50, resetsIn: 4.6 * 3600), stale: false, now: now) == nil)
        #expect(UsagePace(window: fiveHour(used: 90, resetsIn: 3600), stale: true, now: now) == nil)
        #expect(UsagePace(window: fiveHour(used: 90, resetsIn: -60), stale: false, now: now) == nil)
    }

    @Test func exhaustsAtOnlyBeforeReset() {
        // 經過 50%（2.5 小時）已用 75% → 每小時 30%，剩 25% 約 50 分鐘後用完，早於重置
        let pace = UsagePace(window: fiveHour(used: 75, resetsIn: 9000), stale: false, now: now)
        #expect(abs(pace!.exhaustsAt!.timeIntervalSince(now) - 3000) < 1)
        // 已用 30%：照這速度要 5 小時以上才用完，晚於重置 → 不顯示
        #expect(UsagePace(window: fiveHour(used: 30, resetsIn: 9000), stale: false, now: now)?.exhaustsAt == nil)
        // 已用 0%：沒有速度
        #expect(UsagePace(window: fiveHour(used: 0, resetsIn: 9000), stale: false, now: now)?.exhaustsAt == nil)
    }

    @Test func menuBarStatePriority() {
        let fast = fiveHour(used: 60, resetsIn: 9000)
        let critical = fiveHour(used: 85, resetsIn: 9000)
        #expect(MenuBarState(window: fast, stale: false, now: now) == .tooFast)
        // 剩不到 20% 優先於太快；過期優先於全部（灰色優先，FR-16）
        #expect(MenuBarState(window: critical, stale: false, now: now) == .critical)
        #expect(MenuBarState(window: critical, stale: true, now: now) == .stale)
        #expect(MenuBarState(window: fiveHour(used: 10, resetsIn: 9000), stale: false, now: now) == .normal)
    }

    @Test func windowChoiceFallsBackToTightest() {
        let snapshot = UsageSnapshot(updatedAt: now, providers: [
            "claude": ProviderUsage(windows: [fiveHour(used: 90, resetsIn: 3600)]),
            "codex": ProviderUsage(windows: [UsageWindow(id: "weekly", label: "每週", usedPct: 10, resetsAt: now.addingTimeInterval(86400))]),
        ])
        #expect(snapshot.window(for: .specific(provider: "codex", windowID: "weekly"), at: now)?.provider == "codex")
        #expect(snapshot.window(for: .specific(provider: "codex", windowID: "gone"), at: now)?.provider == "claude")
        #expect(snapshot.window(for: .automatic, at: now)?.provider == "claude")
        #expect(MenuBarWindowChoice(rawValue: "codex/weekly") == .specific(provider: "codex", windowID: "weekly"))
        #expect(MenuBarWindowChoice(rawValue: "auto") == .automatic)
        #expect(MenuBarWindowChoice(rawValue: MenuBarWindowChoice.specific(provider: "a", windowID: "b").rawValue) == .specific(provider: "a", windowID: "b"))
    }
}

@Suite struct PanelLayoutTests {
    let defaults = ["ring", "quota", "trend"]

    @Test func missingSettingsUseDefaultOrder() {
        let layout = PanelLayout.resolve(stored: nil, defaultOrder: defaults)
        #expect(layout.entries.map(\.id) == defaults)
        #expect(layout.entries.allSatisfy { $0.enabled })
    }

    @Test func newSectionIsInsertedAfterItsPredecessor() {
        let stored = PanelLayout(entries: [.init(id: "quota", enabled: true), .init(id: "ring", enabled: false)]).encoded()
        let layout = PanelLayout.resolve(stored: stored, defaultOrder: defaults)
        // 使用者的順序與開關保留，新的 trend 接在預設順序的前一個（quota）後面
        #expect(layout.entries.map(\.id) == ["quota", "trend", "ring"])
        #expect(layout.entries.first { $0.id == "ring" }?.enabled == false)
        #expect(layout.entries.first { $0.id == "trend" }?.enabled == true)
    }

    @Test func unknownSectionsAreKeptButHidden() {
        let stored = PanelLayout(entries: [.init(id: "future", enabled: true), .init(id: "ring", enabled: true)]).encoded()
        let layout = PanelLayout.resolve(stored: stored, defaultOrder: defaults)
        #expect(layout.entries.map(\.id).contains("future"))
        #expect(layout.visibleIDs(known: Set(defaults)) == ["ring", "quota", "trend"])
    }

    @Test func corruptOrDuplicateSettings() {
        #expect(PanelLayout.resolve(stored: Data("x".utf8), defaultOrder: defaults).entries.map(\.id) == defaults)
        let dup = PanelLayout(entries: [.init(id: "ring", enabled: false), .init(id: "ring", enabled: true)]).encoded()
        let layout = PanelLayout.resolve(stored: dup, defaultOrder: defaults)
        #expect(layout.entries.filter { $0.id == "ring" }.count == 1)
        #expect(layout.entries.first { $0.id == "ring" }?.enabled == false)
    }

    @Test func moveSkipsUnknownSections() {
        var layout = PanelLayout(entries: [
            .init(id: "ring", enabled: true), .init(id: "future", enabled: true),
            .init(id: "quota", enabled: true), .init(id: "trend", enabled: true),
        ])
        // 設定畫面只看到 ring、quota、trend；把 trend 拖到最前面
        layout.move(knownIDs: Set(defaults), fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(layout.entries.map(\.id) == ["trend", "future", "ring", "quota"])
        layout.setEnabled(false, for: "quota")
        #expect(layout.visibleIDs(known: Set(defaults)) == ["trend", "ring"])
    }
}
