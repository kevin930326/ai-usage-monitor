import Foundation

/// 設定「歷史資料」的資料庫大小與預估（ADR-0014）。
///
/// 各表目前佔用的位元組（SQLite `dbstat`，含索引）分成四類，依收集器的清理規則推算保留期間內穩定下來的大小：
/// - 額度歷史（`quota_samples`、`collector_runs`）：35 天內每 5 分鐘一筆，之後每小時一筆，保留期間後刪除
/// - 每日統計（`daily_tokens` 等以日為單位的表）：每天固定幾列，保留期間後刪除
/// - 時間窗內的表（去重紀錄、`hourly_tokens`、掃描進度）：最多 90 天，之後不再變大
/// - 其他（meta、紀錄等）：大小固定
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
    public var windowBytes: Int64 = 0
    /// 時間窗內的表目前涵蓋的天數（最早一筆去重紀錄到今天）；0 表示沒有去重紀錄，不再放大
    public var windowSpanDays: Int = 0
    public var otherBytes: Int64 = 0
    /// 額度歷史涵蓋的天數；不到 `minimumDays` 時不估算
    public var dataDays: Int = 0

    public init(fileBytes: Int64) {
        self.fileBytes = fileBytes
    }

    public enum Estimate: Equatable, Sendable {
        /// 保留期間內穩定下來的大小
        case steady(Int64)
        /// 永久保留：每年增加的大小
        case perYear(Int64)
    }

    /// `retentionDays` 為 0 表示永久保留；資料不足 `minimumDays` 天或讀不到各表大小時為 nil。
    public func estimate(retentionDays: Int) -> Estimate? {
        guard dataDays >= Self.minimumDays, quotaRows > 0 else { return nil }
        let quotaPerRow = Double(quotaBytes) / Double(quotaRows)
        let quotaPerDay = quotaPerRow * quotaRowsPerDay
        let dailyPerDay = dailyDays > 0 ? Double(dailyBytes) / Double(dailyDays) : 0
        guard retentionDays > 0 else {
            return .perYear(Int64((quotaPerDay / Self.downsampleRatio + dailyPerDay) * 365))
        }
        let days = Double(retentionDays)
        let recent = min(days, Double(Self.downsampleAfterDays))
        let quota = quotaPerDay * (recent + (days - recent) / Self.downsampleRatio)
        let grow = windowSpanDays > 0 ? max(1, Double(Self.windowDays) / Double(windowSpanDays)) : 1
        let window = Double(windowBytes) * grow
        return .steady(Int64(quota + dailyPerDay * days + window) + otherBytes)
    }
}
