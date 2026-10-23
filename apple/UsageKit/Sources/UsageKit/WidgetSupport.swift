import Foundation

public enum UsageEncoder {
    /// 與收集器輸出相同的格式（日期為 ISO 8601），`UsageDecoder.decode` 可以讀回。
    /// App 寫給小工具／複雜功能的共用檔案都用這個。
    public static func encode(_ snapshot: UsageSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }
}

public enum UsageTimelineSchedule {
    /// 小工具與錶面複雜功能的時間軸：每 15 分鐘一筆，另外在重置時間與資料過期的時間點各加一筆，
    /// 讓「已重置」與轉灰準時出現，而不是等下一個 15 分鐘（重置倒數不會先往上數）。
    /// `staleAfter` 要與畫面判斷過期用的門檻相同（複雜功能用 `UsageSnapshot.watchStaleAfter`）。
    public static func entryDates(now: Date, snapshot: UsageSnapshot?,
                                  step: TimeInterval = 15 * 60, horizon: TimeInterval = 60 * 60,
                                  staleAfter: TimeInterval = UsageSnapshot.staleAfter) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var dates = stride(from: 0, to: horizon, by: step).map { now.addingTimeInterval($0) }
        if let snapshot {
            let events = snapshot.providers.values
                .flatMap(\.visibleWindows)
                .compactMap(\.resetsAt)
                + [snapshot.updatedAt.addingTimeInterval(staleAfter)]
            dates += events.filter { $0 > now && $0 < end }
        }
        return Array(Set(dates)).sorted()
    }
}
