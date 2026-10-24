import Foundation

// 這台 Mac 的 Token 統計（FR-43、FR-44，ADR-0009 第 4 節、ADR-0011 第 4 節）。
// 資料來自收集器寫的 history.sqlite3（`daily_tokens`、`hourly_tokens`、`records`；讀取層在 Mac App 的 HistoryStore）；
// 這裡只有純計算，Linux 也能測試。日期是收集器以本機時區寫入的 `YYYY-MM-DD`。

/// 全部／Claude／Codex 切換。
public enum TokenScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case claude
    case codex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "全部"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    public func includes(_ provider: String) -> Bool {
        self == .all || provider == rawValue
    }

    /// `records` 的鍵：全部沒有後綴，各服務加 `:claude`／`:codex`
    public func recordKey(_ base: String) -> String {
        self == .all ? base : "\(base):\(rawValue)"
    }
}

/// 四種 Token 分開保存（ADR-0009 第 4 節）；`reasoning` 是 `output` 的明細，不另外加總。
public struct TokenCounts: Equatable, Sendable {
    public var input: Int64
    public var cacheWrite: Int64
    public var cacheRead: Int64
    public var output: Int64
    public var reasoning: Int64

    public init(input: Int64 = 0, cacheWrite: Int64 = 0, cacheRead: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
        self.reasoning = reasoning
    }

    public static let zero = TokenCounts()

    /// 顯示的「Token」主數字 = input + cache_write + output（不含 cache_read）
    public var main: Int64 { input + cacheWrite + output }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead,
                    output: a.output + b.output, reasoning: a.reasoning + b.reasoning)
    }

    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

/// `daily_tokens` 的一列（這台 Mac 的 device_id）。
public struct TokenDayRow: Equatable, Sendable {
    public var day: String
    public var provider: String
    public var model: String
    public var counts: TokenCounts
    public var taskCount: Int
    public var taskSeconds: Int
    public var longestTaskSeconds: Int

    public init(day: String, provider: String, model: String, counts: TokenCounts,
                taskCount: Int = 0, taskSeconds: Int = 0, longestTaskSeconds: Int = 0) {
        self.day = day
        self.provider = provider
        self.model = model
        self.counts = counts
        self.taskCount = taskCount
        self.taskSeconds = taskSeconds
        self.longestTaskSeconds = longestTaskSeconds
    }
}

/// `hourly_tokens` 的一列（只在完整統計視窗讀取）。
public struct TokenHourRow: Equatable, Sendable {
    public var day: String
    public var hour: Int
    public var provider: String
    public var model: String
    public var counts: TokenCounts

    public init(day: String, hour: Int, provider: String, model: String, counts: TokenCounts) {
        self.day = day
        self.hour = hour
        self.provider = provider
        self.model = model
        self.counts = counts
    }
}

/// `records` 的一列：個人紀錄（不隨保留期間刪除）。
public struct TokenRecord: Equatable, Sendable {
    public var value: Int64
    public var day: String?

    public init(value: Int64, day: String? = nil) {
        self.value = value
        self.day = day
    }
}

/// 從資料庫讀到的 Token 統計。
public struct TokenStatsData: Equatable, Sendable {
    public var days: [TokenDayRow]
    public var hours: [TokenHourRow]
    public var records: [String: TokenRecord]
    /// `record_days`：每天每個服務的主數字，不套用保留期間（目前連續天數用；保留期間比連續天數短時也正確）
    public var recordDays: [String: [String: Int64]]
    /// 首次掃描完成（`meta.first_scan_done`）
    public var firstScanDone: Bool
    /// 首次掃描進度 0～100（`meta.first_scan_progress`）；收集器還沒開始時為 nil
    public var firstScanProgress: Int?
    /// 略過的紀錄行數（無法解析＋過長）；> 0 時顯示「部分紀錄無法解析」
    public var skippedLines: Int
    /// 保留期間（天，0＝永久）
    public var retentionDays: Int
    /// 實際還有每日資料的第一天（`meta.token_days_from`，`YYYY-MM-DD`）：保留期間縮短或清除歷史後延長保留期間，
    /// 已刪除的日子不會回來，不能只看目前的保留期間；沒有記錄時為 nil
    public var dataFrom: String?

    public init(days: [TokenDayRow] = [], hours: [TokenHourRow] = [], records: [String: TokenRecord] = [:],
                recordDays: [String: [String: Int64]] = [:],
                firstScanDone: Bool = false, firstScanProgress: Int? = nil, skippedLines: Int = 0, retentionDays: Int = 365,
                dataFrom: String? = nil) {
        self.days = days
        self.hours = hours
        self.records = records
        self.recordDays = recordDays
        self.firstScanDone = firstScanDone
        self.firstScanProgress = firstScanProgress
        self.skippedLines = skippedLines
        self.retentionDays = retentionDays
        self.dataFrom = dataFrom
    }

    public static let empty = TokenStatsData()

    /// 有任何 Token 資料（含已超過保留期間、只剩個人紀錄的）
    public var hasData: Bool {
        days.contains { $0.counts.main > 0 } || (records["total_tokens"]?.value ?? 0) > 0
    }

    /// 這個範圍有資料的服務（給切換列決定要不要顯示）
    public var providers: [String] {
        ["claude", "codex"].filter { p in days.contains { $0.provider == p && $0.counts.main > 0 } || (records["total_tokens:\(p)"]?.value ?? 0) > 0 }
    }

    /// 每日資料最早還保留的那一天（保留期間以前的已刪除，不能當成「沒有使用」）：目前保留期間的起點與
    /// `dataFrom` 較晚的一個；永久保留且沒有刪除過時為 nil
    public func firstAvailableDay(now: Date, calendar base: Calendar = .current) -> Date? {
        let calendar = TokenCalendar.make(base)
        let byRetention = retentionDays > 0
            ? calendar.startOfDay(for: now.addingTimeInterval(-TimeInterval(retentionDays) * 86400)) : nil
        let deleted = dataFrom.flatMap { TokenCalendar.date($0, calendar: base) }
        switch (byRetention, deleted) {
        case let (a?, b?): return max(a, b)
        case let (a, b): return a ?? b
        }
    }

    /// 每天（依範圍）的合計
    public func dailyTotals(scope: TokenScope) -> [String: TokenCounts] {
        var result: [String: TokenCounts] = [:]
        for row in days where scope.includes(row.provider) {
            result[row.day, default: .zero] += row.counts
        }
        return result
    }
}

// MARK: - 日期

/// 統計用的日曆：西元曆、本機時區、星期一開始（「本週」從本機時間星期一 00:00 起算，ADR-0009 第 4 節）。
/// 收集器寫的日期鍵是西元 `YYYY-MM-DD`：使用者選民國曆或佛曆時也必須用西元曆換算，否則年份對不上。
public enum TokenCalendar {
    public static func make(_ base: Calendar = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = base.timeZone
        c.locale = base.locale
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    public static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = make(calendar).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return make(calendar).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public static func startOfWeek(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func adding(_ days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(TimeInterval(days) * 86400)
    }
}

// MARK: - 四個數字

public struct TokenSummary: Equatable, Sendable {
    /// 本週（星期一起）的合計
    public var thisWeek: TokenCounts
    /// 上週同一段期間（星期一到上週的今天）的主數字
    public var lastWeekSamePeriod: Int64
    public var bestDay: TokenRecord?
    public var longestTaskSeconds: TokenRecord?
    /// 目前連續使用的天數：今天有用時算到今天，今天還沒用時算到昨天（還沒中斷）
    public var currentStreak: Int
    public var longestStreak: TokenRecord?
    public var total: TokenRecord?

    /// 與上週同期相比的變化（%）；上週同期為 0 時為 nil
    public var changePct: Double? {
        guard lastWeekSamePeriod > 0 else { return nil }
        return (Double(thisWeek.main) - Double(lastWeekSamePeriod)) / Double(lastWeekSamePeriod) * 100
    }

    /// 目前的連續天數就是（或追平）最長紀錄
    public var streakIsRecord: Bool {
        currentStreak > 0 && currentStreak >= (longestStreak?.value ?? 0)
    }

    public init(data: TokenStatsData, scope: TokenScope, now: Date, calendar base: Calendar = .current) {
        let calendar = TokenCalendar.make(base)
        let totals = data.dailyTotals(scope: scope)
        let today = calendar.startOfDay(for: now)
        let monday = TokenCalendar.startOfWeek(now, calendar: calendar)
        let daysIntoWeek = calendar.dateComponents([.day], from: monday, to: today).day ?? 0
        var week = TokenCounts.zero
        var last: Int64 = 0
        for offset in 0...max(daysIntoWeek, 0) {
            let day = TokenCalendar.adding(offset, to: monday, calendar: calendar)
            week += totals[TokenCalendar.key(day, calendar: calendar)] ?? .zero
            last += totals[TokenCalendar.key(TokenCalendar.adding(-7, to: day, calendar: calendar), calendar: calendar)]?.main ?? 0
        }
        thisWeek = week
        // 上週同期已超過保留期間：無法比較
        let lastWeekStart = TokenCalendar.adding(-7, to: monday, calendar: calendar)
        let comparable = data.firstAvailableDay(now: now, calendar: base).map { lastWeekStart >= $0 } ?? true
        lastWeekSamePeriod = comparable ? last : 0

        // 個人紀錄以 records 為準（不受保留期間影響）；收集器還沒寫入時從每日資料算
        func record(_ base: String) -> TokenRecord? { data.records[scope.recordKey(base)] }
        let computedBest = totals.filter { $0.value.main > 0 }.max { ($0.value.main, $1.key) < ($1.value.main, $0.key) }
            .map { TokenRecord(value: $0.value.main, day: $0.key) }
        bestDay = [record("best_day_tokens"), computedBest].compactMap { $0 }.max { $0.value < $1.value }
        let computedLongest = data.days.filter { scope.includes($0.provider) && $0.longestTaskSeconds > 0 }
            .max { $0.longestTaskSeconds < $1.longestTaskSeconds }
            .map { TokenRecord(value: Int64($0.longestTaskSeconds), day: $0.day) }
        longestTaskSeconds = [record("longest_task_seconds"), computedLongest].compactMap { $0 }.max { $0.value < $1.value }
        total = record("total_tokens") ?? (totals.isEmpty ? nil : TokenRecord(value: totals.values.reduce(0) { $0 + $1.main }))

        // 有 record_days 時以它為準（不受保留期間影響），否則用每日資料
        func used(_ date: Date) -> Bool {
            let key = TokenCalendar.key(date, calendar: calendar)
            if !data.recordDays.isEmpty {
                return (data.recordDays[key] ?? [:]).contains { scope.includes($0.key) && $0.value > 0 }
                    || (totals[key]?.main ?? 0) > 0
            }
            return (totals[key]?.main ?? 0) > 0
        }
        var streak = 0
        var cursor = used(today) ? today : TokenCalendar.adding(-1, to: today, calendar: calendar)
        while used(cursor) {
            streak += 1
            cursor = TokenCalendar.adding(-1, to: cursor, calendar: calendar)
        }
        currentStreak = streak
        let recordStreak = record("longest_streak_days")
        longestStreak = streak > (recordStreak?.value ?? 0)
            ? TokenRecord(value: Int64(streak), day: TokenCalendar.key(today, calendar: calendar)) : recordStreak
    }
}

// MARK: - Token 活動

public enum TokenActivityRange: String, CaseIterable, Identifiable, Sendable {
    case days30
    case weeks
    case cumulative

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .days30: "30 天"
        case .weeks: "週"
        case .cumulative: "累計"
        }
    }
}

/// 長條圖的一根（一天或一週）。
public struct TokenBar: Equatable, Sendable {
    public var start: Date
    /// 依服務分開的主數字（疊加長條用）
    public var byProvider: [String: Int64]
    public var counts: TokenCounts
    /// 這段期間的每日資料還在保留期間內（否則不畫，也不當成 0）
    public var available: Bool = true

    public var main: Int64 { counts.main }
}

public enum TokenActivity {
    public static let dayCount = 30
    public static let weekCount = 12

    public static func bars(data: TokenStatsData, scope: TokenScope, range: TokenActivityRange, now: Date,
                            calendar base: Calendar = .current) -> [TokenBar] {
        let calendar = TokenCalendar.make(base)
        let today = calendar.startOfDay(for: now)
        let first = data.firstAvailableDay(now: now, calendar: base)
        func available(_ date: Date) -> Bool { first.map { date >= $0 } ?? true }
        var byDay: [String: (counts: TokenCounts, providers: [String: Int64])] = [:]
        for row in data.days where scope.includes(row.provider) {
            byDay[row.day, default: (.zero, [:])].counts += row.counts
            byDay[row.day, default: (.zero, [:])].providers[row.provider, default: 0] += row.counts.main
        }
        func day(_ date: Date) -> (TokenCounts, [String: Int64]) {
            let value = byDay[TokenCalendar.key(date, calendar: calendar)]
            return (value?.counts ?? .zero, value?.providers ?? [:])
        }
        switch range {
        case .days30:
            return (0..<dayCount).map { i in
                let date = TokenCalendar.adding(i - dayCount + 1, to: today, calendar: calendar)
                let (counts, providers) = day(date)
                return TokenBar(start: date, byProvider: providers, counts: counts, available: available(date))
            }
        case .weeks:
            let monday = TokenCalendar.startOfWeek(now, calendar: calendar)
            return (0..<weekCount).map { w in
                let start = TokenCalendar.adding(7 * (w - weekCount + 1), to: monday, calendar: calendar)
                var counts = TokenCounts.zero
                var providers: [String: Int64] = [:]
                for d in 0..<7 {
                    let (c, p) = day(TokenCalendar.adding(d, to: start, calendar: calendar))
                    counts += c
                    providers.merge(p, uniquingKeysWith: +)
                }
                // 一週的第一天也在保留期間內才算完整；跨過保留邊界的週有幾天已刪除，合計不可信
                return TokenBar(start: start, byProvider: providers, counts: counts, available: available(start))
            }
        case .cumulative:
            // 每天結束時的累計：以 records 的累計 Token（含保留期間以前）往回扣。
            // 保留期間以前的日子算不出當天的累計，不畫
            let daily = (0..<dayCount).map { i in day(TokenCalendar.adding(i - dayCount + 1, to: today, calendar: calendar)) }
            let windowTotal = daily.reduce(Int64(0)) { $0 + $1.0.main }
            let allTotals = data.dailyTotals(scope: scope).values.reduce(Int64(0)) { $0 + $1.main }
            var running = max((data.records[scope.recordKey("total_tokens")]?.value ?? allTotals) - windowTotal, 0)
            return daily.enumerated().map { i, value in
                running += value.0.main
                let date = TokenCalendar.adding(i - dayCount + 1, to: today, calendar: calendar)
                return TokenBar(start: date, byProvider: [:], counts: TokenCounts(input: running), available: available(date))
            }
        }
    }
}

// MARK: - 活動熱力圖

/// 一欄一週（星期一在上），最右欄是本週；今天以後的格子為 nil。
public struct TokenHeatmap: Equatable, Sendable {
    public var weeks: Int
    public var firstMonday: Date
    /// `weeks × 7`，依欄（週）再依列（星期一～日）排列
    public var cells: [Int64?]
    /// 分成 4 級的門檻（非零值的四分位數）
    public var thresholds: [Int64]
    /// 有格子在保留期間以前（不畫，與「沒有使用」區分）
    public var truncated: Bool

    public init(data: TokenStatsData, scope: TokenScope, now: Date, weeks: Int, calendar base: Calendar = .current) {
        let calendar = TokenCalendar.make(base)
        let totals = data.dailyTotals(scope: scope)
        let today = calendar.startOfDay(for: now)
        self.weeks = weeks
        firstMonday = TokenCalendar.adding(-7 * (weeks - 1), to: TokenCalendar.startOfWeek(now, calendar: calendar), calendar: calendar)
        let first = data.firstAvailableDay(now: now, calendar: base)
        var cells: [Int64?] = []
        var truncated = false
        for i in 0..<(weeks * 7) {
            let date = TokenCalendar.adding(i, to: firstMonday, calendar: calendar)
            if let first, date < first {
                truncated = true
                cells.append(nil)
                continue
            }
            cells.append(date > today ? nil : totals[TokenCalendar.key(date, calendar: calendar)]?.main ?? 0)
        }
        self.cells = cells
        self.truncated = truncated
        let nonZero = cells.compactMap { $0 }.filter { $0 > 0 }.sorted()
        thresholds = nonZero.isEmpty ? [] : [0.25, 0.5, 0.75].map { nonZero[Int(Double(nonZero.count - 1) * $0)] }
    }

    /// 0（沒有使用）～4（最多）
    public func level(_ value: Int64) -> Int {
        guard value > 0 else { return 0 }
        return 1 + thresholds.filter { value > $0 }.count
    }

    public func date(column: Int, row: Int, calendar base: Calendar = .current) -> Date {
        TokenCalendar.adding(column * 7 + row, to: firstMonday, calendar: TokenCalendar.make(base))
    }
}

// MARK: - 各模型與時段（完整統計視窗）

/// 一個服務的一個模型的合計（「各模型」的一列）
public struct TokenModelTotal: Equatable, Sendable, Identifiable {
    public var provider: String
    public var model: String
    public var counts: TokenCounts
    public var id: String { "\(provider)/\(model)" }
}

public enum TokenBreakdown {
    /// 各模型的合計，依主數字由大到小。以（服務、模型）分組：兩家都有白名單外的模型時各自一列 `other`
    public static func models(data: TokenStatsData, scope: TokenScope) -> [TokenModelTotal] {
        var result: [String: TokenModelTotal] = [:]
        for row in data.days where scope.includes(row.provider) {
            let key = "\(row.provider)/\(row.model)"
            result[key, default: TokenModelTotal(provider: row.provider, model: row.model, counts: .zero)].counts += row.counts
        }
        return result.values.filter { $0.counts.main > 0 }
            .sorted { ($0.counts.main, $1.model, $1.provider) > ($1.counts.main, $0.model, $0.provider) }
    }

    /// 一天中各時段（0～23 時）的主數字合計
    public static func hours(data: TokenStatsData, scope: TokenScope) -> [Int64] {
        var result = [Int64](repeating: 0, count: 24)
        for row in data.hours where scope.includes(row.provider) && (0..<24).contains(row.hour) {
            result[row.hour] += row.counts.main
        }
        return result
    }
}

// MARK: - 文字

public enum TokenFormat {
    /// 「9,999」「1.23萬」「12.3萬」「1,470萬」「3.85億」：一萬以上用萬／億、三位有效數字，
    /// 不到一萬顯示整數。面板、統計視窗與 VoiceOver 都用這個；滑鼠說明用 `full`。
    public static func short(_ value: Int64) -> String {
        let v = abs(Double(value))
        guard v >= 10_000 else { return full(value) }
        var scaled = significant(v / 1e4)
        var unit = "萬"
        if scaled >= 10_000 {  // 包含四捨五入後進位到一億（9,999.5 萬 → 1 億）
            scaled = significant(v / 1e8)
            unit = "億"
        }
        return (value < 0 ? "-" : "") + trimmed(scaled) + unit
    }

    /// 完整數字加千分位：「12,345,678」
    public static func full(_ value: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 「1 小時 23 分」「45 分」「30 秒」
    public static func duration(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) 小時" : "\(h) 小時 \(m) 分"
    }

    /// 四捨五入到三位有效數字（`v` ≥ 1）
    private static func significant(_ v: Double) -> Double {
        let step = pow(10, floor(log10(v)) - 2)
        return (v / step).rounded() * step
    }

    /// 三位有效數字的文字：「1.47」「12.3」「147」「1,470」；小數尾端的 0 去掉（「1.5」）
    private static func trimmed(_ v: Double) -> String {
        guard v < 1000 else { return full(Int64(v.rounded())) }
        let digits = v < 10 ? 2 : v < 100 ? 1 : 0
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}

// MARK: - 匯出 CSV（FR-37、ADR-0009 第 5 節）

public enum TokenCSV {
    public static let header = "day,provider,model,input_tokens,cache_write_tokens,cache_read_tokens,output_tokens,"
        + "reasoning_tokens,task_count,task_seconds,longest_task_seconds\n"

    /// 每日 Token（`daily_tokens`）：欄位同資料表，四種 Token 與推理明細分開、不預先加總；
    /// `day` 是收集器寫入時的本機日期（YYYY-MM-DD）。依日期、服務、模型排序。
    public static func make(rows: [TokenDayRow]) -> String {
        let sorted = rows.sorted { ($0.day, $0.provider, $0.model) < ($1.day, $1.provider, $1.model) }
        var out = header
        for r in sorted {
            let c = r.counts
            let fields: [String] = [
                QuotaHistoryCSV.field(r.day), QuotaHistoryCSV.field(r.provider), QuotaHistoryCSV.field(r.model),
                "\(c.input)", "\(c.cacheWrite)", "\(c.cacheRead)", "\(c.output)", "\(c.reasoning)",
                "\(r.taskCount)", "\(r.taskSeconds)", "\(r.longestTaskSeconds)",
            ]
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }
}
