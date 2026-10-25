import XCTest
@testable import UsageKit

final class HistorySizeTests: XCTestCase {
    /// 30 天的資料：額度每筆 100 B、每天 600 筆；每日統計每天 1 KB；每小時統計每天 2 KB；
    /// 個人紀錄 3 年、每天 100 B；去重紀錄 30 天 3 MB（收集器有時間窗）；其他 50 KB
    private func sample() -> HistorySize {
        var size = HistorySize(fileBytes: 6_000_000)
        size.quotaBytes = 1_800_000
        size.quotaRows = 18_000
        size.quotaRowsPerDay = 600
        size.dailyBytes = 30_000
        size.dailyDays = 30
        size.hourlyBytes = 60_000
        size.hourlyDays = 30
        size.recordBytes = 109_500
        size.recordDays = 1095
        size.seenBytes = 3_000_000
        size.seenSpanDays = 30
        size.seenBounded = true
        size.otherBytes = 50_000
        size.dataDays = 30
        return size
    }

    func testSteadySizeFollowsTheCleanupRules() {
        // 額度：60 KB/天 × (35 + 330 / 12) 天；每日統計 1 KB × 365；每小時統計 2 KB × 90；去重紀錄放大到 90 天；
        // 個人紀錄目前的大小，之後每年 100 B × 365
        let quota = 60_000.0 * (35 + 330.0 / 12)
        let steady = Int64(quota + 1_000 * 365 + 2_000 * 90 + 9_000_000) + 109_500 + 50_000
        XCTAssertEqual(sample().estimate(retentionDays: 365), .init(steady: steady, perYear: 36_500))
    }

    func testShortRetentionKeepsEveryQuotaSampleAndFewerHours() {
        // 7 天都還沒降採樣；每小時統計跟著保留期間只留 7 天；去重紀錄不跟保留期間走，仍以 90 天估算
        let steady = Int64(60_000.0 * 7 + 1_000 * 7 + 2_000 * 7 + 9_000_000) + 109_500 + 50_000
        XCTAssertEqual(sample().estimate(retentionDays: 7)?.steady, steady)
    }

    func testForeverReportsYearlyGrowth() {
        // 降採樣後的額度、每日統計與個人紀錄一直增加；每小時統計、時間窗內的去重紀錄與其他不再變大
        XCTAssertEqual(sample().estimate(retentionDays: 0),
                       .init(steady: nil, perYear: Int64((60_000.0 / 12 + 1_000 + 100) * 365)))
    }

    func testCollectorWithoutTheWindowKeepsGrowingSeenRows() {
        var size = sample()
        size.seenBounded = false  // 舊版收集器：去重紀錄一直增加（100 KB/天）
        let estimate = size.estimate(retentionDays: 365)
        let quota = 60_000.0 * (35 + 330.0 / 12)
        XCTAssertEqual(estimate?.steady, Int64(quota + 1_000 * 365 + 2_000 * 90 + 3_000_000) + 109_500 + 50_000)
        XCTAssertEqual(estimate?.perYear, Int64(100.0 * 365 + 100_000 * 365))
    }

    func testSeenRowsOlderThanTheWindowAreNotScaledDown() {
        var size = sample()
        size.seenSpanDays = 200  // 時間窗之前留下的去重紀錄，會由收集器慢慢刪掉，保守地不縮小
        let steady = Int64(60_000.0 * 7 + 1_000 * 7 + 2_000 * 7 + 3_000_000) + 109_500 + 50_000
        XCTAssertEqual(size.estimate(retentionDays: 7)?.steady, steady)
    }

    func testNoSeenRowsMeansNoScaling() {
        var size = sample()
        size.seenSpanDays = 0
        let steady = Int64(60_000.0 * 7 + 1_000 * 7 + 2_000 * 7 + 3_000_000) + 109_500 + 50_000
        XCTAssertEqual(size.estimate(retentionDays: 7)?.steady, steady)
    }

    func testTooLittleDataGivesNoEstimate() {
        var size = sample()
        size.dataDays = HistorySize.minimumDays - 1
        XCTAssertNil(size.estimate(retentionDays: 365))
        size = HistorySize(fileBytes: 4096)  // 讀不到各表大小
        size.dataDays = 30
        XCTAssertNil(size.estimate(retentionDays: 365))
    }
}
