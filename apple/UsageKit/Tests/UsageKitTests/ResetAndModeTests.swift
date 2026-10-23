import Foundation
import Testing
@testable import UsageKit

@Suite struct ResetAndModeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func window(used: Double, resetsIn offset: TimeInterval?) -> UsageWindow {
        UsageWindow(id: "five_hour", label: "5 小時", usedPct: used, resetsAt: offset.map { now.addingTimeInterval($0) })
    }

    @Test func windowIsResetAfterResetTime() {
        #expect(window(used: 80, resetsIn: -1).isReset(at: now))
        #expect(window(used: 80, resetsIn: 0).isReset(at: now))
        #expect(!window(used: 80, resetsIn: 60).isReset(at: now))
        #expect(!window(used: 80, resetsIn: nil).isReset(at: now))
    }

    @Test func resetWindowShowsZeroUsed() {
        let w = window(used: 80, resetsIn: -60)
        #expect(w.effectiveUsedPct(at: now) == 0)
        #expect(w.effectiveRemainingPct(at: now) == 100)
        #expect(w.effectiveSeverity(at: now) == .normal)
    }

    @Test func activeWindowKeepsPercentage() {
        let w = window(used: 85, resetsIn: 600)
        #expect(w.effectiveUsedPct(at: now) == 85)
        #expect(w.effectiveRemainingPct(at: now) == 15)
        #expect(w.effectiveSeverity(at: now) == .critical)
    }

    @Test func effectivePercentagesAreClamped() {
        #expect(window(used: 130, resetsIn: 60).effectiveUsedPct(at: now) == 100)
        #expect(window(used: -5, resetsIn: 60).effectiveRemainingPct(at: now) == 100)
    }

    @Test(arguments: [(UsageDisplayMode.used, 30.0), (.remaining, 70.0)])
    func displayedPctFollowsMode(mode: UsageDisplayMode, expected: Double) {
        #expect(window(used: 30, resetsIn: 60).displayedPct(mode, at: now) == expected)
    }

    @Test func displayModeLabels() {
        #expect(UsageDisplayMode.used.label == "已用")
        #expect(UsageDisplayMode.remaining.label == "剩餘")
    }

    @Test func tightestTreatsResetWindowAsFull() {
        let snap = UsageSnapshot(updatedAt: now, providers: [
            "claude": ProviderUsage(windows: [window(used: 95, resetsIn: -60)]),
            "codex": ProviderUsage(windows: [UsageWindow(id: "weekly", label: "每週", usedPct: 40, resetsAt: now.addingTimeInterval(3600))]),
        ])
        // 舊邏輯會挑 Claude 95%；重置後應改挑 Codex
        #expect(snap.tightestWindow?.provider == "claude")
        #expect(snap.tightestWindow(at: now)?.provider == "codex")
    }
}

@Suite struct LeastRemainingWordingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func displayNameIsProviderAndWindow() {
        let item = ProviderWindow(provider: "claude", window: UsageWindow(id: "weekly", label: "每週", usedPct: 33))
        #expect(item.displayName == "Claude 每週")
    }

    @Test func accessibilityLabelSaysItIsTheLeastRemaining() {
        let item = ProviderWindow(provider: "claude", window: UsageWindow(id: "weekly", label: "每週", usedPct: 33))
        #expect(item.leastRemainingAccessibilityLabel(at: now) == "剩餘最少的額度：Claude 每週，剩 67%")
        #expect(item.leastRemainingAccessibilityLabel(mode: .used, at: now) == "剩餘最少的額度：Claude 每週，已用 33%")
    }
}

/// 手錶列表的重置倒數（取代每秒更新的相對時間文字，避免 watchOS 版面不斷重算）
@Suite struct ResetCountdownTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func formatsToTheMinute() {
        func text(_ seconds: TimeInterval) -> String? { ResetCountdown.text(until: now.addingTimeInterval(seconds), now: now) }
        #expect(text(2 * 86400 + 23 * 3600 + 59 * 60) == "2天 23小時")
        #expect(text(86400 + 30) == "1天")
        #expect(text(3600 + 39 * 60 + 59) == "1小時 39分鐘")
        #expect(text(2 * 3600) == "2小時")
        #expect(text(12 * 60 + 5) == "12分鐘")
        #expect(text(30) == "不到 1 分鐘")
    }

    @Test func pastOrNowIsNil() {
        #expect(ResetCountdown.text(until: now, now: now) == nil)
        #expect(ResetCountdown.text(until: now.addingTimeInterval(-60), now: now) == nil)
    }
}
