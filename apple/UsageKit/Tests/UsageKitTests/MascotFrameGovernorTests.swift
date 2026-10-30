import Testing
@testable import UsageKit

/// 看滑鼠超標自動降幀（ADR-0016 第 6 節；Fable F-02、F-03、F-08、F-12）
@Suite struct MascotFrameGovernorTests {
    /// 每格 `frame` 毫秒、CPU 照 `cost(t, 當時的格數)`（%）累積，跑到 `until`；回傳每次換級
    func run(_ g: inout MascotFrameGovernor, from start: Int = 0, until end: Int, frame: Int = 16,
             cost: (Int, Int) -> Double) -> [MascotFrameGovernor.Change] {
        var cpu = 0.0, changes: [MascotFrameGovernor.Change] = []
        var t = start
        while t < end {
            cpu += cost(t, g.fps) / 100 * Double(frame) / 1000
            if let c = g.observe(at: t, cpu: { cpu }) { changes.append(c) }
            t += frame
        }
        return changes
    }

    @Test func ratesAreExactDivisorsOfTheScreen() {
        #expect(MascotFrameGovernor.rates(screen: 120, cap: 120, floor: 30) == [120, 60, 40, 30])
        #expect(MascotFrameGovernor.rates(screen: 60, cap: 120, floor: 30) == [60, 30])
        #expect(MascotFrameGovernor.rates(screen: 60, cap: 30, floor: 15) == [30, 20, 15])
        #expect(MascotFrameGovernor.rates(screen: 120, cap: 30, floor: 15) == [30, 24, 20, 15])
        #expect(MascotFrameGovernor.rates(screen: 50, cap: 30, floor: 15) == [25])
        #expect(MascotFrameGovernor.rates(screen: 24, cap: 120, floor: 30) == [24])
    }

    @Test func underBudgetStaysAtTheScreenRate() {
        var g = MascotFrameGovernor(rates: [60, 30], budget: 2)
        let got = run(&g, until: 60_000) { _, _ in 1.5 }
        #expect(got.isEmpty)
        #expect(g.fps == 60)
    }

    @Test func oneSpikeDoesNotLowerTheRate() {
        // 每分鐘的更新這種一次的尖峰：只有一段超標
        var g = MascotFrameGovernor(rates: [60, 30], budget: 2)
        let got = run(&g, until: 30_000) { t, _ in (10_000..<10_300).contains(t) ? 30 : 1 }
        #expect(got.isEmpty)
        #expect(g.fps == 60)
    }

    @Test func steadilyOverBudgetStepsDownToTheFloorAndStays() {
        var g = MascotFrameGovernor(rates: [30, 20, 15], budget: 1)
        let changes = run(&g, until: 120_000) { _, _ in 3 }
        #expect(g.fps == 15)
        #expect(changes.first?.from == 30 && changes.first?.to == 20)
        // 到了最慢的一級還在超標：不試著升回去（每段都超標，連續超標的計數不歸零）
        let tried = changes.contains { $0.isTrial }
        #expect(!tried)
    }

    @Test func climbsBackWhenTheFasterRateFits() {
        // 固定成本為主（每格成本小）：降到 30 之後升回 60 試一次也在目標內，就留在 60（Fable F-02 的固定成本模型）
        var g = MascotFrameGovernor(rates: [60, 30], budget: 2)
        var busy = true
        _ = run(&g, until: 10_000) { _, _ in busy ? 4 : 0 }
        #expect(g.fps == 30)
        busy = false
        _ = run(&g, from: 10_000, until: 40_000) { _, _ in 0.8 + 0.02 * 60 / 2 }
        #expect(g.fps == 60)
    }

    @Test func shortPausesContinueAndLongOnesRestartTheWindow() {
        // 眨眼約 0.3 秒圖層停掉：接著算；停 2 秒：重新開始一段，連續超標的計數也歸零
        var g = MascotFrameGovernor(rates: [60, 30], budget: 2)
        var cpu = 0.0
        var t = 0
        for _ in 0..<2 {
            for _ in 0..<130 { cpu += 0.03 * 0.016; _ = g.observe(at: t, cpu: { cpu }); t += 16 }
            t += 2_000
        }
        #expect(g.fps == 60)
        // 不停頓、一直超標：兩段之後降一級
        var h = MascotFrameGovernor(rates: [60, 30], budget: 2)
        let got = run(&h, until: 8_000) { _, _ in 4 }
        #expect(got.count == 1)
    }

    @Test func failedTrialBacksOffLonger() {
        // 升回去那一段超標就退回，下次再試的等待加倍（10 → 20 秒）
        var g = MascotFrameGovernor(rates: [60, 30], budget: 2)
        let changes = run(&g, until: 60_000) { _, fps in fps == 60 ? 3 : 1.2 }
        let trials = changes.filter(\.isTrial).map(\.from)
        #expect(trials.count >= 2 && trials.count <= 3)
        #expect(g.fps == 30 || changes.last?.isTrial == true)
    }

    @Test func forgetsAfterTenMinutesWithoutGaze() {
        var g = MascotFrameGovernor(rates: [60, 30], budget: 2)
        _ = run(&g, until: 10_000) { _, _ in 5 }
        #expect(g.fps == 30)
        _ = run(&g, from: 10_000 + MascotFrameGovernor.forgetMs + 1, until: 10_000 + MascotFrameGovernor.forgetMs + 100) { _, _ in 0 }
        #expect(g.fps == 60)
    }
}
