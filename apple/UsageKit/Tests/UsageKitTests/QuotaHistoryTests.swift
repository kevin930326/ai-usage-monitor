import Foundation
import Testing
@testable import UsageKit

@Suite struct QuotaHistoryTests {
    /// 2026-11-02 00:00 UTC（星期一）
    let t0 = Date(timeIntervalSince1970: 1_793_577_600)
    let minute: TimeInterval = 60
    let hour: TimeInterval = 3600

    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    func sample(_ offset: TimeInterval, _ used: Double, resets: TimeInterval? = 5 * 3600, provider: String = "claude",
                window: String = "five_hour") -> QuotaSample {
        QuotaSample(ts: at(offset), provider: provider, windowID: window, usedPct: used, resetsAt: resets.map(at))
    }

    /// 每 5 分鐘一次收集，`from`～`to`（秒）
    func runs(_ from: TimeInterval, _ to: TimeInterval) -> [CollectorRun] {
        stride(from: from, through: to, by: 300).map { CollectorRun(ts: at($0)) }
    }

    // MARK: - 沒有紀錄的時段

    @Test func gapsAreRunsMoreThan15MinutesApart() {
        // 00:00～02:00 有紀錄，02:00～05:00 睡眠，05:00～06:00 有紀錄
        let h = QuotaHistory(runs: runs(0, 2 * hour) + runs(5 * hour, 6 * hour))
        let gaps = h.gaps(in: TimeSpan(start: at(0), end: at(6 * hour)))
        #expect(gaps == [TimeSpan(start: at(2 * hour), end: at(5 * hour))])
    }

    @Test func gapAtTheEndAndBeforeFirstRun() {
        let h = QuotaHistory(runs: runs(hour, 2 * hour))
        let gaps = h.gaps(in: TimeSpan(start: at(0), end: at(3 * hour)))
        #expect(gaps == [TimeSpan(start: at(0), end: at(hour)), TimeSpan(start: at(2 * hour), end: at(3 * hour))])
    }

    @Test func shortPausesAreNotGaps() {
        let h = QuotaHistory(runs: [CollectorRun(ts: at(0)), CollectorRun(ts: at(14 * minute)), CollectorRun(ts: at(28 * minute))])
        #expect(h.gaps(in: TimeSpan(start: at(0), end: at(30 * minute))).isEmpty)
    }

    @Test func downsampledRowCoversItsHour() {
        // 降採樣後每小時一列（時間是該小時最後一次），整天都算有紀錄
        let rows = stride(from: 55 * minute, to: 24 * hour, by: hour).map { CollectorRun(ts: at($0), ok: 12, runs: 12) }
        let h = QuotaHistory(runs: rows)
        #expect(h.gaps(in: TimeSpan(start: at(0), end: at(23 * hour + 55 * minute))).isEmpty)
    }

    // MARK: - 重置

    @Test func resetWhenResetsAtMovesOrUsageDrops() {
        #expect(QuotaHistory.isReset(from: sample(0, 80), to: sample(300, 2)))
        #expect(QuotaHistory.isReset(from: sample(0, 10, resets: hour), to: sample(300, 10, resets: 6 * hour)))
        #expect(!QuotaHistory.isReset(from: sample(0, 10, resets: hour), to: sample(300, 12, resets: hour + 120)))
        #expect(QuotaHistory.isReset(from: sample(0, 10, resets: nil), to: sample(300, 12, resets: hour)))
    }

    @Test func currentCycleStartsAtLastReset() {
        let s = [sample(0, 70), sample(300, 80), sample(600, 1, resets: 10 * hour), sample(900, 3, resets: 10 * hour)]
        #expect(QuotaHistory.currentCycle(s).map(\.usedPct) == [1, 3])
    }

    // MARK: - 近期速度

    @Test func recentRateNeedsFourSamplesOver30Minutes() {
        let now = at(hour)
        let few = QuotaHistory(samples: [sample(40 * minute, 10), sample(50 * minute, 12), sample(hour, 14)])
        #expect(few.recentRate(provider: "claude", windowID: "five_hour", now: now) == nil)
        let short = QuotaHistory(samples: (0..<6).map { sample(hour - Double($0) * 4 * minute, 20 - Double($0)) })
        #expect(short.recentRate(provider: "claude", windowID: "five_hour", now: now) == nil)
        // 最近 60 分鐘從 10% 到 22%，跨 50 分鐘
        let ok = QuotaHistory(samples: [sample(10 * minute, 10), sample(20 * minute, 13), sample(40 * minute, 18), sample(hour, 22)])
        let rate = ok.recentRate(provider: "claude", windowID: "five_hour", now: now)!
        #expect(abs(rate - 12.0 / (50 * minute)) < 1e-9)
    }

    @Test func recentRateIgnoresSamplesBeforeReset() {
        let now = at(hour)
        let h = QuotaHistory(samples: [sample(5 * minute, 90), sample(10 * minute, 95), sample(15 * minute, 1, resets: 6 * hour),
                                       sample(30 * minute, 2, resets: 6 * hour), sample(50 * minute, 3, resets: 6 * hour)])
        #expect(h.recentRate(provider: "claude", windowID: "five_hour", now: now) == nil)
    }

    @Test func recentRateOnlyForFiveHourAndWeekly() {
        #expect(QuotaHistory.recentLookback(windowID: "five_hour") == 3600)
        #expect(QuotaHistory.recentLookback(windowID: "weekly_fable") == 86400)
        #expect(QuotaHistory.recentLookback(windowID: "90m") == nil)
    }

    @Test func paceUsesRecentRateForExhaustion() {
        // 5 小時額度：經過 3 小時已用 60%（超前 0），平均速度會在 2 小時後用完…
        let now = at(3 * hour)
        let window = UsageWindow(id: "five_hour", label: "5 小時", usedPct: 80, resetsAt: at(5 * hour))
        // 最近 60 分鐘從 40% 到 80%：每分鐘 2/3 個百分點，剩 20% → 30 分鐘後用完
        let h = QuotaHistory(samples: [sample(2 * hour, 40), sample(2 * hour + 20 * minute, 53), sample(2 * hour + 40 * minute, 67), sample(3 * hour, 80)])
        let pace = UsagePace(window: window, provider: "claude", history: h, stale: false, now: now)!
        #expect(pace.isTooFast)
        #expect(abs(pace.exhaustsAt!.timeIntervalSince(now) - 30 * minute) < 1)
        // 沒有歷史：退回平均速度（3 小時用了 80% → 再 45 分鐘）
        let fallback = UsagePace(window: window, provider: "claude", history: .empty, stale: false, now: now)!
        #expect(abs(fallback.exhaustsAt!.timeIntervalSince(now) - 45 * minute) < 1)
    }

    @Test func paceWithIdleRecentUsageDoesNotRunOut() {
        let now = at(3 * hour)
        let window = UsageWindow(id: "five_hour", label: "5 小時", usedPct: 80, resetsAt: at(5 * hour))
        let h = QuotaHistory(samples: (0..<5).map { sample(2 * hour + Double($0) * 15 * minute, 80) })
        let pace = UsagePace(window: window, provider: "claude", history: h, stale: false, now: now)!
        #expect(pace.isTooFast)  // 門檻不變：已用比照時間多 ≥ 10 個百分點
        #expect(pace.exhaustsAt == nil)
    }

    // MARK: - 建議接下來用

    func snapshot(claude: [UsageWindow], codex: [UsageWindow]?, updated: Date) -> UsageSnapshot {
        var providers = ["claude": ProviderUsage(plan: "Max", windows: claude)]
        if let codex { providers["codex"] = ProviderUsage(plan: "Plus", windows: codex) }
        return UsageSnapshot(updatedAt: updated, providers: providers)
    }

    func w(_ id: String, _ used: Double) -> UsageWindow {
        UsageWindow(id: id, label: id == "five_hour" ? "5 小時" : "每週", usedPct: used, resetsAt: at(10 * hour))
    }

    @Test func suggestsOtherProviderWhenOneIsLow() {
        let s = snapshot(claude: [w("five_hour", 85), w("weekly", 40)], codex: [w("five_hour", 18), w("weekly", 30)], updated: at(0))
        let suggestion = NextProviderSuggestion(snapshot: s, now: at(60))!
        #expect(suggestion.provider == "codex")
        #expect(suggestion.window.id == "five_hour")
        #expect(suggestion.remainingPct == 82)
        #expect(suggestion.exhaustedProvider == "claude")
    }

    @Test func noSuggestionWhenBothPlentyOrBothLowOrSingleProvider() {
        let plenty = snapshot(claude: [w("five_hour", 50)], codex: [w("five_hour", 10)], updated: at(0))
        #expect(NextProviderSuggestion(snapshot: plenty, now: at(60)) == nil)
        let bothLow = snapshot(claude: [w("five_hour", 85)], codex: [w("five_hour", 60)], updated: at(0))
        #expect(NextProviderSuggestion(snapshot: bothLow, now: at(60)) == nil)  // Codex 只剩 40%
        let single = snapshot(claude: [w("five_hour", 95)], codex: nil, updated: at(0))
        #expect(NextProviderSuggestion(snapshot: single, now: at(60)) == nil)
    }

    @Test func noSuggestionWhenTheOtherProviderHasAnotherLowWindow() {
        let s = snapshot(claude: [w("five_hour", 90)], codex: [w("five_hour", 10), w("weekly", 85)], updated: at(0))
        #expect(NextProviderSuggestion(snapshot: s, now: at(60)) == nil)
    }

    @Test func noSuggestionWhenStale() {
        let s = snapshot(claude: [w("five_hour", 90)], codex: [w("five_hour", 10)], updated: at(0))
        #expect(NextProviderSuggestion(snapshot: s, now: at(31 * minute)) == nil)
    }

    // MARK: - 重置時間軸與每週預測

    @Test func upcomingResetsWithinEightHours() {
        let s = UsageSnapshot(updatedAt: at(0), providers: [
            "claude": ProviderUsage(windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: 1, resetsAt: at(2 * hour)),
                UsageWindow(id: "weekly", label: "每週", usedPct: 1, resetsAt: at(50 * hour)),
            ]),
            "codex": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 1, resetsAt: at(hour))]),
        ])
        let list = UpcomingReset.list(snapshot: s, now: at(0))
        #expect(list.map(\.provider) == ["codex", "claude"])
        #expect(list.map(\.position) == [0.125, 0.25])
    }

    @Test func weeklyForecastRunsOutWithRecentRate() {
        // 每週額度已用 50%，再 3 天重置；最近 24 小時用了 24%（每小時 1%）→ 50 小時後用完
        let now = at(4 * 86400)
        let weekly = UsageWindow(id: "weekly", label: "每週", usedPct: 50, resetsAt: now.addingTimeInterval(3 * 86400))
        let s = UsageSnapshot(updatedAt: now, providers: ["claude": ProviderUsage(windows: [weekly])])
        let samples = (0...24).map { i in
            QuotaSample(ts: now.addingTimeInterval(Double(i - 24) * hour), provider: "claude", windowID: "weekly",
                        usedPct: 26 + Double(i), resetsAt: weekly.resetsAt)
        }
        let forecast = WeeklyForecast.list(snapshot: s, history: QuotaHistory(samples: samples), now: now)
        #expect(forecast.count == 1)
        #expect(forecast[0].outcome == .runsOut(now.addingTimeInterval(50 * hour)))
        #expect(forecast[0].usesRecentRate)
    }

    @Test func weeklyForecastFallsBackToAverageAndCanLast() {
        // 經過 4 天用了 20%：平均每天 5%，剩 80% 撐得過剩下的 3 天
        let now = at(4 * 86400)
        let weekly = UsageWindow(id: "weekly", label: "每週", usedPct: 20, resetsAt: now.addingTimeInterval(3 * 86400))
        let s = UsageSnapshot(updatedAt: now, providers: ["claude": ProviderUsage(windows: [weekly])])
        let forecast = WeeklyForecast.list(snapshot: s, history: .empty, now: now)
        #expect(forecast[0].outcome == .lastsUntilReset)
        #expect(!forecast[0].usesRecentRate)
    }

    @Test func dayPartNames() {
        #expect(WeeklyForecast.dayPart(at(4 * 86400 + 20 * hour), calendar: utc) == "週五晚上")  // 11/6 星期五 20:00
        #expect(WeeklyForecast.dayPart(at(3 * hour), calendar: utc) == "週一凌晨")
        #expect(WeeklyForecast.dayPart(at(13 * hour), calendar: utc) == "週一下午")
    }

    // MARK: - 走勢

    @Test func trendCoversCurrentCycleWithGaps() {
        let now = at(3 * hour)
        let window = UsageWindow(id: "five_hour", label: "5 小時", usedPct: 30, resetsAt: at(5 * hour))
        let h = QuotaHistory(
            samples: [sample(-hour, 90, resets: 0), sample(10 * minute, 5), sample(hour, 10), sample(2 * hour + 30 * minute, 25), sample(3 * hour, 30)],
            runs: runs(0, hour) + runs(2 * hour + 30 * minute, 3 * hour)
        )
        let trend = QuotaTrend(provider: "claude", window: window, history: h, now: now)
        #expect(trend.span == TimeSpan(start: at(0), end: at(5 * hour)))
        #expect(trend.points.map(\.remainingPct) == [95, 90, 75, 70])
        #expect(trend.gaps == [TimeSpan(start: at(hour), end: at(2 * hour + 30 * minute))])
        #expect(trend.hasEnoughData)
        #expect(trend.expectedRemaining(at: at(2.5 * hour)) == 50)
    }

    @Test func trendWithOneSampleIsNotEnough() {
        let now = at(10 * minute)
        let window = UsageWindow(id: "five_hour", label: "5 小時", usedPct: 3, resetsAt: at(5 * hour))
        let trend = QuotaTrend(provider: "claude", window: window, history: QuotaHistory(samples: [sample(5 * minute, 3)]), now: now)
        #expect(!trend.hasEnoughData)
    }

    // MARK: - 額度消耗

    @Test func hourlyConsumptionFromPositiveDeltas() {
        let now = at(3 * hour)
        let h = QuotaHistory(
            samples: [sample(0, 10), sample(30 * minute, 14), sample(55 * minute, 15), sample(hour + 30 * minute, 20)]
                + stride(from: 2 * hour, through: 3 * hour, by: 300).map { sample($0, 20) },
            runs: runs(0, 3 * hour)
        )
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: now, days: 1, calendar: utc)
        #expect(c.hours.count == 24)
        #expect(abs(c.hours[0].consumed! - (5 + 5 * 5.0 / 35)) < 1e-9)  // 00:55～01:30 的 5 點，5/35 在 00 點
        #expect(abs(c.hours[1].consumed! - 5 * 30.0 / 35) < 1e-9)
        #expect(c.hours[2].consumed == 0)
        #expect(c.hours[5].consumed == nil)  // 還沒到
        // 00:55～01:30 之間收集器有執行、但這個額度沒有樣本（例如服務錯誤）：同樣平均分配並標成估計
        #expect(c.hours[0].estimated)
        #expect(!c.hours[2].estimated)
    }

    @Test func resetSegmentCountsNewValue() {
        let now = at(hour)
        let h = QuotaHistory(samples: [sample(0, 90, resets: 5 * minute), sample(10 * minute, 4, resets: 5 * hour)], runs: runs(0, hour))
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: now, days: 1, calendar: utc)
        #expect(c.hours[0].consumed == 4)
    }

    @Test func gapDeltaIsSpreadEvenlyAndMarkedEstimated() {
        // 01:00 到 05:00 睡眠，期間額度從 10% 到 30%：每小時分 5 點
        let now = at(6 * hour)
        let h = QuotaHistory(samples: [sample(hour, 10), sample(5 * hour, 30)], runs: runs(0, hour) + runs(5 * hour, 6 * hour))
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: now, days: 1, calendar: utc)
        for i in 1..<5 {
            #expect(abs(c.hours[i].consumed! - 5) < 1e-9)
            #expect(c.hours[i].estimated)
        }
        #expect(c.hours[0].consumed == 0)
        #expect(!c.hours[0].estimated)
    }

    @Test func gapWithResetIsNotDistributed() {
        let now = at(6 * hour)
        let h = QuotaHistory(samples: [sample(hour, 80, resets: 2 * hour), sample(5 * hour, 30, resets: 7 * hour)],
                             runs: runs(0, hour) + runs(5 * hour, 6 * hour))
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: now, days: 1, calendar: utc)
        for i in 1..<5 { #expect(c.hours[i].consumed == nil) }
        #expect(c.hours[0].consumed == 0)
        #expect(c.hours[5].consumed == 0)
    }

    @Test func noRunsMeansNoRecordNotZero() {
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: .empty, now: at(3 * hour), days: 1, calendar: utc)
        #expect(!c.hasEnoughData)
        #expect(c.hours.allSatisfy { $0.consumed == nil })
    }

    @Test func resetBetweenSamplesCountsOnlyAfterTheReset() {
        // 00:55 已用 90%（01:00 重置）→ 01:05 已用 4%：新一輪的 4 點全部算在 01:00 那一小時
        let h = QuotaHistory(samples: [sample(55 * minute, 90, resets: hour), sample(65 * minute, 4, resets: 6 * hour)],
                             runs: runs(0, 2 * hour))
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: at(2 * hour), days: 1, calendar: utc)
        #expect(c.hours[0].consumed == 0)
        #expect(c.hours[1].consumed == 4)
        #expect(!c.hours[1].estimated)
    }

    @Test func resetAtMidnightIsNotCountedInThePreviousDay() {
        // 前一天 23:55 已用 90%（00:00 重置）→ 00:05 已用 4%
        let h = QuotaHistory(samples: [sample(-5 * minute, 90, resets: 0), sample(5 * minute, 4, resets: 5 * hour)],
                             runs: runs(-hour, hour))
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: at(hour), days: 2, calendar: utc)
        #expect(c.dailyTotals[0].consumed == 0)
        #expect(c.dailyTotals[1].consumed == 4)
    }

    @Test func oneSampleIsNotEnoughForConsumption() {
        let h = QuotaHistory(samples: [sample(hour, 3)], runs: [CollectorRun(ts: at(hour))])
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: at(hour + 60), days: 1, calendar: utc)
        #expect(!c.hasEnoughData)
    }

    @Test func dailyTotalsSumHours() {
        let now = at(86400 + 2 * hour)
        let h = QuotaHistory(samples: [sample(0, 0, resets: nil), sample(hour, 6, resets: nil), sample(86400 + hour, 9, resets: nil)],
                             runs: runs(0, 86400 + 2 * hour))
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: now, days: 2, calendar: utc)
        let totals = c.dailyTotals
        #expect(totals.count == 2)
        #expect(abs(totals[0].consumed! - (6 + 3 * 23.0 / 24)) < 1e-9)
        #expect(abs(totals[1].consumed! - 3.0 / 24) < 1e-9)
    }

    // MARK: - CSV

    @Test func csvKeepsLastSamplePerHour() {
        let csv = QuotaHistoryCSV.make(samples: [
            sample(5 * minute, 10), sample(55 * minute, 12.5), sample(hour + minute, 13, resets: nil),
            sample(10 * minute, 3, provider: "codex"),
        ])
        let base = Int(t0.timeIntervalSince1970)
        #expect(csv == """
        ts,provider,window_id,used_pct,resets_at
        \(base + 600),codex,five_hour,3,\(base + 18000)
        \(base + 3300),claude,five_hour,12.5,\(base + 18000)
        \(base + 3660),claude,five_hour,13,

        """)
    }

    @Test func csvEscapesFormulaAndQuotes() {
        #expect(QuotaHistoryCSV.field("=cmd") == "'=cmd")
        #expect(QuotaHistoryCSV.field("a,b") == "\"a,b\"")
        #expect(QuotaHistoryCSV.field("a\"b") == "\"a\"\"b\"")
    }
}
