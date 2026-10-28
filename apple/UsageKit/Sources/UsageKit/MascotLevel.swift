import Foundation

/// 角色養成（ADR-0020）：從 `level_days`（每天所有電腦合併的主數字，收集器維護、只增不減）算經驗值、等級與連續天數。
/// 規則和 C#（UsageCore/MascotLevel.cs）相同，`fixtures/level` 的 golden 兩邊比對。
///
/// - 活躍日：`tokens > 0`。每天 10 點，加用量 `min(10, ⌊log₂(tokens ÷ 10,000)⌋ + 1)`（滿 1 萬才有），
///   加連續 `min(5, k − 1)`（連續活躍的第 k 天）；一天最多 25 點。
/// - 等級 L 升到 L + 1 要 `50 × L` 點；達到 L 的累計門檻 `25 × L × (L − 1)`；最高 99。
/// - 日期是 `YYYY-MM-DD`，以日曆日計算（不經過時區與 Calendar），格式不對的略過。
public struct MascotLevel: Equatable, Sendable {
    public static let maxLevel = 99
    static let activePoints: Int64 = 10
    static let volumeUnit: Int64 = 10_000
    static let maxVolume: Int64 = 10
    static let maxStreakBonus: Int64 = 5

    public var xp: Int64
    public var level: Int
    /// 升到下一級還要幾點（最高級時 0）
    public var toNext: Int64
    /// 這一級的進度 0～1（最高級時 1）
    public var progress: Double
    /// 到今天（今天還沒用時到昨天）為止的連續活躍天數
    public var currentStreak: Int
    public var longestStreak: Int
    public var activeDays: Int

    /// 沒有任何活躍日時 nil（新安裝、還沒掃描完）
    public init?(days: [String: Int64], today: String) {
        let active = days.compactMap { day, tokens in tokens > 0 ? Self.dayNumber(day).map { ($0, tokens) } : nil }
            .sorted { $0.0 < $1.0 }
        guard !active.isEmpty else { return nil }
        var xp: Int64 = 0
        var run = 0
        var longest = 0
        var previous: Int?
        for (day, tokens) in active {
            run = previous == day - 1 ? run + 1 : 1
            longest = max(longest, run)
            previous = day
            xp += Self.activePoints + Self.volume(tokens) + min(Self.maxStreakBonus, Int64(run - 1))
        }
        // 目前的連續：從今天（今天還沒用時從昨天）往回數。時鐘曾經調快而留下「未來」的日子時不受影響
        let set = Set(active.map(\.0))
        var current = 0
        if let todayNumber = Self.dayNumber(today), var day = [todayNumber, todayNumber - 1].first(where: set.contains) {
            while set.contains(day) {
                current += 1
                day -= 1
            }
        }

        var level = 1
        while level < Self.maxLevel && Self.threshold(level + 1) <= xp { level += 1 }
        self.xp = xp
        self.level = level
        if level == Self.maxLevel {
            toNext = 0
            progress = 1
        } else {
            toNext = Self.threshold(level + 1) - xp
            progress = Double(xp - Self.threshold(level)) / Double(50 * Int64(level))
        }
        currentStreak = current
        longestStreak = longest
        activeDays = active.count
    }

    /// 達到等級 L 的累計經驗值
    public static func threshold(_ level: Int) -> Int64 { 25 * Int64(level) * Int64(level - 1) }

    /// 用量加分：1 萬→1、2 萬→2、4 萬→3 … 512 萬以上→10（整數運算，和 C# 相同）
    static func volume(_ tokens: Int64) -> Int64 {
        guard tokens >= volumeUnit else { return 0 }
        var bonus: Int64 = 1
        var t = tokens / volumeUnit
        while t >= 2 && bonus < maxVolume {
            t /= 2
            bonus += 1
        }
        return bonus
    }

    /// `YYYY-MM-DD` → 從 1970-01-01 起的日數（Howard Hinnant 的 days_from_civil）；格式或日期不對時 nil
    static func dayNumber(_ text: String) -> Int? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.utf8.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= daysIn(year: y, month: m) else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// 「Lv 7」
    public var title: String { "Lv \(level)" }

    /// VoiceOver 與滑鼠提示
    public var accessibilityText: String {
        let next = level == Self.maxLevel ? "已經是最高級" : "再 \(toNext) 點升級"
        return "第 \(level) 級，\(next)；所有電腦合併，連續 \(currentStreak) 天，最長 \(longestStreak) 天"
    }
}
