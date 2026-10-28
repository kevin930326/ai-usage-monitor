import Foundation

/// 額度預測（ADR-0018 第 1 節）：照近期速度推算「約幾點幾分用完」，以及比過去 7 天同時段快幾倍。
/// 只在資料足夠、而且會在重置前用完時才有值；資料不足時不退回平均速度（不猜）。
/// 同一套規則在 `UsageCore/QuotaForecast.cs` 與收集器的 `forecast.py`，`fixtures/forecast/` 三邊跑同一份 golden。
public struct QuotaForecast: Hashable, Sendable, Codable {
    /// 距離用完不到這麼久算緊急（紅色）
    public static let urgentWithin: TimeInterval = 3600
    /// 比平常快這麼多倍以上才顯示倍數
    public static let fasterThreshold = 1.5
    /// 平常幾乎沒用時倍數沒有意義：最多 10（畫面寫「10 倍以上」）
    public static let fasterCap = 10.0
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
        // 以最後一筆樣本的時間為起點：兩次收集之間不會每分鐘往後漂一分鐘（畫面每分鐘重算）
        let base = history.samples(provider: provider, windowID: window.id).last { $0.ts <= now }?.ts ?? now
        let at = base.addingTimeInterval((100 - used) / rate)
        guard at > now, at < resetsAt else { return nil }
        exhaustsAt = at
        urgent = at.timeIntervalSince(now) < Self.urgentWithin
        faster = history.usualRate(provider: provider, windowID: window.id, now: now).flatMap { usual in
            guard usual > 0 else { return nil }
            let ratio = (rate / usual * 10).rounded(.down) / 10
            return ratio >= Self.fasterThreshold ? min(ratio, Self.fasterCap) : nil
        }
    }
}

public extension QuotaForecast {
    /// 畫面用的預測：有本機歷史（Mac 面板，空的也算）時只用自己算的，算不出來就不顯示（資料不足時不猜，不退回快照；Codex C-02）；
    /// 沒有歷史（iPhone、瀏海與角色不讀資料庫）時用收集器寫在快照裡的（同一套規則，最多 5 分鐘前）。
    /// 快照的過期、已經過了、或不在重置前的不用，緊急與否照現在的時間重算
    static func current(window: UsageWindow, provider: String, history: QuotaHistory?, stale: Bool, now: Date) -> QuotaForecast? {
        if let history {
            return QuotaForecast(window: window, provider: provider, history: history, stale: stale, now: now)
        }
        guard !stale, !window.hidden, var forecast = window.forecast, forecast.exhaustsAt > now,
              let resetsAt = window.resetsAt, forecast.exhaustsAt < resetsAt, window.effectiveUsedPct(at: now) < 100 else {
            return nil
        }
        forecast.urgent = forecast.exhaustsAt.timeIntervalSince(now) < urgentWithin
        return forecast
    }
}

public extension QuotaForecast {
    /// 「照目前速度約 14:32 用完」；不是今天時「照目前速度約明天 09:05 用完」「…約週五 18:00 用完」（本機時區）
    func text(now: Date, calendar: Calendar = .current) -> String {
        let clock = Self.clock(exhaustsAt, now: now, calendar: calendar)
        return "照目前速度約\(clock.first?.isNumber == true ? " " : "")\(clock) 用完"
    }

    /// 「比平常快 2.1 倍」「比平常快 10 倍以上」；沒有倍數時 nil
    var fasterText: String? {
        faster.map { "比平常快 \(Self.times($0))" }
    }

    /// 「2.1 倍」；到上限時「10 倍以上」
    static func times(_ faster: Double) -> String {
        faster >= fasterCap ? "\(Int(fasterCap)) 倍以上" : "\(String(format: "%.1f", faster)) 倍"
    }

    /// 瀏海與小地方的短說法：「約 14:32 用完・快 2.1 倍」
    func shortLine(now: Date, calendar: Calendar = .current) -> String {
        let clock = Self.clock(exhaustsAt, now: now, calendar: calendar)
        let head = "約\(clock.first?.isNumber == true ? " " : "")\(clock) 用完"
        return faster.map { "\(head)・快 \(Self.times($0))" } ?? head
    }

    /// 一行的完整說法：「照目前速度約 14:32 用完・比平常快 2.1 倍」
    func line(now: Date, calendar: Calendar = .current) -> String {
        [text(now: now, calendar: calendar), fasterText].compactMap { $0 }.joined(separator: "・")
    }

    /// 朗讀用：緊急只靠顏色與圖示分辨不出來，加上「不到 1 小時」
    func spokenLine(now: Date, calendar: Calendar = .current) -> String {
        line(now: now, calendar: calendar) + (urgent ? "，不到 1 小時" : "")
    }

    /// 「14:32」「明天 09:05」「週五 18:00」
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days <= 0 { return time }
        if days == 1 { return "明天 \(time)" }
        let weekday = ["週日", "週一", "週二", "週三", "週四", "週五", "週六"][calendar.component(.weekday, from: date) - 1]
        return "\(weekday) \(time)"
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
            let used = zip(span, span.dropFirst()).reduce(0.0) { sum, pair in
                Self.isReset(from: pair.0, to: pair.1) ? sum : sum + max(pair.1.usedPct - pair.0.usedPct, 0)
            }
            rates.append(used / seconds)
        }
        guard rates.count >= QuotaForecast.baselineMinimumDays else { return nil }
        rates.sort()
        let mid = rates.count / 2
        return rates.count % 2 == 1 ? rates[mid] : (rates[mid - 1] + rates[mid]) / 2
    }
}
