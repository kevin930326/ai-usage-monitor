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

/// 小工具（WidgetKit）重新整理的節流。WidgetKit 每天大約只給 40～70 次重新整理，
/// App 不在前景時呼叫 `reloadAllTimelines` 也會扣次數；收集器每 5 分鐘寫一次，
/// 每次都重新整理一天會用掉約 288 次，之後的更新會被系統延後。
///
/// 規則：畫面上會看到的內容變了且距離上次至少 `minimumInterval`，或距離上次已達
/// `maximumInterval`（小於 30 分鐘的過期門檻，避免小工具因資料時間太舊而誤顯示「已過期」）。
/// 預設兩者都是 25 分鐘：一天最多 58 次，數字變動最多晚 25 分鐘反映。
public struct WidgetReloadThrottle: Sendable {
    public var minimumInterval: TimeInterval
    public var maximumInterval: TimeInterval
    public private(set) var lastReload: Date?
    private var lastSignature: [String]?

    public init(minimumInterval: TimeInterval = 25 * 60, maximumInterval: TimeInterval = 25 * 60) {
        self.minimumInterval = minimumInterval
        self.maximumInterval = maximumInterval
    }

    /// 回傳 true 時呼叫端應重新整理，並視為已重新整理。
    public mutating func shouldReload(for snapshot: UsageSnapshot, now: Date) -> Bool {
        let signature = Self.signature(of: snapshot)
        let reload: Bool
        if let lastReload {
            let elapsed = now.timeIntervalSince(lastReload)
            reload = (signature != lastSignature && elapsed >= minimumInterval) || elapsed >= maximumInterval
        } else {
            reload = true
        }
        if reload {
            lastReload = now
            lastSignature = signature
        }
        return reload
    }

    /// 小工具上看得到的內容：每個服務的錯誤、可見額度的整數百分比與重置時間。
    /// `updated_at` 不算在內，每 5 分鐘都會變。
    static func signature(of snapshot: UsageSnapshot) -> [String] {
        snapshot.orderedProviderKeys.flatMap { key -> [String] in
            guard let usage = snapshot.providers[key] else { return [] }
            if let error = usage.error { return ["\(key) error \(error)"] }
            return usage.visibleWindows.map {
                "\(key) \($0.id) \(Int($0.usedPct.rounded())) \($0.resetsAt?.timeIntervalSince1970 ?? 0)"
            }
        }
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
