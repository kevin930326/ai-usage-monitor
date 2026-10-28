import Foundation
import Testing
@testable import UsageKit

/// 角色養成的跨平台一致性（ADR-0020）：讀 `fixtures/level/cases.json`，用 `MascotLevel` 算出結果，
/// 和 `fixtures/level/golden.json` 比對。Windows 的 C# 測試讀同一份，必須算出同樣的結果。
///
/// 規則有意改變時：`AUM_UPDATE_GOLDEN=1 swift test --filter LevelGoldenTests` 重新產生 golden.json，
/// 檢查 `git diff` 後和 C# 的修改一起提交。
@Suite struct LevelGoldenTests {
    static let folder = FixtureTests.folder.appendingPathComponent("level")

    struct Input: Decodable {
        var cases: [Case]
    }

    struct Case: Decodable {
        var name: String
        var today: String
        var days: [String: Int64]
        /// 連續的日子：從 `from` 起 `count` 天，每天 `tokens`
        var runs: [Run]?
    }

    struct Run: Decodable {
        var from: String
        var count: Int
        var tokens: Int64
    }

    struct Result: Codable, Equatable {
        var xp: Int64
        var level: Int
        var to_next: Int64
        var current_streak: Int
        var longest_streak: Int
        var active_days: Int
    }

    struct Named: Codable, Equatable {
        var name: String
        var result: Result?
    }

    /// 日數 → `YYYY-MM-DD`（civil_from_days），只用來展開 `runs`
    static func dayText(_ n: Int) -> String {
        let z = n + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func run(_ c: Case) -> Named {
        var days = c.days
        for r in c.runs ?? [] {
            let start = MascotLevel.dayNumber(r.from)!
            for i in 0..<r.count { days[dayText(start + i)] = r.tokens }
        }
        let level = MascotLevel(days: days, today: c.today)
        return Named(name: c.name, result: level.map {
            Result(xp: $0.xp, level: $0.level, to_next: $0.toNext, current_streak: $0.currentStreak,
                   longest_streak: $0.longestStreak, active_days: $0.activeDays)
        })
    }

    @Test func goldenMatches() throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: Self.folder.appendingPathComponent("cases.json")))
        let output = input.cases.map(Self.run)
        let goldenURL = Self.folder.appendingPathComponent("golden.json")
        if ProcessInfo.processInfo.environment["AUM_UPDATE_GOLDEN"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(output).write(to: goldenURL)
            return
        }
        let golden = try JSONDecoder().decode([Named].self, from: Data(contentsOf: goldenURL))
        #expect(golden.count == output.count, "golden.json 與 cases.json 的情境數不同")
        for (g, o) in zip(golden, output) { #expect(g == o, "\(o.name)") }
    }

    @Test func dayNumbersRoundTrip() {
        for n in [-1, 0, 1, 11_016, 19_782, 20_390, 60_000] {
            #expect(MascotLevel.dayNumber(Self.dayText(n)) == n)
        }
        #expect(MascotLevel.dayNumber("1970-01-01") == 0)
    }

    @Test func thresholdsAndText() throws {
        #expect([2, 3, 5, 10, 20, 30].map(MascotLevel.threshold) == [50, 150, 500, 2_250, 9_500, 21_750])
        let level = try #require(MascotLevel(days: ["2026-10-29": 1], today: "2026-10-29"))
        #expect(level.title == "Lv 1")
        #expect(level.progress == 0.2)
        #expect(level.accessibilityText == "第 1 級，再 40 點升級；所有電腦合併，連續 1 天，最長 1 天")
    }
}
