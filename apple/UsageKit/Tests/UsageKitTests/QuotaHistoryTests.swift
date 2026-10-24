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

    @Test func smallDropIsACorrectionNotAReset() {
        // 服務小幅下修（Claude 的整數 % 四捨五入改變、Codex 重新計算）：resets_at 沒變、新值高於舊值一半
        #expect(!QuotaHistory.isReset(from: sample(0, 33), to: sample(300, 32)))
        #expect(!QuotaHistory.isReset(from: sample(0, 50, resets: hour), to: sample(300, 48, resets: hour + 60)))
        #expect(!QuotaHistory.isReset(from: sample(0, 40), to: sample(300, 21)))
        // 剛好一半或更低：重置（resets_at 沒跟著更新時）
        #expect(QuotaHistory.isReset(from: sample(0, 40), to: sample(300, 20)))
        #expect(QuotaHistory.isReset(from: sample(0, 1), to: sample(300, 0)))
        // 小幅下降但 resets_at 也改變：兩者同時發生，算重置
        #expect(QuotaHistory.isReset(from: sample(0, 50, resets: hour), to: sample(300, 48, resets: 6 * hour)))
    }

    @Test func correctionKeepsTheCycleAndCountsNothing() {
        // 00:00 50% → 00:30 下修為 48% → 01:00 52%：下修那段記 0，之後的 4 點照算；目前這一輪不從下修處重新起算
        let h = QuotaHistory(samples: [sample(0, 50), sample(30 * minute, 48), sample(hour, 52)], runs: runs(0, 2 * hour))
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: at(2 * hour), days: 1, calendar: utc)
        #expect(c.hours[0].consumed == 4)
        #expect(c.hours[1].consumed == 0)
        #expect(QuotaHistory.currentCycle(h.samples(provider: "claude", windowID: "five_hour")).count == 3)
    }

    @Test func consumptionLevelsSplitPeakIntoFiveSteps() {
        // 00:00 0% → 01:00 10% → 02:00 12%：peak 10，2 點落在第 1 階
        let h = QuotaHistory(samples: [sample(0, 0), sample(hour, 10), sample(2 * hour, 12)], runs: runs(0, 3 * hour))
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: at(3 * hour), days: 1, calendar: utc)
        #expect(c.peak == 10)
        #expect(c.level(0) == 0)
        #expect(c.level(0.1) == 1)
        #expect(c.level(2) == 1)
        #expect(c.level(2.1) == 2)
        #expect(c.level(8) == 4)
        #expect(c.level(10) == 5)
        #expect(c.level(30) == 5)
    }

    @Test func realisticResetAndCorrectionTogether() {
        // 5 小時額度：87%（00:10 重置）→ 00:15 3%（resets_at 往後 5 小時）→ 00:20 下修為 2% → 00:50 6%
        let resets = 5 * hour + 10 * minute
        let h = QuotaHistory(samples: [sample(0, 87, resets: 10 * minute), sample(15 * minute, 3, resets: resets),
                                       sample(20 * minute, 2, resets: resets), sample(50 * minute, 6, resets: resets)],
                             runs: runs(0, hour))
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: h, now: at(hour), days: 1, calendar: utc)
        #expect(c.hours[0].consumed == 7)  // 新一輪的 3 點＋下修後的 4 點，下修本身不計
        #expect(QuotaHistory.currentCycle(h.samples(provider: "claude", windowID: "five_hour")).map(\.usedPct) == [3, 2, 6])
        // 每週額度：resets_at 沒有更新、% 從 60 掉到 3（≤ 一半）：仍是重置
        #expect(QuotaHistory.isReset(from: sample(0, 60, resets: 7 * 86400, window: "weekly"),
                                     to: sample(300, 3, resets: 7 * 86400, window: "weekly")))
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

    @Test func recentRateSumsPositiveStepsAcrossDownwardCorrections() {
        // 最近 60 分鐘：40 → 52 → 下修 30（不到一半，不算重置）→ 40，跨 50 分鐘。
        // 兩端相減是 0（以前的算法，「用得太快」就不會出現）；正差值總和是 12 + 10 = 22 點
        let now = at(hour)
        let h = QuotaHistory(samples: [sample(10 * minute, 40), sample(20 * minute, 52), sample(40 * minute, 30), sample(hour, 40)])
        #expect(QuotaHistory.currentCycle(h.samples(provider: "claude", windowID: "five_hour")).count == 4)
        let rate = h.recentRate(provider: "claude", windowID: "five_hour", now: now)!
        #expect(abs(rate - 22.0 / (50 * minute)) < 1e-9)
        // 與額度消耗一致：同一段的消耗也是 22
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: QuotaHistory(samples: h.samples, runs: runs(0, hour)),
                                 now: now, days: 1, calendar: utc)
        #expect(c.hours[0].consumed == 22)
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
        // 平均速度會在重置前用完，但最近一小時沒在用：照近期速度不會用完，不算太快
        #expect(!pace.isTooFast)
        #expect(pace.exhaustsAt == nil)
        #expect(UsagePace(window: window, provider: "claude", history: .empty, stale: false, now: now)!.isTooFast)
    }

    @Test func recentlyFastIsTooFastEvenWhenAverageIsBehind() {
        // 經過 3 小時只用了 40%（平均會撐到重置），但最近 60 分鐘從 4% 用到 40%（每小時 36%）→ 100 分鐘後用完，早於重置
        let now = at(3 * hour)
        let window = UsageWindow(id: "five_hour", label: "5 小時", usedPct: 40, resetsAt: at(5 * hour))
        #expect(!UsagePace(window: window, provider: "claude", history: .empty, stale: false, now: now)!.isTooFast)
        let h = QuotaHistory(samples: [sample(2 * hour, 4), sample(2 * hour + 20 * minute, 16), sample(2 * hour + 40 * minute, 28), sample(3 * hour, 40)])
        let pace = UsagePace(window: window, provider: "claude", history: h, stale: false, now: now)!
        #expect(pace.isTooFast)
        #expect(abs(pace.exhaustsAt!.timeIntervalSince(now) - 100 * minute) < 1)
    }

    @Test func weeklyRecentRateNeeds12Hours() {
        #expect(QuotaHistory.recentMinimumSpan(windowID: "five_hour") == 30 * minute)
        #expect(QuotaHistory.recentMinimumSpan(windowID: "weekly") == 12 * hour)
        let now = at(4 * 86400)
        let weekly = { (span: TimeInterval) in
            QuotaHistory(samples: stride(from: 0, through: span, by: 300).map {
                QuotaSample(ts: now.addingTimeInterval($0 - span), provider: "claude", windowID: "weekly", usedPct: 20 + $0 / 3600, resetsAt: at(7 * 86400))
            })
        }
        #expect(weekly(11 * hour).recentRate(provider: "claude", windowID: "weekly", now: now) == nil)
        #expect(weekly(12 * hour).recentRate(provider: "claude", windowID: "weekly", now: now) != nil)
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

    @Test func pastResetTimeShowsJustResetAtNow() {
        // Codex 5 小時的重置時間 10 分鐘前已過、收集器還沒拿到新的：畫在「現在」、標剛重置，排在最前面
        let s = UsageSnapshot(updatedAt: at(0), providers: [
            "claude": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 30, resetsAt: at(2 * hour))]),
            "codex": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 80, resetsAt: at(-10 * minute))]),
        ])
        let list = UpcomingReset.list(snapshot: s, now: at(0))
        #expect(list.map(\.provider) == ["codex", "claude"])
        #expect(list.map(\.justReset) == [true, false])
        #expect(list[0].position == 0)
        #expect(UpcomingReset.awaitingStart(snapshot: s).isEmpty)
        // 收集器拿到新的重置時間後就不再是剛重置
        let next = UsageSnapshot(updatedAt: at(5 * minute), providers: [
            "codex": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 0, resetsAt: at(5 * hour))]),
        ])
        #expect(UpcomingReset.list(snapshot: next, now: at(5 * minute)).map(\.justReset) == [false])
        // 收集器停了兩天（資料過期）：重置早就過了，不標「剛重置」
        #expect(UpcomingReset.list(snapshot: s, now: at(2 * 86400)).isEmpty)
    }

    @Test func nullResetTimeAwaitsNextUse() {
        // Codex 5 小時已重置、回報沒有重置時間（下次使用才開始計時）：不在時間軸上，另列一行
        let s = UsageSnapshot(updatedAt: at(0), providers: [
            "claude": ProviderUsage(windows: [UsageWindow(id: "five_hour", label: "5 小時", usedPct: 30, resetsAt: at(2 * hour))]),
            "codex": ProviderUsage(windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: 0, resetsAt: nil),
                UsageWindow(id: "weekly", label: "每週", usedPct: 12, resetsAt: nil),  // 有用量卻沒有重置時間：狀態不明，不列
            ]),
        ])
        #expect(UpcomingReset.list(snapshot: s, now: at(0)).map(\.provider) == ["claude"])
        let waiting = UpcomingReset.awaitingStart(snapshot: s)
        #expect(waiting.map(\.provider) == ["codex"])
        #expect(waiting.map(\.window.id) == ["five_hour"])
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

    @Test func weeklyForecastIgnoresShortIntenseHistory() {
        // 剛開始收集 45 分鐘、這段用得很兇（每 5 分鐘 +1%）；每週已用 38%、經過 39% → 退回平均速度，撐得到重置
        let resetsAt = at(7 * 86400)
        let now = resetsAt.addingTimeInterval(-0.61 * 7 * 86400)
        let weekly = UsageWindow(id: "weekly", label: "每週", usedPct: 38, resetsAt: resetsAt)
        let s = UsageSnapshot(updatedAt: now, providers: ["claude": ProviderUsage(windows: [weekly])])
        let samples = (0...9).map { i in
            QuotaSample(ts: now.addingTimeInterval(Double(i - 9) * 300), provider: "claude", windowID: "weekly",
                        usedPct: 29 + Double(i), resetsAt: resetsAt)
        }
        let history = QuotaHistory(samples: samples)
        let forecast = WeeklyForecast.list(snapshot: s, history: history, now: now)
        #expect(forecast[0].outcome == .lastsUntilReset)
        #expect(!forecast[0].usesRecentRate)
        // 同一規則：每週額度不算用得太快
        #expect(UsagePace(window: weekly, provider: "claude", history: history, stale: false, now: now)?.isTooFast == false)
    }

    @Test func weeklyForecastWaitsLikeUsagePaceRightAfterReset() {
        // 剛重置 10 分鐘、用了 1%，沒有近期速度：平均速度會說 16.5 小時後用完，但與「用得太快」同一規則先不預測
        let resetsAt = at(7 * 86400)
        let now = resetsAt.addingTimeInterval(-(7 * 86400 - 600))
        let weekly = UsageWindow(id: "weekly", label: "每週", usedPct: 1, resetsAt: resetsAt)
        let s = UsageSnapshot(updatedAt: now, providers: ["claude": ProviderUsage(windows: [weekly])])
        #expect(WeeklyForecast.list(snapshot: s, history: .empty, now: now).isEmpty)
        #expect(UsagePace(window: weekly, stale: false, now: now) == nil)
        // 經過 10% 以上且照平均速度會用完：兩者一致
        let later = resetsAt.addingTimeInterval(-0.8 * 7 * 86400)
        let heavy = UsageWindow(id: "weekly", label: "每週", usedPct: 40, resetsAt: resetsAt)
        let s2 = UsageSnapshot(updatedAt: later, providers: ["claude": ProviderUsage(windows: [heavy])])
        let forecast = WeeklyForecast.list(snapshot: s2, history: .empty, now: later)
        guard case .runsOut = forecast.first?.outcome else { Issue.record("應預測用完"); return }
        #expect(UsagePace(window: heavy, stale: false, now: later)?.isTooFast == true)
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

    @Test(arguments: [("2026-03-08", 23.0), ("2026-11-01", 25.0)])
    func daylightSavingDaysKeepHoursAligned(day: String, length: Double) throws {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = la.timeZone
        formatter.formatOptions = [.withFullDate]
        let dayStart = la.startOfDay(for: try #require(formatter.date(from: day)))
        let now = la.date(byAdding: .day, value: 1, to: dayStart)!.addingTimeInterval(1800)
        let c = QuotaConsumption(provider: "claude", windowID: "five_hour", history: .empty, now: now, days: 2, calendar: la)
        // 第一天的 24 格加起來就是那天的實際長度，第二天從午夜開始
        let first = c.hours.prefix(24)
        #expect(first.first?.start == dayStart)
        #expect(c.hours[24].start == la.date(byAdding: .day, value: 1, to: dayStart))
        #expect(la.component(.hour, from: c.hours[5].start) == 5)
        let total = zip(first, c.hours.dropFirst()).reduce(0.0) { $0 + $1.1.start.timeIntervalSince($1.0.start) }
        #expect(total == length * 3600)
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
