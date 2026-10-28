import Foundation

/// 額度預測（ADR-0018 第 1 節）：照近期速度推算「約幾點幾分用完」，以及比過去 7 天同時段快幾倍。
/// 只在資料足夠、而且會在重置前用完時才有值；資料不足時不退回平均速度（不猜）。
/// 同一套規則在 `UsageCore/QuotaForecast.cs` 與收集器的 `forecast.py`，`fixtures/forecast/` 三邊跑同一份 golden。
public struct QuotaForecast: Equatable, Sendable, Codable {
    /// 距離用完不到這麼久算緊急（紅色）
    public static let urgentWithin: TimeInterval = 3600
    /// 比平常快這麼多倍以上才顯示倍數
    public static let fasterThreshold = 1.5
    /// 「平常」看過去幾天、至少幾天有資料
    public static let baselineDays = 7
    public static let baselineMinimumDays = 3

    /// 預計用完的時間
    public var exhaustsAt: Date
    /// 不到 60 分鐘就用完（紅色；其他黃色）
    public var urgent: Bool
    /// 比平常快幾倍（小數一位、無條件捨去）；不到 1.5 倍或平常的資料不足時為 nil
    public var faster: Double?

    public init(exhaustsAt: Date, urgent: Bool, faster: Double? = nil) {
        self.exhaustsAt = exhaustsAt
        self.urgent = urgent
        self.faster = faster
    }

    enum CodingKeys: String, CodingKey {
        case exhaustsAt = "exhausts_at"
        case urgent, faster
    }

    /// 某個額度的預測；任何條件不符（過期、隱藏、沒有重置時間、已用完、資料不足、不會在重置前用完）為 nil
    public init?(window: UsageWindow, provider: String, history: QuotaHistory, stale: Bool, now: Date) {
        guard !stale, !window.hidden, let resetsAt = window.resetsAt, resetsAt > now,
              QuotaHistory.recentLookback(windowID: window.id) != nil else { return nil }
        let used = window.effectiveUsedPct(at: now)
        guard used < 100, let rate = history.recentRate(provider: provider, windowID: window.id, now: now), rate > 0 else {
            return nil
        }
        let at = now.addingTimeInterval((100 - used) / rate)
        guard at < resetsAt else { return nil }
        exhaustsAt = at
        urgent = at.timeIntervalSince(now) < Self.urgentWithin
        faster = history.usualRate(provider: provider, windowID: window.id, now: now).flatMap { usual in
            guard usual > 0 else { return nil }
            let ratio = (rate / usual * 10).rounded(.down) / 10
            return ratio >= Self.fasterThreshold ? ratio : nil
        }
    }
}

public extension QuotaHistory {
    /// 平常的速度：過去 7 天每一天同一段回看範圍（往前推整天數）的速度，各天的資料門檻同近期速度
    /// （至少 4 筆、跨度足夠）；至少 3 天有資料時取中位數，否則 nil。跨過重置的那一段不算消耗。
    func usualRate(provider: String, windowID: String, now: Date) -> Double? {
        guard let lookback = Self.recentLookback(windowID: windowID) else { return nil }
        let all = samples(provider: provider, windowID: windowID)
        var rates: [Double] = []
        for day in 1...QuotaForecast.baselineDays {
            let end = now.addingTimeInterval(-Double(day) * 86400)
            let span = all.filter { $0.ts >= end.addingTimeInterval(-lookback) && $0.ts <= end }
            guard span.count >= Self.recentMinimumSamples, let first = span.first, let last = span.last else { continue }
            let seconds = last.ts.timeIntervalSince(first.ts)
            guard seconds >= Self.recentMinimumSpan(windowID: windowID) else { continue }
            let consumed = zip(span, span.dropFirst()).reduce(0.0) { sum, pair in
                Self.isReset(from: pair.0, to: pair.1) ? sum : sum + max(pair.1.usedPct - pair.0.usedPct, 0)
            }
            rates.append(consumed / seconds)
        }
        guard rates.count >= QuotaForecast.baselineMinimumDays else { return nil }
        rates.sort()
        let mid = rates.count / 2
        return rates.count % 2 == 1 ? rates[mid] : (rates[mid - 1] + rates[mid]) / 2
    }
}
