import Foundation
import Testing
@testable import UsageKit

/// 額度預測的跨平台一致性（ADR-0018 第 1 節）：讀 `fixtures/forecast/cases.json`，用 `QuotaForecast` 算出結果，
/// 和 `fixtures/forecast/golden.json` 比對。Windows 的 C# 測試與收集器的 Python 測試讀同一份，必須算出同樣的結果。
///
/// 規則有意改變時：`AUM_UPDATE_GOLDEN=1 swift test --filter ForecastGoldenTests` 重新產生 golden.json，
/// 檢查 `git diff` 後和 C#、Python 的修改一起提交。
@Suite struct ForecastGoldenTests {
    static let folder = FixtureTests.folder.appendingPathComponent("forecast")

    struct Input: Decodable {
        var now: String
        var cases: [Case]
    }

    struct Case: Decodable {
        var name: String
        var stale: Bool?
        var window: Window
        var series: [Series]
    }

    struct Window: Decodable {
        var id: String
        var used_pct: Double
        var resets_min: Double?
        var hidden: Bool?
    }

    struct Series: Decodable {
        var from_min: Int
        var to_min: Int
        var every_min: Int
        var start: Double
        var end: Double
        var resets_min: Double?
    }

    struct Result: Codable, Equatable {
        var exhausts_in_min: Int
        var urgent: Bool
        var faster: Double?
    }

    struct Named: Codable, Equatable {
        var name: String
        var result: Result?
    }

    static func run(_ c: Case, now: Date) -> Named {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        var samples: [QuotaSample] = []
        for s in c.series {
            for t in stride(from: s.from_min, through: s.to_min, by: s.every_min) {
                let used = s.start + (s.end - s.start) * Double(t - s.from_min) / Double(s.to_min - s.from_min)
                samples.append(QuotaSample(ts: at(Double(t)), provider: "claude", windowID: c.window.id, usedPct: used,
                                           resetsAt: (s.resets_min ?? c.window.resets_min).map(at)))
            }
        }
        let window = UsageWindow(id: c.window.id, label: c.window.id, usedPct: c.window.used_pct,
                                 resetsAt: c.window.resets_min.map(at), hidden: c.window.hidden ?? false)
        let forecast = QuotaForecast(window: window, provider: "claude", history: QuotaHistory(samples: samples),
                                     stale: c.stale ?? false, now: now)
        return Named(name: c.name, result: forecast.map {
            Result(exhausts_in_min: Int(($0.exhaustsAt.timeIntervalSince(now) / 60).rounded(.down)), urgent: $0.urgent, faster: $0.faster)
        })
    }

    @Test func matchesGolden() throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: Self.folder.appendingPathComponent("cases.json")))
        let now = try #require(ISO8601DateFormatter().date(from: input.now))
        let output = input.cases.map { Self.run($0, now: now) }
        let goldenURL = Self.folder.appendingPathComponent("golden.json")
        if ProcessInfo.processInfo.environment["AUM_UPDATE_GOLDEN"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try (encoder.encode(output) + Data("\n".utf8)).write(to: goldenURL)
        }
        let golden = try JSONDecoder().decode([Named].self, from: Data(contentsOf: goldenURL))
        #expect(golden.count == output.count, "golden.json 與 cases.json 的情境數不同")
        for (expected, actual) in zip(golden, output) {
            #expect(expected == actual, "\(actual.name)：預期 \(String(describing: expected.result))，實際 \(String(describing: actual.result))")
        }
    }

    @Test func text() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Taipei"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-28T04:00:00Z"))  // 週三 12:00
        func line(_ hours: Double, faster: Double? = nil) -> String {
            QuotaForecast(exhaustsAt: now.addingTimeInterval(hours * 3600), urgent: false, faster: faster).line(now: now, calendar: calendar)
        }
        #expect(line(2.5) == "照目前速度約 14:30 用完")
        #expect(line(12.5, faster: 2.1) == "照目前速度約明天 00:30 用完・比平常快 2.1 倍")
        #expect(line(48) == "照目前速度約週五 12:00 用完")
        #expect(line(1, faster: 1.5) == "照目前速度約 13:00 用完・比平常快 1.5 倍")
        let short = QuotaForecast(exhaustsAt: now.addingTimeInterval(12.5 * 3600), urgent: false, faster: 2.1)
        #expect(short.shortLine(now: now, calendar: calendar) == "約明天 00:30 用完・快 2.1 倍")
        let urgent = QuotaForecast(exhaustsAt: now.addingTimeInterval(1800), urgent: true)
        #expect(urgent.spokenLine(now: now, calendar: calendar) == "照目前速度約 12:30 用完，不到 1 小時")
    }
}
