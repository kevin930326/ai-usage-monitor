import Foundation
import Testing
@testable import UsageKit

/// 跨平台的計算一致性（ADR-0015 第 4 節）：讀 repo 根目錄的 `fixtures/logic/cases.json`，用 UsageKit 算出
/// 剩餘最少的額度、預期進度、用量節奏、近期速度、重置判斷、倒數文字與萬／億格式，以及額度歷史（建議接下來用、
/// 重置時間軸、每週預測、走勢、額度消耗）與 Token 統計（LogicGoldenHistory.swift），和 `fixtures/logic/golden.json` 比對。
/// Windows App 的 C# 測試（`windows/tests/UsageCore.Tests`）讀同一份輸入，必須算出同樣的 golden。
///
/// 計算規則改變時：`AUM_UPDATE_GOLDEN=1 swift test --filter LogicGoldenTests` 重新產生 golden.json，
/// 檢查 `git diff` 後和 C# 的修改一起提交。
@Suite struct LogicGoldenTests {
    static let folder = FixtureTests.folder.appendingPathComponent("logic")
    static let casesURL = folder.appendingPathComponent("cases.json")
    static let goldenURL = folder.appendingPathComponent("golden.json")

    @Test func goldenMatchesUsageKit() throws {
        let computed = try Self.compute()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(computed)
        if ProcessInfo.processInfo.environment["AUM_UPDATE_GOLDEN"] == "1" {
            try (data + Data("\n".utf8)).write(to: Self.goldenURL)
            return
        }
        // 以 JSON 的值比較（浮點容許 1e-9），不比文字：Linux 與 macOS 的浮點輸出可能差在最後一位
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.goldenURL))
        let actual = try JSONSerialization.jsonObject(with: data)
        var differences: [String] = []
        Self.compare(expected, actual, path: "$", into: &differences)
        let report = differences.prefix(20).joined(separator: "\n")
        #expect(differences.isEmpty, "golden.json 與 UsageKit 的計算不同（規則有意改變時以 AUM_UPDATE_GOLDEN=1 重新產生）：\n\(report)")
    }

    // MARK: - 輸入

    struct Input: Decodable {
        var cases: [Case]
        var tokenFormat: [Int64]
        var countdownSeconds: [Double]
        var updatedSeconds: [Double]
        var durationSeconds: [Int64]
        var tokenCases: [TokenCase]

        enum CodingKeys: String, CodingKey {
            case cases
            case tokenFormat = "token_format"
            case countdownSeconds = "countdown_seconds"
            case updatedSeconds = "updated_seconds"
            case durationSeconds = "duration_seconds"
            case tokenCases = "token_cases"
        }
    }

    struct Case: Decodable {
        var name: String
        var now: Date
        var choice: String?
        var snapshot: UsageSnapshot
        var samples: [Sample]?
        var runs: [Run]?
        /// 本機時區（IANA）；沒有時為 UTC。額度消耗的整點與每週預測的「週五晚上」依它計算
        var timeZone: String?

        enum CodingKeys: String, CodingKey {
            case name, now, choice, snapshot, samples, runs
            case timeZone = "time_zone"
        }
    }

    struct Run: Decodable {
        var ts: Date
        var ok: Int?
        var runs: Int?
    }

    struct Sample: Decodable {
        var ts: Date
        var provider: String
        var window: String
        var usedPct: Double
        var resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case ts, provider, window
            case usedPct = "used_pct"
            case resetsAt = "resets_at"
        }
    }

    // MARK: - 輸出（欄位名稱即 golden.json 的鍵；C# 端照同樣的名稱比對）

    struct Output: Encodable {
        var cases: [CaseOutput]
        var tokenFormat: [TokenOutput]
        var countdown: [CountdownOutput]
        var updated: [CountdownOutput]
        var duration: [JSONValue]
        var tokenCases: [JSONValue]

        enum CodingKeys: String, CodingKey {
            case cases, countdown, updated, duration
            case tokenFormat = "token_format"
            case tokenCases = "token_cases"
        }
    }

    struct CaseOutput: Encodable {
        var name: String
        var stale: Bool
        var hasNoProviders: Bool
        var orderedProviders: [String]
        var tightest: String?
        var chosen: String?
        var chosenState: String?
        var leastLabel: String?
        var windows: [WindowOutput]
        /// 額度歷史的畫面（LogicGoldenHistory.swift）
        var history: JSONValue

        enum CodingKeys: String, CodingKey {
            case name, stale, tightest, chosen, windows, history
            case hasNoProviders = "has_no_providers"
            case orderedProviders = "ordered_providers"
            case chosenState = "chosen_state"
            case leastLabel = "least_label"
        }

        // nil 也要寫出 null：golden 的每個鍵都要出現，C# 才能逐鍵比對
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(stale, forKey: .stale)
            try c.encode(hasNoProviders, forKey: .hasNoProviders)
            try c.encode(orderedProviders, forKey: .orderedProviders)
            try c.encode(tightest, forKey: .tightest)
            try c.encode(chosen, forKey: .chosen)
            try c.encode(chosenState, forKey: .chosenState)
            try c.encode(leastLabel, forKey: .leastLabel)
            try c.encode(windows, forKey: .windows)
            try c.encode(history, forKey: .history)
        }
    }

    struct PaceOutput: Encodable {
        var aheadBy: Double
        /// 預計用完的時間（Unix 秒，四捨五入到整數）
        var exhaustsAt: Int64?
        var tooFast: Bool

        enum CodingKeys: String, CodingKey {
            case aheadBy = "ahead_by"
            case exhaustsAt = "exhausts_at"
            case tooFast = "too_fast"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(aheadBy, forKey: .aheadBy)
            try c.encode(exhaustsAt, forKey: .exhaustsAt)
            try c.encode(tooFast, forKey: .tooFast)
        }
    }

    struct WindowOutput: Encodable {
        var key: String
        var displayName: String
        var hidden: Bool
        var isReset: Bool
        var effectiveUsedPct: Double
        var effectiveRemainingPct: Double
        /// 圓環與面板顯示的整數 %（`.rounded()`：0.5 進位，C# 要用 MidpointRounding.AwayFromZero）
        var remainingRounded: Int
        var severity: String
        var state: String
        var duration: Double?
        var elapsedFraction: Double?
        var timeRemainingFraction: Double?
        var expectedRemainingPct: Double?
        var expectedDescription: String?
        var pace: PaceOutput?
        var paceHistory: PaceOutput?
        /// 近期速度（每小時消耗的百分點）
        var recentRatePerHour: Double?
        var countdown: String?

        enum CodingKeys: String, CodingKey {
            case key, hidden, severity, state, duration, pace, countdown
            case displayName = "display_name"
            case isReset = "is_reset"
            case effectiveUsedPct = "effective_used_pct"
            case effectiveRemainingPct = "effective_remaining_pct"
            case remainingRounded = "remaining_rounded"
            case elapsedFraction = "elapsed_fraction"
            case timeRemainingFraction = "time_remaining_fraction"
            case expectedRemainingPct = "expected_remaining_pct"
            case expectedDescription = "expected_description"
            case paceHistory = "pace_history"
            case recentRatePerHour = "recent_rate_per_hour"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(displayName, forKey: .displayName)
            try c.encode(hidden, forKey: .hidden)
            try c.encode(isReset, forKey: .isReset)
            try c.encode(effectiveUsedPct, forKey: .effectiveUsedPct)
            try c.encode(effectiveRemainingPct, forKey: .effectiveRemainingPct)
            try c.encode(remainingRounded, forKey: .remainingRounded)
            try c.encode(severity, forKey: .severity)
            try c.encode(state, forKey: .state)
            try c.encode(duration, forKey: .duration)
            try c.encode(elapsedFraction, forKey: .elapsedFraction)
            try c.encode(timeRemainingFraction, forKey: .timeRemainingFraction)
            try c.encode(expectedRemainingPct, forKey: .expectedRemainingPct)
            try c.encode(expectedDescription, forKey: .expectedDescription)
            try c.encode(pace, forKey: .pace)
            try c.encode(paceHistory, forKey: .paceHistory)
            try c.encode(recentRatePerHour, forKey: .recentRatePerHour)
            try c.encode(countdown, forKey: .countdown)
        }
    }

    struct TokenOutput: Encodable {
        var value: Int64
        var short: String
        var full: String
    }

    struct CountdownOutput: Encodable {
        var seconds: Double
        var text: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(seconds, forKey: .seconds)
            try c.encode(text, forKey: .text)
        }

        enum CodingKeys: String, CodingKey { case seconds, text }
    }

    // MARK: - 計算

    static func compute() throws -> Output {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let input = try decoder.decode(Input.self, from: Data(contentsOf: casesURL))
        let epoch = Date(timeIntervalSince1970: 1_793_007_000)  // 倒數文字的基準時間（任意）
        return Output(
            cases: input.cases.map(caseOutput),
            tokenFormat: input.tokenFormat.map { TokenOutput(value: $0, short: TokenFormat.short($0), full: TokenFormat.full($0)) },
            countdown: input.countdownSeconds.map {
                CountdownOutput(seconds: $0, text: ResetCountdown.text(until: epoch.addingTimeInterval($0), now: epoch))
            },
            updated: input.updatedSeconds.map {
                CountdownOutput(seconds: $0, text: ResetCountdown.updatedText(since: epoch.addingTimeInterval(-$0), now: epoch))
            },
            duration: input.durationSeconds.map { .object(["seconds": .int($0), "text": .string(TokenFormat.duration($0))]) },
            tokenCases: input.tokenCases.map(tokenCaseOutput))
    }

    static func caseOutput(_ c: Case) -> CaseOutput {
        let snapshot = c.snapshot
        let now = c.now
        let stale = snapshot.isStale(now: now)
        let history = QuotaHistory(samples: (c.samples ?? []).map {
            QuotaSample(ts: $0.ts, provider: $0.provider, windowID: $0.window, usedPct: $0.usedPct, resetsAt: $0.resetsAt)
        }, runs: (c.runs ?? []).map { CollectorRun(ts: $0.ts, ok: $0.ok ?? 1, runs: $0.runs ?? 1) })
        let chosen = snapshot.window(for: MenuBarWindowChoice(rawValue: c.choice ?? "auto"), at: now)
        var windows: [WindowOutput] = []
        for provider in snapshot.orderedProviderKeys {
            for window in snapshot.providers[provider]?.windows ?? [] {
                let item = ProviderWindow(provider: provider, window: window)
                let rate = history.recentRate(provider: provider, windowID: window.id, now: now)
                windows.append(WindowOutput(
                    key: item.key,
                    displayName: item.displayName,
                    hidden: window.hidden,
                    isReset: window.isReset(at: now),
                    effectiveUsedPct: round9(window.effectiveUsedPct(at: now)),
                    effectiveRemainingPct: round9(window.effectiveRemainingPct(at: now)),
                    remainingRounded: Int(window.effectiveRemainingPct(at: now).rounded()),
                    severity: window.effectiveSeverity(at: now) == .critical ? "critical" : "normal",
                    state: stateName(MenuBarState(window: window, stale: stale, now: now)),
                    duration: window.duration,
                    elapsedFraction: window.elapsedFraction(at: now).map(round9),
                    timeRemainingFraction: window.timeRemainingFraction(at: now).map(round9),
                    expectedRemainingPct: window.expectedRemainingPct(at: now).map(round9),
                    expectedDescription: window.expectedRemainingDescription(at: now),
                    pace: UsagePace(window: window, stale: stale, now: now).map(paceOutput),
                    paceHistory: UsagePace(window: window, provider: provider, history: history, stale: stale, now: now).map(paceOutput),
                    recentRatePerHour: rate.map { round9($0 * 3600) },
                    countdown: window.resetsAt.flatMap { ResetCountdown.text(until: $0, now: now) }))
            }
        }
        return CaseOutput(
            name: c.name,
            stale: stale,
            hasNoProviders: snapshot.hasNoProviders,
            orderedProviders: snapshot.orderedProviderKeys,
            tightest: snapshot.tightestWindow(at: now)?.key,
            chosen: chosen?.key,
            chosenState: chosen.map { stateName(MenuBarState(window: $0.window, stale: stale, now: now)) },
            leastLabel: snapshot.tightestWindow(at: now)?.leastRemainingAccessibilityLabel(at: now),
            windows: windows,
            history: historyOutput(c, snapshot: snapshot, history: history))
    }

    static func paceOutput(_ pace: UsagePace) -> PaceOutput {
        PaceOutput(aheadBy: round9(pace.aheadBy),
                   exhaustsAt: pace.exhaustsAt.map { Int64($0.timeIntervalSince1970.rounded()) },
                   tooFast: pace.isTooFast)
    }

    static func stateName(_ state: MenuBarState) -> String {
        switch state {
        case .normal: "normal"
        case .tooFast: "too_fast"
        case .critical: "critical"
        case .stale: "stale"
        }
    }

    static func round9(_ x: Double) -> Double { (x * 1e9).rounded() / 1e9 }

    // MARK: - 比對

    static func compare(_ expected: Any, _ actual: Any, path: String, into differences: inout [String]) {
        switch (expected, actual) {
        case let (e as [String: Any], a as [String: Any]):
            for key in Set(e.keys).union(a.keys).sorted() {
                guard let ev = e[key], let av = a[key] else {
                    differences.append("\(path).\(key)：\(e[key] == nil ? "golden 沒有" : "計算結果沒有")")
                    continue
                }
                compare(ev, av, path: "\(path).\(key)", into: &differences)
            }
        case let (e as [Any], a as [Any]):
            guard e.count == a.count else {
                differences.append("\(path)：長度 \(e.count) ≠ \(a.count)")
                return
            }
            for (i, (ev, av)) in zip(e, a).enumerated() { compare(ev, av, path: "\(path)[\(i)]", into: &differences) }
        case let (e as NSNumber, a as NSNumber):
            // Bool 也是 NSNumber：兩邊都是整數或布林時直接比，浮點容許誤差
            if abs(e.doubleValue - a.doubleValue) > 1e-9 { differences.append("\(path)：\(e) ≠ \(a)") }
        case let (e as String, a as String):
            if e != a { differences.append("\(path)：「\(e)」≠「\(a)」") }
        case (is NSNull, is NSNull):
            break
        default:
            differences.append("\(path)：\(expected) ≠ \(actual)")
        }
    }
}
