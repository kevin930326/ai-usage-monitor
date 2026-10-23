import Foundation

// 額度歷史的計算（FR-39～FR-42、ADR-0008 第 4 節、ADR-0009 第 4 節）。
// 資料來自收集器寫的 history.sqlite3（App 只讀，讀取層在 Mac App 的 HistoryStore）；
// 這裡只有純計算，Linux 也能測試。

/// `quota_samples` 的一列：某次收集時某個額度的已用 %。
public struct QuotaSample: Equatable, Sendable {
    public var ts: Date
    public var provider: String
    public var windowID: String
    public var usedPct: Double
    public var resetsAt: Date?

    public init(ts: Date, provider: String, windowID: String, usedPct: Double, resetsAt: Date? = nil) {
        self.ts = ts
        self.provider = provider
        self.windowID = windowID
        self.usedPct = usedPct
        self.resetsAt = resetsAt
    }
}

/// `collector_runs` 的一列。`runs > 1` 是降採樣後代表一整個小時的列（35 天前的資料）。
public struct CollectorRun: Equatable, Sendable {
    public var ts: Date
    public var ok: Int
    public var runs: Int

    public init(ts: Date, ok: Int = 1, runs: Int = 1) {
        self.ts = ts
        self.ok = ok
        self.runs = runs
    }
}

/// 一段時間（開始、結束）。不用 `DateInterval`：它的 `end` 不能早於 `start`，計算中間值時容易踩到。
public struct TimeSpan: Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func overlap(_ other: TimeSpan) -> TimeInterval {
        max(0, min(end, other.end).timeIntervalSince(max(start, other.start)))
    }
}

public struct QuotaHistory: Equatable, Sendable {
    /// 兩次收集之間超過這麼久就是「沒有紀錄」（ADR-0009 第 4 節）
    public static let gapThreshold: TimeInterval = 15 * 60
    /// `resets_at` 前後變動不到這麼多視為同一輪（Claude 的重置時間從文字解析，可能有分鐘以內的差異）
    public static let resetTolerance: TimeInterval = 10 * 60
    /// 畫圖至少要有的樣本數（ADR-0009 第 8 節：≥ 2 筆後開始畫）
    public static let minimumSamples = 2

    public var samples: [QuotaSample]
    public var runs: [CollectorRun]

    public init(samples: [QuotaSample] = [], runs: [CollectorRun] = []) {
        self.samples = samples.sorted { $0.ts < $1.ts }
        self.runs = runs.sorted { $0.ts < $1.ts }
    }

    public static let empty = QuotaHistory()

    /// 某個額度的樣本（依時間排序）。
    public func samples(provider: String, windowID: String) -> [QuotaSample] {
        samples.filter { $0.provider == provider && $0.windowID == windowID }
    }

    /// `range` 內沒有收集器紀錄的時段（Mac 睡眠、關機、收集器停止）。
    /// 降採樣的列（`runs > 1`）視為涵蓋它所在的整點到它的時間。
    public func gaps(in range: TimeSpan) -> [TimeSpan] {
        guard range.duration > 0 else { return [] }
        var covered: [TimeSpan] = runs.map { run in
            let start = run.runs > 1 ? Date(timeIntervalSince1970: floor(run.ts.timeIntervalSince1970 / 3600) * 3600) : run.ts
            return TimeSpan(start: start, end: run.ts)
        }
        covered.sort { $0.start < $1.start }
        var result: [TimeSpan] = []
        var cursor = range.start
        // 範圍開始之前最後一次收集若在門檻內，從那次開始算
        if let before = covered.last(where: { $0.end <= range.start }) { cursor = before.end }
        for span in covered where span.end > range.start {
            if span.start.timeIntervalSince(cursor) > Self.gapThreshold {
                result.append(TimeSpan(start: max(cursor, range.start), end: min(span.start, range.end)))
            }
            cursor = max(cursor, span.end)
            if cursor >= range.end { break }
        }
        if range.end.timeIntervalSince(cursor) > Self.gapThreshold {
            result.append(TimeSpan(start: max(cursor, range.start), end: range.end))
        }
        return result.filter { $0.duration > 0 }
    }

    /// 相鄰兩筆之間是否重置：`resets_at` 改變超過容許誤差，或已用 % 下降（ADR-0009 第 4 節）。
    public static func isReset(from a: QuotaSample, to b: QuotaSample) -> Bool {
        if b.usedPct < a.usedPct { return true }
        switch (a.resetsAt, b.resetsAt) {
        case let (x?, y?): return abs(y.timeIntervalSince(x)) > resetTolerance
        case (nil, nil): return false
        default: return true
        }
    }

    /// 最後一次重置之後（目前這一輪）的樣本。
    public static func currentCycle(_ samples: [QuotaSample]) -> [QuotaSample] {
        guard let lastReset = samples.indices.dropFirst().last(where: { isReset(from: samples[$0 - 1], to: samples[$0]) }) else {
            return samples
        }
        return Array(samples[lastReset...])
    }
}

// MARK: - 近期速度（ADR-0009 第 4 節）

public extension QuotaHistory {
    /// 近期速度要看多久：5 小時額度看最近 60 分鐘、每週額度看最近 24 小時；其他長度不用近期速度。
    static func recentLookback(windowID: String) -> TimeInterval? {
        if windowID == "five_hour" { return 3600 }
        if windowID == "weekly" || windowID.hasPrefix("weekly_") { return 86400 }
        return nil
    }

    static let recentMinimumSamples = 4

    /// 近期速度至少要涵蓋多久：5 小時額度 30 分鐘；每週額度 12 小時（幾十分鐘的密集使用不能代表一整週）。
    static func recentMinimumSpan(windowID: String) -> TimeInterval {
        windowID == "five_hour" ? 30 * 60 : 12 * 3600
    }

    /// 近期速度（每秒消耗的百分點）：同一輪、回看範圍內至少 4 筆，且跨度達 `recentMinimumSpan`；
    /// 不足時為 nil（退回本額度開始至今的平均速度）。「用得太快」「約 N 分鐘後用完」「可撐到星期幾」都用這個規則。
    /// 回看範圍內有「沒有紀錄」的時段也照算：速度是兩端的差除以時間，睡眠期間沒有使用本來就該拉低速度。
    func recentRate(provider: String, windowID: String, now: Date) -> Double? {
        guard let lookback = Self.recentLookback(windowID: windowID) else { return nil }
        let cycle = Self.currentCycle(samples(provider: provider, windowID: windowID))
        let recent = cycle.filter { $0.ts >= now.addingTimeInterval(-lookback) && $0.ts <= now }
        guard recent.count >= Self.recentMinimumSamples, let first = recent.first, let last = recent.last else { return nil }
        let span = last.ts.timeIntervalSince(first.ts)
        guard span >= Self.recentMinimumSpan(windowID: windowID) else { return nil }
        return max(last.usedPct - first.usedPct, 0) / span
    }
}

public extension UsagePace {
    /// 有歷史時的用量節奏：以近期速度估計用完的時間，會在重置前用完就是「用得太快」；
    /// 近期速度不足時退回平均速度（與 `init(window:stale:now:)` 相同）。
    init?(window: UsageWindow, provider: String, history: QuotaHistory, stale: Bool, now: Date) {
        guard let base = UsagePace(window: window, stale: stale, now: now) else { return nil }
        guard let rate = history.recentRate(provider: provider, windowID: window.id, now: now),
              let resetsAt = window.resetsAt else {
            self = base
            return
        }
        let used = window.effectiveUsedPct(at: now)
        let exhausts: Date?
        if used >= 100 {
            exhausts = now
        } else if rate > 0 {
            let at = now.addingTimeInterval((100 - used) / rate)
            exhausts = at < resetsAt ? at : nil
        } else {
            exhausts = nil  // 最近沒有在用：照目前速度不會用完
        }
        self.init(aheadBy: base.aheadBy, exhaustsAt: exhausts)
    }
}

// MARK: - 建議接下來用（FR-39）

/// 某服務剩餘最少的額度剩 < 20%，且另一服務對應的額度剩 ≥ 50% 時，建議另一個服務（ADR-0008 第 2 節）。
public struct NextProviderSuggestion: Equatable, Sendable {
    public static let lowThreshold: Double = 20
    public static let plentyThreshold: Double = 50

    /// 建議改用的服務
    public var provider: String
    /// 建議服務中用來比較的額度與剩餘 %
    public var window: UsageWindow
    public var remainingPct: Double
    /// 快用完的服務
    public var exhaustedProvider: String

    /// 資料過期、只有一個服務、兩者都充足時為 nil（不顯示、不占空間）。
    /// 「對應的額度」是同 id 的額度（5 小時對 5 小時）；建議的服務沒有同 id 的額度時用它剩最少的額度。
    /// 另外要求建議的服務本身沒有任何額度剩不到 20%，避免建議一個每週額度也快用完的服務。
    public init?(snapshot: UsageSnapshot, now: Date) {
        guard !snapshot.isStale(now: now) else { return nil }
        let healthy = snapshot.orderedProviderKeys.compactMap { key -> (String, [UsageWindow])? in
            guard let p = snapshot.providers[key], p.error == nil, !p.visibleWindows.isEmpty else { return nil }
            return (key, p.visibleWindows)
        }
        guard healthy.count >= 2 else { return nil }
        func least(_ windows: [UsageWindow]) -> UsageWindow? {
            windows.min { $0.effectiveRemainingPct(at: now) < $1.effectiveRemainingPct(at: now) }
        }
        // 剩最少的服務優先（依服務順序決定同分）
        let ranked = healthy.compactMap { key, windows in least(windows).map { (key, windows, $0) } }
            .sorted { $0.2.effectiveRemainingPct(at: now) < $1.2.effectiveRemainingPct(at: now) }
        guard let low = ranked.first, low.2.effectiveRemainingPct(at: now) < Self.lowThreshold else { return nil }
        for (key, windows, tightest) in ranked.dropFirst() {
            guard tightest.effectiveRemainingPct(at: now) >= Self.lowThreshold else { continue }
            let counterpart = windows.first { $0.id == low.2.id } ?? tightest
            let remaining = counterpart.effectiveRemainingPct(at: now)
            if remaining >= Self.plentyThreshold {
                provider = key
                window = counterpart
                remainingPct = remaining
                exhaustedProvider = low.0
                return
            }
        }
        return nil
    }
}

// MARK: - 接下來的重置與每週預測（FR-40）

public struct UpcomingReset: Equatable, Sendable {
    public var provider: String
    public var window: UsageWindow
    public var resetsAt: Date
    /// 在時間軸上的位置（0＝現在，1＝8 小時後）
    public var position: Double

    /// 未來 `horizon` 內會重置的可見額度，依時間排序（有錯誤的服務、已重置的額度不列）。
    public static func list(snapshot: UsageSnapshot, now: Date, horizon: TimeInterval = 8 * 3600) -> [UpcomingReset] {
        snapshot.orderedProviderKeys.flatMap { key -> [UpcomingReset] in
            guard let p = snapshot.providers[key], p.error == nil else { return [] }
            return p.visibleWindows.compactMap { w in
                guard let at = w.resetsAt, at > now, at.timeIntervalSince(now) <= horizon else { return nil }
                return UpcomingReset(provider: key, window: w, resetsAt: at, position: at.timeIntervalSince(now) / horizon)
            }
        }
        .sorted { $0.resetsAt < $1.resetsAt }
    }
}

/// 「照目前速度，每週額度可撐到星期幾」。
public struct WeeklyForecast: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// 照目前速度在重置前用完
        case runsOut(Date)
        /// 撐得到重置
        case lastsUntilReset
    }

    public var provider: String
    public var window: UsageWindow
    public var resetsAt: Date
    public var outcome: Outcome
    /// 是否用了近期速度（否則是本額度開始至今的平均速度）
    public var usesRecentRate: Bool

    /// 每個服務的 `weekly` 額度一筆；資料過期、重置時間不明或已重置時不列。
    public static func list(snapshot: UsageSnapshot, history: QuotaHistory, now: Date) -> [WeeklyForecast] {
        guard !snapshot.isStale(now: now) else { return [] }
        return snapshot.orderedProviderKeys.compactMap { key in
            guard let p = snapshot.providers[key], p.error == nil,
                  let w = p.visibleWindows.first(where: { $0.id == "weekly" }),
                  let resetsAt = w.resetsAt, !w.isReset(at: now) else { return nil }
            let used = w.effectiveUsedPct(at: now)
            let recent = history.recentRate(provider: key, windowID: w.id, now: now)
            var rate = recent
            if rate == nil, let elapsed = w.elapsedFraction(at: now), let duration = w.duration, elapsed > 0 {
                rate = used / (elapsed * duration)
            }
            let outcome: Outcome
            if used >= 100 {
                outcome = .runsOut(now)
            } else if let rate, rate > 0, now.addingTimeInterval((100 - used) / rate) < resetsAt {
                outcome = .runsOut(now.addingTimeInterval((100 - used) / rate))
            } else {
                outcome = .lastsUntilReset
            }
            return WeeklyForecast(provider: key, window: w, resetsAt: resetsAt, outcome: outcome, usesRecentRate: recent != nil)
        }
    }

    /// 「週五晚上」：星期＋時段（凌晨 0–6、早上 6–12、下午 12–18、晚上 18–24），本機時區。
    public static func dayPart(_ date: Date, calendar: Calendar = .current) -> String {
        let weekday = ["週日", "週一", "週二", "週三", "週四", "週五", "週六"][calendar.component(.weekday, from: date) - 1]
        let hour = calendar.component(.hour, from: date)
        let part = hour < 6 ? "凌晨" : hour < 12 ? "早上" : hour < 18 ? "下午" : "晚上"
        return weekday + part
    }
}

// MARK: - 本週額度走勢（FR-41）

public struct QuotaTrend: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var ts: Date
        public var remainingPct: Double
    }

    /// 這一輪的開始與結束（重置時間）；x 軸的範圍
    public var span: TimeSpan
    /// 這一輪的剩餘 %（依時間排序），最後一點是現在的值
    public var points: [Point]
    /// 沒有紀錄的時段（斜線）
    public var gaps: [TimeSpan]

    public var hasEnoughData: Bool { points.count >= QuotaHistory.minimumSamples }

    /// 照時間的預期剩餘 %（虛線）：開始時 100%，重置時 0%。
    public func expectedRemaining(at date: Date) -> Double {
        guard span.duration > 0 else { return 100 }
        return 100 * (1 - min(max(date.timeIntervalSince(span.start) / span.duration, 0), 1))
    }

    /// 選定額度的走勢。額度長度或重置時間不明時以最近 7 天為範圍、不畫預期。
    public init(provider: String, window: UsageWindow, history: QuotaHistory, now: Date) {
        let end: Date
        let start: Date
        if let resetsAt = window.resetsAt, let duration = window.duration, !window.isReset(at: now) {
            end = resetsAt
            start = resetsAt.addingTimeInterval(-duration)
        } else {
            end = now
            start = now.addingTimeInterval(-7 * 86400)
        }
        span = TimeSpan(start: start, end: end)
        let cycle = QuotaHistory.currentCycle(history.samples(provider: provider, windowID: window.id))
        points = cycle.filter { $0.ts >= start && $0.ts <= now }
            .map { Point(ts: $0.ts, remainingPct: min(max(100 - $0.usedPct, 0), 100)) }
        gaps = history.gaps(in: TimeSpan(start: start, end: min(now, end)))
    }
}

// MARK: - 額度消耗（FR-42，ADR-0011 第一層）

/// 每小時消耗的額度 %：同一額度相鄰兩筆的正差值；重置時以新值計，並只分到重置時間之後（ADR-0009 第 4 節）。
/// 兩筆之間超過 15 分鐘（沒有紀錄）時，差值平均分配到這段時間並標成「估計」；
/// 這段時間中有重置時不分配（不知道重置前後各用了多少），那幾個小時標成「沒有紀錄」。
public struct QuotaConsumption: Equatable, Sendable {
    public struct Hour: Equatable, Sendable {
        /// 這個小時的開始（本機時區的整點）
        public var start: Date
        /// 消耗的百分點；`nil`＝沒有紀錄
        public var consumed: Double?
        /// 含平均分配的估計值（畫斜線）
        public var estimated: Bool
    }

    /// 依時間排序的每小時資料，涵蓋 `days` 天（今天在最後）
    public var hours: [Hour]
    public var days: Int
    /// 範圍內這個額度的樣本數
    public var sampleCount: Int

    /// 至少 2 筆樣本才畫（ADR-0009 第 8 節），否則顯示骨架畫面
    public var hasEnoughData: Bool { sampleCount >= QuotaHistory.minimumSamples && hours.contains { $0.consumed != nil } }

    /// 每天的合計（`days` 筆，今天在最後）；整天都沒有紀錄時為 nil。
    public var dailyTotals: [(start: Date, consumed: Double?, estimated: Bool)] {
        stride(from: 0, to: hours.count, by: 24).map { i in
            let day = hours[i..<min(i + 24, hours.count)]
            let known = day.compactMap(\.consumed)
            return (day.first!.start, known.isEmpty ? nil : known.reduce(0, +), day.contains { $0.estimated })
        }
    }

    public init(provider: String, windowID: String, history: QuotaHistory, now: Date, days: Int = 7, calendar: Calendar = .current) {
        self.days = days
        let todayStart = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        // 每個本機日期固定 24 格（第 h 格＝當天 h 點開始到下一格開始），日期與小時才不會錯位。
        // 日光節約時間開始那天不存在的小時是 0 長度的格子；結束那天重複的小時併在同一格（2 小時）。
        var spans: [TimeSpan] = []
        for day in 0..<days {
            let dayStart = calendar.date(byAdding: .day, value: day, to: first) ?? first.addingTimeInterval(Double(day) * 86400)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            let starts = (0..<24).map { h in
                h == 0 ? dayStart : calendar.date(bySettingHour: h, minute: 0, second: 0, of: dayStart) ?? dayStart.addingTimeInterval(Double(h) * 3600)
            } + [nextDay]
            for h in 0..<24 {
                let start = min(starts[h], nextDay)
                spans.append(TimeSpan(start: start, end: max(min(starts[h + 1], nextDay), start)))
            }
        }
        var consumed = [Double?](repeating: nil, count: spans.count)
        var estimated = [Bool](repeating: false, count: spans.count)
        var unknown = [Bool](repeating: false, count: spans.count)
        let range = TimeSpan(start: first, end: now)

        // 有收集紀錄的時段才算「有紀錄」，沒有使用時是 0
        for (i, span) in spans.enumerated() where span.start < now && span.duration > 0 {
            let observed = TimeSpan(start: span.start, end: min(span.end, now))
            let missing = history.gaps(in: observed).reduce(0) { $0 + $1.duration }
            if missing < observed.duration { consumed[i] = 0 }
        }

        let series = history.samples(provider: provider, windowID: windowID)
        sampleCount = series.filter { $0.ts >= range.start }.count
        for (a, b) in zip(series, series.dropFirst()) where b.ts > range.start {
            let segment = TimeSpan(start: a.ts, end: b.ts)
            let reset = QuotaHistory.isReset(from: a, to: b)
            let delta = reset ? max(b.usedPct, 0) : max(b.usedPct - a.usedPct, 0)
            let isGap = segment.duration > QuotaHistory.gapThreshold
            if isGap && reset {
                // 空檔中有重置：不分配，這段時間標成沒有紀錄
                for (i, span) in spans.enumerated() where span.overlap(segment) > 0 { unknown[i] = true }
                continue
            }
            // 重置時間落在兩筆之間：新一輪的用量只分到重置之後（不算進重置前的小時或前一天）
            var allocation = segment
            if reset, let resetsAt = a.resetsAt, resetsAt > a.ts, resetsAt < b.ts {
                allocation = TimeSpan(start: resetsAt, end: b.ts)
            }
            guard allocation.duration > 0 else { continue }
            for (i, span) in spans.enumerated() {
                let overlap = span.overlap(allocation)
                guard overlap > 0 else { continue }
                consumed[i] = (consumed[i] ?? 0) + delta * overlap / allocation.duration
                if isGap { estimated[i] = true }
            }
        }
        hours = spans.indices.map { i in
            if unknown[i] { return Hour(start: spans[i].start, consumed: nil, estimated: false) }
            return Hour(start: spans[i].start, consumed: consumed[i], estimated: estimated[i] && consumed[i] != nil)
        }
    }
}

// MARK: - 匯出 CSV（FR-37）

public enum QuotaHistoryCSV {
    /// 每小時的額度歷史：每個額度每小時保留最後一筆（與收集器的降採樣規則相同），欄位同 `quota_samples`。
    /// `ts`、`resets_at` 為 Unix 秒（UTC），與資料表相同。
    public static func make(samples: [QuotaSample]) -> String {
        var last: [String: QuotaSample] = [:]
        for s in samples {
            let hour = Int(floor(s.ts.timeIntervalSince1970 / 3600))
            let key = "\(s.provider)\u{1F}\(s.windowID)\u{1F}\(hour)"
            if let existing = last[key], existing.ts > s.ts { continue }
            last[key] = s
        }
        let rows = last.values.sorted { ($0.ts, $0.provider, $0.windowID) < ($1.ts, $1.provider, $1.windowID) }
        var out = "ts,provider,window_id,used_pct,resets_at\n"
        for s in rows {
            let resets = s.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
            out += "\(Int(s.ts.timeIntervalSince1970)),\(field(s.provider)),\(field(s.windowID)),\(number(s.usedPct)),\(resets)\n"
        }
        return out
    }

    /// 服務與額度 id 由收集器產生（`[a-z0-9_]`），仍照 RFC 4180 處理，並擋掉試算表公式開頭的字元。
    static func field(_ value: String) -> String {
        var v = value
        if let first = v.first, "=+-@\t\r".contains(first) { v = "'" + v }
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
