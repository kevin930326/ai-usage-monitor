import Foundation
import Testing
@testable import UsageKit

@Suite struct TokenStatsTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }

    /// 2026-11-05（星期四）15:00 台北
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 15))! }

    func row(_ day: String, _ provider: String = "claude", main: Int64, cacheRead: Int64 = 0, model: String = "claude-opus-5-5",
             longest: Int = 0) -> TokenDayRow {
        TokenDayRow(day: day, provider: provider, model: model,
                    counts: TokenCounts(input: main / 2, cacheWrite: main / 4, cacheRead: cacheRead, output: main - main / 2 - main / 4),
                    taskCount: longest > 0 ? 1 : 0, taskSeconds: longest, longestTaskSeconds: longest)
    }

    @Test func mainNumberExcludesCacheReadAndReasoning() {
        let c = TokenCounts(input: 10, cacheWrite: 20, cacheRead: 1000, output: 30, reasoning: 5)
        #expect(c.main == 60)
        #expect((c + c).cacheRead == 2000)
    }

    @Test func thisWeekComparesWithSamePeriodLastWeek() {
        // 本週一 11/2 起；上週同期 10/26～10/29
        let data = TokenStatsData(days: [
            row("2026-11-02", main: 100), row("2026-11-05", main: 50), row("2026-11-05", "codex", main: 50, model: "gpt-6.1-sol"),
            row("2026-11-01", main: 999),  // 上週日：不屬於本週，也不在上週同期
            row("2026-10-26", main: 80), row("2026-10-29", main: 20), row("2026-10-30", main: 500),
        ], firstScanDone: true)
        let all = TokenSummary(data: data, scope: .all, now: now, calendar: cal)
        #expect(all.thisWeek.main == 200)
        #expect(all.lastWeekSamePeriod == 100)
        #expect(all.changePct == 100)
        let codex = TokenSummary(data: data, scope: .codex, now: now, calendar: cal)
        #expect(codex.thisWeek.main == 50)
        #expect(codex.changePct == nil)
    }

    @Test func recordsWinOverComputedAndScopeUsesSuffix() {
        let data = TokenStatsData(days: [row("2026-11-04", main: 300, longest: 120)], records: [
            "best_day_tokens": TokenRecord(value: 5000, day: "2026-01-01"),
            "best_day_tokens:codex": TokenRecord(value: 40, day: "2026-02-02"),
            "total_tokens": TokenRecord(value: 123_456),
            "longest_task_seconds": TokenRecord(value: 60, day: "2026-03-03"),
        ])
        let all = TokenSummary(data: data, scope: .all, now: now, calendar: cal)
        #expect(all.bestDay == TokenRecord(value: 5000, day: "2026-01-01"))
        #expect(all.total?.value == 123_456)
        // 收集器的紀錄較小時（例如還沒更新）以每日資料為準
        #expect(all.longestTaskSeconds == TokenRecord(value: 120, day: "2026-11-04"))
        let claude = TokenSummary(data: data, scope: .claude, now: now, calendar: cal)
        #expect(claude.bestDay == TokenRecord(value: 300, day: "2026-11-04"))
    }

    @Test func streakCountsTodayOrUntilYesterday() {
        let days = ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04"].map { row($0, main: 10) }
        var data = TokenStatsData(days: days, records: ["longest_streak_days": TokenRecord(value: 3, day: "2026-10-10")])
        var summary = TokenSummary(data: data, scope: .all, now: now, calendar: cal)
        #expect(summary.currentStreak == 4)  // 今天還沒用：算到昨天
        #expect(summary.streakIsRecord)
        #expect(summary.longestStreak?.value == 4)
        data.days.append(row("2026-11-05", main: 1))
        summary = TokenSummary(data: data, scope: .all, now: now, calendar: cal)
        #expect(summary.currentStreak == 5)
        data.days.removeAll { $0.day == "2026-11-04" }
        summary = TokenSummary(data: data, scope: .all, now: now, calendar: cal)
        #expect(summary.currentStreak == 1)
        #expect(!summary.streakIsRecord)
        #expect(TokenSummary(data: .empty, scope: .all, now: now, calendar: cal).currentStreak == 0)
    }

    @Test func streakUsesRetentionFreeDays() {
        // 保留 7 天：每日資料只剩最近幾天，record_days 還有更早的
        let data = TokenStatsData(days: [row("2026-11-04", main: 5), row("2026-11-05", main: 5)],
                                  recordDays: ["2026-11-01": ["codex": 3], "2026-11-02": ["claude": 1], "2026-11-03": ["claude": 2],
                                               "2026-11-04": ["claude": 5], "2026-11-05": ["claude": 5]])
        #expect(TokenSummary(data: data, scope: .all, now: now, calendar: cal).currentStreak == 5)
        #expect(TokenSummary(data: data, scope: .claude, now: now, calendar: cal).currentStreak == 4)
    }

    @Test func streakLongerThanAYear() {
        // record_days 不受保留期間與圖表範圍限制：連續 400 天
        var days: [String: [String: Int64]] = [:]
        for back in 0..<400 {
            days[TokenCalendar.key(now.addingTimeInterval(-Double(back) * 86400), calendar: cal)] = ["claude": 1]
        }
        let data = TokenStatsData(recordDays: days, retentionDays: 7)
        #expect(TokenSummary(data: data, scope: .all, now: now, calendar: cal).currentStreak == 400)
        #expect(TokenSummary(data: data, scope: .codex, now: now, calendar: cal).currentStreak == 0)
    }

    @Test func activityBars() {
        let data = TokenStatsData(days: [
            row("2026-11-05", main: 40), row("2026-11-05", "codex", main: 60, model: "gpt-6.1-sol"),
            row("2026-10-07", main: 7),  // 30 天的第一天
            row("2026-10-06", main: 1000),  // 30 天之外
        ], records: ["total_tokens": TokenRecord(value: 5000)])
        let days = TokenActivity.bars(data: data, scope: .all, range: .days30, now: now, calendar: cal)
        #expect(days.count == 30)
        #expect(days.last?.main == 100)
        #expect(days.last?.byProvider == ["claude": 40, "codex": 60])
        #expect(days.first?.main == 7)
        let weeks = TokenActivity.bars(data: data, scope: .all, range: .weeks, now: now, calendar: cal)
        #expect(weeks.count == 12)
        #expect(TokenCalendar.key(weeks.last!.start, calendar: cal) == "2026-11-02")
        #expect(weeks.last?.main == 100)
        // 累計：最後一天等於 records 的累計，往回扣掉之後每天的用量
        let cumulative = TokenActivity.bars(data: data, scope: .all, range: .cumulative, now: now, calendar: cal)
        #expect(cumulative.last?.main == 5000)
        #expect(cumulative[28].main == 4900)
        #expect(cumulative.first?.main == 4900)
        #expect(cumulative.map(\.main) == cumulative.map(\.main).sorted())
    }

    @Test func heatmapShapeLevelsAndFuture() {
        let data = TokenStatsData(days: [
            row("2026-11-05", main: 400), row("2026-11-04", main: 100), row("2026-11-03", main: 200), row("2026-11-02", main: 300),
        ])
        let map = TokenHeatmap(data: data, scope: .all, now: now, weeks: 22, calendar: cal)
        #expect(map.cells.count == 22 * 7)
        #expect(TokenCalendar.key(map.firstMonday, calendar: cal) == "2026-06-08")
        let lastWeek = map.cells.suffix(7)
        #expect(Array(lastWeek) == [300, 200, 100, 400, nil, nil, nil])
        #expect(map.level(0) == 0)
        #expect(map.level(100) == 1)
        #expect(map.level(200) == 2)
        #expect(map.level(300) == 4)
        #expect(map.level(400) == 5)
        #expect(TokenCalendar.key(map.date(column: 21, row: 3, calendar: cal), calendar: cal) == "2026-11-05")
    }

    @Test func modelsAndHours() {
        let data = TokenStatsData(days: [
            row("2026-11-05", main: 10, model: "claude-sonnet-5-5"), row("2026-11-04", main: 30),
            row("2026-11-04", "codex", main: 20, model: "gpt-6.1-sol"),
        ], hours: [
            TokenHourRow(day: "2026-11-05", hour: 9, provider: "claude", model: "x", counts: TokenCounts(input: 5)),
            TokenHourRow(day: "2026-11-04", hour: 9, provider: "codex", model: "x", counts: TokenCounts(output: 7)),
            TokenHourRow(day: "2026-11-04", hour: 23, provider: "claude", model: "x", counts: TokenCounts(cacheRead: 99)),
        ])
        #expect(TokenBreakdown.models(data: data, scope: .all).map(\.model) == ["claude-opus-5-5", "gpt-6.1-sol", "claude-sonnet-5-5"])
        #expect(TokenBreakdown.models(data: data, scope: .codex).map(\.model) == ["gpt-6.1-sol"])
        // 兩家都有白名單外的模型（other）：各自一列、帶自己的服務
        let others = TokenStatsData(days: [TokenDayRow(day: "2026-11-05", provider: "claude", model: "other", counts: TokenCounts(input: 30)),
                                           TokenDayRow(day: "2026-11-05", provider: "codex", model: "other", counts: TokenCounts(input: 20))])
        #expect(TokenBreakdown.models(data: others, scope: .all).map(\.id) == ["claude/other", "codex/other"])
        #expect(TokenBreakdown.models(data: others, scope: .claude).map(\.provider) == ["claude"])
        let hours = TokenBreakdown.hours(data: data, scope: .all)
        #expect(hours[9] == 12)
        #expect(hours[23] == 0)
        #expect(TokenBreakdown.hours(data: data, scope: .claude)[9] == 5)
    }

    @Test func providersAndHasData() {
        #expect(!TokenStatsData.empty.hasData)
        let onlyRecords = TokenStatsData(records: ["total_tokens": TokenRecord(value: 9), "total_tokens:codex": TokenRecord(value: 9)])
        #expect(onlyRecords.hasData)
        #expect(onlyRecords.providers == ["codex"])
    }

    @Test func formatting() {
        // 萬／億、三位有效數字；不到一萬顯示整數
        #expect(TokenFormat.short(0) == "0")
        #expect(TokenFormat.short(980) == "980")
        #expect(TokenFormat.short(9_999) == "9,999")
        #expect(TokenFormat.short(10_000) == "1萬")
        #expect(TokenFormat.short(12_345) == "1.23萬")
        #expect(TokenFormat.short(15_000) == "1.5萬")
        #expect(TokenFormat.short(123_456) == "12.3萬")
        #expect(TokenFormat.short(4_560_000) == "456萬")
        #expect(TokenFormat.short(14_700_000) == "1,470萬")
        #expect(TokenFormat.short(14_749_999) == "1,470萬")
        #expect(TokenFormat.short(99_950_000) == "1億")  // 9,995 萬四捨五入進位到 1 億
        #expect(TokenFormat.short(99_940_000) == "9,990萬")
        #expect(TokenFormat.short(385_000_000) == "3.85億")
        #expect(TokenFormat.short(1_234_567_890) == "12.3億")
        #expect(TokenFormat.short(123_456_789_012) == "1,230億")
        #expect(TokenFormat.short(-12_345) == "-1.23萬")
        // 剛好一半的值一律進位（浮點的 9.995、1.005 曾經往下捨）
        #expect(TokenFormat.short(99_950) == "10萬")
        #expect(TokenFormat.short(10_050) == "1.01萬")
        #expect(TokenFormat.short(12_350) == "1.24萬")
        #expect(TokenFormat.short(999_500) == "100萬")
        #expect(TokenFormat.short(9_995_000) == "1,000萬")
        #expect(TokenFormat.short(Int64.max) == "92,200,000,000億")
        #expect(TokenFormat.short(Int64.min) == "-92,200,000,000億")
        #expect(TokenFormat.full(12_345_678) == "12,345,678")
        #expect(TokenFormat.duration(30) == "30 秒")
        #expect(TokenFormat.duration(45 * 60) == "45 分")
        #expect(TokenFormat.duration(3600 + 23 * 60) == "1 小時 23 分")
        #expect(TokenFormat.duration(7200) == "2 小時")
    }

    @Test func tokenCSVKeepsFourTokenKindsSeparate() {
        let rows = [
            TokenDayRow(day: "2026-10-24", provider: "codex", model: "gpt-5.5",
                        counts: TokenCounts(input: 10, cacheWrite: 0, cacheRead: 900, output: 40, reasoning: 12),
                        taskCount: 2, taskSeconds: 300, longestTaskSeconds: 200),
            TokenDayRow(day: "2026-10-23", provider: "claude", model: "claude-opus-5-5",
                        counts: TokenCounts(input: 1, cacheWrite: 2, cacheRead: 3, output: 4), taskCount: 1, taskSeconds: 60, longestTaskSeconds: 60),
            TokenDayRow(day: "2026-10-24", provider: "claude", model: "other", counts: TokenCounts(input: 5)),
        ]
        let lines = TokenCSV.make(rows: rows).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "day,provider,model,input_tokens,cache_write_tokens,cache_read_tokens,output_tokens,reasoning_tokens,task_count,task_seconds,longest_task_seconds")
        #expect(lines[1] == "2026-10-23,claude,claude-opus-5-5,1,2,3,4,0,1,60,60")
        #expect(lines[2] == "2026-10-24,claude,other,5,0,0,0,0,0,0,0")
        #expect(lines[3] == "2026-10-24,codex,gpt-5.5,10,0,900,40,12,2,300,200")
        #expect(lines.count == 5 && lines[4].isEmpty)
        #expect(TokenCSV.make(rows: []) == TokenCSV.header)
    }

    @Test func otherCalendarsUseGregorianDayKeys() {
        // 使用者選民國曆或佛曆：資料庫的日期鍵仍是西元
        for id in [Calendar.Identifier.republicOfChina, .buddhist, .japanese] {
            var other = Calendar(identifier: id)
            other.timeZone = cal.timeZone
            #expect(TokenCalendar.key(now, calendar: other) == "2026-11-05")
            #expect(TokenCalendar.date("2026-11-02", calendar: other) == TokenCalendar.date("2026-11-02", calendar: cal))
            let data = TokenStatsData(days: [row("2026-11-02", main: 100), row("2026-11-04", main: 10), row("2026-11-05", main: 5)])
            let summary = TokenSummary(data: data, scope: .all, now: now, calendar: other)
            #expect(summary.thisWeek.main == 115)
            #expect(summary.currentStreak == 2)
            #expect(TokenHeatmap(data: data, scope: .all, now: now, weeks: 22, calendar: other).cells.suffix(7).prefix(4) == [100, 0, 10, 5])
        }
    }

    @Test func dataBeforeRetentionIsUnavailableNotZero() {
        // 保留 7 天：11/5 - 7 天 = 10/29 起才有每日資料
        let data = TokenStatsData(days: [row("2026-11-05", main: 40), row("2026-10-29", main: 7)],
                                  records: ["total_tokens": TokenRecord(value: 5000)], firstScanDone: true, retentionDays: 7)
        let map = TokenHeatmap(data: data, scope: .all, now: now, weeks: 22, calendar: cal)
        #expect(map.truncated)
        let firstShown = map.cells.firstIndex { $0 != nil }!
        #expect(TokenCalendar.key(map.date(column: firstShown / 7, row: firstShown % 7, calendar: cal), calendar: cal) == "2026-10-29")
        let days = TokenActivity.bars(data: data, scope: .all, range: .days30, now: now, calendar: cal)
        #expect(days.filter(\.available).count == 8)
        #expect(!days[0].available)
        let cumulative = TokenActivity.bars(data: data, scope: .all, range: .cumulative, now: now, calendar: cal)
        #expect(cumulative.first(where: \.available)?.main == 4960)
        #expect(cumulative.last?.main == 5000)
        // 週長條：10/26 那週的 10/26～10/28 已刪除，不算完整的一週；11/2 那週完整
        let weeks = TokenActivity.bars(data: data, scope: .all, range: .weeks, now: now, calendar: cal)
        #expect(TokenCalendar.key(weeks[weeks.count - 2].start, calendar: cal) == "2026-10-26")
        #expect(!weeks[weeks.count - 2].available)
        #expect(weeks.last!.available)
        #expect(weeks.filter(\.available).count == 1)
        // 上週同期（10/26～10/29）已部分超過保留期間：不比較
        #expect(TokenSummary(data: data, scope: .all, now: now, calendar: cal).changePct == nil)
        // 永久保留：全部可用
        var forever = data
        forever.retentionDays = 0
        #expect(!TokenHeatmap(data: forever, scope: .all, now: now, weeks: 22, calendar: cal).truncated)
    }

    @Test func deletedDaysStayUnavailableAfterRetentionIsExtended() {
        // 先保留 7 天（10/29 以前已刪除），再改回 1 年或永久：10/29 以前仍然沒有資料，不能畫成 0
        for retention in [365, 0] {
            let data = TokenStatsData(days: [row("2026-11-05", main: 40), row("2026-10-29", main: 7)],
                                      records: ["total_tokens": TokenRecord(value: 5000)], firstScanDone: true,
                                      retentionDays: retention, dataFrom: "2026-10-29")
            #expect(TokenCalendar.key(data.firstAvailableDay(now: now, calendar: cal)!, calendar: cal) == "2026-10-29")
            let map = TokenHeatmap(data: data, scope: .all, now: now, weeks: 22, calendar: cal)
            #expect(map.truncated)
            let days = TokenActivity.bars(data: data, scope: .all, range: .days30, now: now, calendar: cal)
            #expect(days.filter(\.available).count == 8)
            #expect(TokenSummary(data: data, scope: .all, now: now, calendar: cal).changePct == nil)
        }
        // 刪除邊界比目前的保留期間早時，以保留期間為準
        let older = TokenStatsData(days: [row("2026-11-05", main: 40)], retentionDays: 7, dataFrom: "2026-01-01")
        #expect(TokenCalendar.key(older.firstAvailableDay(now: now, calendar: cal)!, calendar: cal) == "2026-10-29")
        // 沒有刪除過、永久保留：全部可用
        #expect(TokenStatsData(retentionDays: 0).firstAvailableDay(now: now, calendar: cal) == nil)
    }

    @Test func dayKeysRoundTrip() {
        let date = TokenCalendar.date("2026-02-28", calendar: cal)!
        #expect(TokenCalendar.key(date, calendar: cal) == "2026-02-28")
        #expect(TokenCalendar.date("bad", calendar: cal) == nil)
        #expect(TokenCalendar.key(TokenCalendar.startOfWeek(now, calendar: TokenCalendar.make(cal)), calendar: cal) == "2026-11-02")
    }
}
