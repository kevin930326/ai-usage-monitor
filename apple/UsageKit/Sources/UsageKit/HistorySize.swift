import Foundation

/// 設定「歷史資料」的資料庫大小與預估（ADR-0014）。
///
/// 各表目前佔用的位元組（SQLite `dbstat`，含索引）依收集器的清理規則分類，推算保留期間內穩定下來的大小：
/// - 額度歷史（`quota_samples`、`collector_runs`）：35 天內每 5 分鐘一筆，之後每小時一筆，保留期間後刪除
/// - 每日統計（`daily_tokens`、`upload_state`）：每天固定幾列，保留期間後刪除
/// - 每小時統計（`hourly_tokens`）：保留期間與 90 天較短的一個
/// - 個人紀錄（`record_days`、`record_days_cached`）：不受保留期間影響，一直增加
/// - 去重紀錄（`seen_ids`、`seen_tasks`、`file_tokens`）：收集器有時間窗（`meta.seen_cutoff_day`）時最多 90 天，
///   舊版收集器沒有時一直增加
/// - 其他（meta、掃描進度等）：大小固定
public struct HistorySize: Equatable, Sendable {
    /// 去重紀錄與每小時統計最多留的天數（收集器的 `SEEN_DAYS`、`HOURLY_TOKENS_DAYS`）
    public static let windowDays = 90
    /// 超過這個天數的額度歷史降為每小時一筆（收集器的 `DOWNSAMPLE_AFTER_DAYS`）
    public static let downsampleAfterDays = 35
    /// 降採樣後每天的筆數約為原本的 1/12（每 5 分鐘 → 每小時）
    static let downsampleRatio = 12.0
    /// 資料不到這麼多天時不估算（剛安裝時的每日筆數不準）
    public static let minimumDays = 7

    /// 檔案實際佔用的大小（主檔＋WAL）
    public var fileBytes: Int64
    public var quotaBytes: Int64 = 0
    public var quotaRows: Int64 = 0
    /// 最近 7 天平均每天新增的額度歷史筆數
    public var quotaRowsPerDay: Double = 0
    public var dailyBytes: Int64 = 0
    /// 每日統計涵蓋的天數
    public var dailyDays: Int = 0
    public var hourlyBytes: Int64 = 0
    public var hourlyDays: Int = 0
    public var recordBytes: Int64 = 0
    /// 個人紀錄涵蓋的天數
    public var recordDays: Int = 0
    public var seenBytes: Int64 = 0
    /// 去重紀錄目前涵蓋的天數（最早一筆到今天）；0 表示沒有去重紀錄，不再放大
    public var seenSpanDays: Int = 0
    /// 收集器有去重時間窗（`meta.seen_cutoff_day`）；沒有時去重紀錄一直增加
    public var seenBounded: Bool = false
    public var otherBytes: Int64 = 0
    /// 額度歷史涵蓋的天數；不到 `minimumDays` 時不估算
    public var dataDays: Int = 0

    public init(fileBytes: Int64) {
        self.fileBytes = fileBytes
    }

    public struct Estimate: Equatable, Sendable {
        /// 保留期間內穩定下來的大小；永久保留時為 nil
        public var steady: Int64?
        /// 之後每年增加的大小（永久保留時的全部增加；有保留期間時只剩個人紀錄與沒有時間窗的去重紀錄）
        public var perYear: Int64
    }

    /// `retentionDays` 為 0 表示永久保留；資料不足 `minimumDays` 天或讀不到各表大小時為 nil。
    public func estimate(retentionDays: Int) -> Estimate? {
        guard dataDays >= Self.minimumDays, quotaRows > 0 else { return nil }
        func perDay(_ bytes: Int64, _ days: Int) -> Double { days > 0 ? Double(bytes) / Double(days) : 0 }
        let quotaPerDay = Double(quotaBytes) / Double(quotaRows) * quotaRowsPerDay
        let dailyPerDay = perDay(dailyBytes, dailyDays)
        let hourlyPerDay = perDay(hourlyBytes, hourlyDays)
        // 一直增加的部分
        var growth = perDay(recordBytes, recordDays) * 365
        if !seenBounded { growth += perDay(seenBytes, seenSpanDays) * 365 }
        // 去重紀錄：有時間窗時放大到 90 天（已超過 90 天的舊資料會被收集器慢慢刪掉，保守地不縮小）
        let seen = seenBounded && seenSpanDays > 0
            ? Double(seenBytes) * max(1, Double(Self.windowDays) / Double(seenSpanDays)) : Double(seenBytes)
        guard retentionDays > 0 else {
            let yearly = growth + (quotaPerDay / Self.downsampleRatio + dailyPerDay) * 365
            return Estimate(steady: nil, perYear: Int64(yearly))
        }
        let days = Double(retentionDays)
        let recent = min(days, Double(Self.downsampleAfterDays))
        let quota = quotaPerDay * (recent + (days - recent) / Self.downsampleRatio)
        let hourly = hourlyPerDay * Double(min(retentionDays, Self.windowDays))
        let steady = Int64(quota + dailyPerDay * days + hourly + seen) + recordBytes + otherBytes
        return Estimate(steady: steady, perYear: Int64(growth))
    }
}
