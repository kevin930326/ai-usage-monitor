import Foundation
import Testing
@testable import UsageKit

/// 角色畫面（`MascotDirector`）的跨平台一致性（ADR-0016 第 1 節）：讀 `fixtures/mascot-director/cases.json` 的事件串，
/// 在取樣時間算出姿勢、眼睛、表情、眨眼、視線、面板外形、內容、特效與漣漪，和 `golden.json` 比對。Windows 的 C# 測試
/// （UsageCore.Tests MascotDirectorGoldenTests）讀同一份輸入，必須算出同樣的值（數字容許 1e-6）。
///
/// 每個取樣是一行字串（`MascotDirectorGoldenTests.columns` 的順序，空白分隔），數字取 6 位小數。
/// 規則有意改變時：`AUM_UPDATE_GOLDEN=1 swift test --filter MascotDirectorGoldenTests` 重新產生，
/// 檢查 `git diff` 後和 C# 的修改一起提交。
@Suite struct MascotDirectorGoldenTests {
    static let folder = FixtureTests.folder.appendingPathComponent("mascot-director")

    /// 一行取樣的欄位（golden.json 的 `columns` 也寫這份，方便看）
    static let columns = ["t", "eyes", "mood", "blink", "gaze_yaw", "gaze_pitch", "panel_w", "panel_h", "panel_corner", "mini",
                          "progress", "content_opacity", "content_offset", "status", "animating", "idle_moving", "sleep", "doze",
                          "effects", "edge_flash", "ring0"] + MascotProp.allCases.map { "\($0)" }

    struct Input: Decodable {
        var cases: [Case]
    }

    struct Case: Decodable {
        var name: String
        var events: [Event]
        var samples: [Range]
    }

    struct Range: Decodable {
        var from: Int
        var to: Int
        var step: Int
    }

    struct Event: Decodable {
        var t: Int
        var e: String
        var intro: Bool?
        var name: String?
        var choice: String?
        var on: Bool?
        var level: Int?
        var react: Bool?
        var dx: Double?
        var dy: Double?
        var snap: Bool?
    }

    struct Output: Codable, Equatable {
        var name: String
        var samples: [String]
    }

    static func number(_ value: Double) -> String {
        let text = String(format: "%.6f", value)
        return text == "-0.000000" ? "0.000000" : text
    }

    static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    static func sample(_ director: MascotDirector, at t: Int) -> String {
        let gaze = director.gaze(at: t)
        let shape = director.panelShape(at: t)
        let content = director.content(at: t)
        let effects = director.effects.compactMap { effect -> String? in
            guard let progress = effect.progress(at: t) else { return nil }
            let kind = switch effect.kind {
            case .heart: "heart"
            case .bang: "bang"
            case .ring(let level): "ring\(level)"
            }
            return "\(kind)@\(number(progress))"
        }
        let ring0 = director.ripple.flatMap { ripple in ripple.rings.first.flatMap { ripple.ringState($0, at: t) } }
        var fields = ["\(t)", director.eyes(at: t).rawValue, director.mood(at: t).rawValue, number(director.blink(at: t)),
                      number(gaze.yaw), number(gaze.pitch), number(shape.width), number(shape.height), number(shape.corner),
                      number(shape.miniOpacity), number(shape.progress), number(content.opacity), number(content.offset),
                      number(director.statusColor(at: t)), flag(director.isAnimating(at: t)), flag(director.isIdleMoving(at: t)),
                      flag(director.showsSleep), flag(director.showsDoze), effects.isEmpty ? "-" : effects.joined(separator: ","),
                      number(director.ripple?.edgeFlashAlpha(at: t, halfWidth: 290) ?? 0),
                      ring0.map { "\(number($0.radius))/\(number($0.fade))" } ?? "-"]
        let pose = director.pose(at: t)
        fields += MascotProp.allCases.map { number(pose[$0]) }
        return fields.joined(separator: " ")
    }

    static func run(_ testCase: Case, config: MascotConfig) throws -> Output {
        var director = MascotDirector(config: config)
        var times = Set<Int>()
        for range in testCase.samples { times.formUnion(stride(from: range.from, through: range.to, by: range.step)) }
        var events = testCase.events[...]
        var samples: [String] = []
        for t in times.sorted() {
            while let event = events.first, event.t <= t {
                events = events.dropFirst()
                director.advance(to: event.t)
                try apply(event, to: &director, caseName: testCase.name)
            }
            director.advance(to: t)
            samples.append(sample(director, at: t))
        }
        return Output(name: testCase.name, samples: samples)
    }

    static func apply(_ event: Event, to director: inout MascotDirector, caseName: String) throws {
        let t = event.t
        switch event.e {
        case "open": director.open(at: t, intro: event.intro ?? false)
        case "close": director.close(at: t)
        case "request": director.request(try #require(MascotRequest(rawValue: event.name ?? "")), at: t)
        case "gesture": director.gesture(try #require(MascotGesture(rawValue: event.name ?? "")), at: t)
        case "click": director.click(at: t, choice: try #require(MascotRequest(rawValue: event.choice ?? "")))
        case "press": director.press(at: t)
        case "release": director.release(at: t)
        case "working": director.setWorking(event.on ?? false, at: t)
        case "idle": director.setAgentIdle(event.on ?? false, at: t)
        case "needs": director.setNeedsYou(event.on ?? false, at: t)
        case "cheer": director.cheer(at: t, react: event.react ?? true)
        case "status": director.setStatus(event.level ?? 0, at: t, react: event.react ?? true)
        case "look": director.look(at: t, dx: event.dx ?? 0, dy: event.dy ?? 0, snap: event.snap ?? false)
        case "still": director.setStill(event.on ?? false, at: t)
        case "mood": director.setMood(try #require(MascotMood(rawValue: event.name ?? "")))
        case "face": director.requestFace(try #require(MascotMood(rawValue: event.name ?? "")), at: t)
        default: Issue.record("未知的事件 \(event.e)（\(caseName)）")
        }
    }

    @Test func goldenMatchesDirector() throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: Self.folder.appendingPathComponent("cases.json")))
        let config = try MascotDirectorTests.config()
        let outputs = try input.cases.map { try Self.run($0, config: config) }
        let goldenURL = Self.folder.appendingPathComponent("golden.json")
        if ProcessInfo.processInfo.environment["AUM_UPDATE_GOLDEN"] == "1" {
            // 每個取樣一行：手寫 JSON，git diff 才看得出是哪個時間點變了
            var text = "{\n  \"columns\": \"\(Self.columns.joined(separator: " "))\",\n  \"cases\": [\n"
            text += outputs.enumerated().map { index, output in
                let lines = output.samples.map { "        \"\($0)\"" }.joined(separator: ",\n")
                return "    {\n      \"name\": \"\(output.name)\",\n      \"samples\": [\n\(lines)\n      ]\n    }"
                    + (index == outputs.count - 1 ? "" : ",")
            }.joined(separator: "\n")
            text += "\n  ]\n}\n"
            try Data(text.utf8).write(to: goldenURL)
            return
        }
        struct Golden: Decodable { var columns: String; var cases: [Output] }
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: goldenURL))
        #expect(golden.columns == Self.columns.joined(separator: " "))
        #expect(golden.cases.map(\.name) == outputs.map(\.name), "golden.json 的情境與 cases.json 不同（以 AUM_UPDATE_GOLDEN=1 重新產生）")
        for (expected, actual) in zip(golden.cases, outputs) {
            #expect(expected.samples.count == actual.samples.count, "\(actual.name)：取樣數不同")
            for (line, (want, got)) in zip(expected.samples, actual.samples).enumerated() where !Self.matches(want, got) {
                Issue.record("\(actual.name) 第 \(line) 個取樣：\n預期 \(want)\n實際 \(got)")
                break
            }
        }
    }

    /// 文字欄位一樣、數字差不到 1e-6
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: " "), y = b.split(separator: " ")
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { p, q in
            if p == q { return true }
            let ps = p.split(whereSeparator: { ",/@".contains($0) }), qs = q.split(whereSeparator: { ",/@".contains($0) })
            guard ps.count == qs.count else { return false }
            return zip(ps, qs).allSatisfy { u, v in
                if u == v { return true }
                guard let m = Double(u), let n = Double(v) else { return false }
                return abs(m - n) <= 1e-6 + 1e-9
            }
        }
    }
}
