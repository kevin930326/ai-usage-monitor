import XCTest
@testable import UsageKit

final class HistorySizeTests: XCTestCase {
    /// 30 天的資料：額度每筆 100 B、每天 600 筆；每日統計每天 1 KB；去重紀錄 30 天 3 MB；其他 50 KB
    private func sample() -> HistorySize {
        var size = HistorySize(fileBytes: 6_000_000)
        size.quotaBytes = 1_800_000
        size.quotaRows = 18_000
        size.quotaRowsPerDay = 600
        size.dailyBytes = 30_000
        size.dailyDays = 30
        size.windowBytes = 3_000_000
        size.windowSpanDays = 30
        size.otherBytes = 50_000
        size.dataDays = 30
        return size
    }

    func testSteadySizeFollowsTheCleanupRules() {
        // 額度：60 KB/天 × (35 + 330 / 12) 天；每日統計 1 KB × 365；去重紀錄放大到 90 天
        let quota = 60_000.0 * (35 + 330.0 / 12)
        let expected = Int64(quota + 1_000 * 365 + 9_000_000) + 50_000
        XCTAssertEqual(sample().estimate(retentionDays: 365), .steady(expected))
    }

    func testShortRetentionKeepsEveryQuotaSample() {
        // 7 天都還沒降採樣；去重紀錄不跟保留期間走，仍以 90 天估算
        let expected = Int64(60_000.0 * 7 + 1_000 * 7 + 9_000_000) + 50_000
        XCTAssertEqual(sample().estimate(retentionDays: 7), .steady(expected))
    }

    func testForeverReportsYearlyGrowth() {
        // 只有降採樣後的額度與每日統計會一直增加；時間窗內的表與其他不再變大
        XCTAssertEqual(sample().estimate(retentionDays: 0), .perYear(Int64((60_000.0 / 12 + 1_000) * 365)))
    }

    func testWindowTablesFullerThanTheWindowAreNotScaledDown() {
        var size = sample()
        size.windowSpanDays = 200  // 時間窗之前留下的去重紀錄，會由收集器慢慢刪掉，保守地不縮小
        let expected = Int64(60_000.0 * 7 + 1_000 * 7 + 3_000_000) + 50_000
        XCTAssertEqual(size.estimate(retentionDays: 7), .steady(expected))
    }

    func testNoSeenRowsMeansNoScaling() {
        var size = sample()
        size.windowSpanDays = 0
        let expected = Int64(60_000.0 * 7 + 1_000 * 7 + 3_000_000) + 50_000
        XCTAssertEqual(size.estimate(retentionDays: 7), .steady(expected))
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
