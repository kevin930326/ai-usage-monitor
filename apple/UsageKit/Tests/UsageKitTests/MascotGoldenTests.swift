import Foundation
import Testing
@testable import UsageKit

/// 角色狀態機的跨平台一致性（ADR-0016）：讀 `fixtures/mascot/cases.json` 的事件串，用 UsageKit 的
/// `MascotMachine` 排出播放紀錄，和 `fixtures/mascot/golden.json` 比對。Windows 的 C# 測試讀同一份輸入，
/// 必須排出同樣的紀錄。時間參數讀 `shared/mascot-anim.json`。
///
/// 規則有意改變時：`AUM_UPDATE_GOLDEN=1 swift test --filter MascotGoldenTests` 重新產生 golden.json，
/// 檢查 `git diff` 後和 C# 的修改一起提交。
@Suite struct MascotGoldenTests {
    static let repo = FixtureTests.folder.deletingLastPathComponent()
    static let folder = FixtureTests.folder.appendingPathComponent("mascot")
    static let configURL = repo.appendingPathComponent("shared/mascot-anim.json")

    static func timing() throws -> MascotTiming {
        try MascotTiming.decode(fromConfig: Data(contentsOf: configURL))
    }

    struct Input: Decodable {
        var cases: [Case]
    }

    struct Case: Decodable {
        var name: String
        var events: [Event]
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
    }

    struct Output: Codable, Equatable {
        var name: String
        var log: [String]
        var final: Final
    }

    struct Final: Codable, Equatable {
        var open: Bool
        var mode: String
        /// 臉跟著游標轉（`followsPointer`）
        var follow: Bool
        var playing: String?
        var pending: String?
        var queued: String?
        var status: Int
    }

    static func run(_ testCase: Case, timing: MascotTiming) throws -> Output {
        var machine = MascotMachine(timing: timing)
        for event in testCase.events {
            switch event.e {
            case "open": machine.open(at: event.t, intro: event.intro ?? false)
            case "close": machine.close(at: event.t)
            case "request": machine.request(try #require(MascotRequest(rawValue: event.name ?? "")), at: event.t)
            case "gesture": machine.gesture(try #require(MascotGesture(rawValue: event.name ?? "")), at: event.t)
            case "click": machine.click(at: event.t, choice: try #require(MascotRequest(rawValue: event.choice ?? "")))
            case "press": machine.press(at: event.t)
            case "release": machine.release(at: event.t)
            case "move": machine.move(at: event.t)
            case "working": machine.setWorking(event.on ?? false, at: event.t)
            case "idle": machine.setAgentIdle(event.on ?? false, at: event.t)
            case "status": machine.setStatus(event.level ?? 0, at: event.t, react: event.react ?? true)
            case "silence": machine.silence(at: event.t)
            case "needs": machine.setNeedsYou(event.on ?? false, at: event.t)
            case "background": machine.setBackground(event.on ?? false, at: event.t)
            case "cheer": machine.cheer(at: event.t, react: event.react ?? true)
            case "advance": machine.advance(to: event.t)
            default: Issue.record("未知的事件 \(event.e)（\(testCase.name)）")
            }
        }
        return Output(
            name: testCase.name,
            log: machine.log.map(\.description),
            final: Final(open: machine.isOpen, mode: machine.mode.rawValue, follow: machine.followsPointer,
                         playing: machine.playing?.animation.rawValue, pending: machine.pending?.rawValue,
                         queued: machine.queued?.rawValue,
                         status: machine.statusLevel))
    }

    @Test func goldenMatchesMachine() throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: Self.folder.appendingPathComponent("cases.json")))
        let timing = try Self.timing()
        let outputs = try input.cases.map { try Self.run($0, timing: timing) }
        let goldenURL = Self.folder.appendingPathComponent("golden.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if ProcessInfo.processInfo.environment["AUM_UPDATE_GOLDEN"] == "1" {
            try (encoder.encode(["cases": outputs]) + Data("\n".utf8)).write(to: goldenURL)
            return
        }
        let golden = try JSONDecoder().decode([String: [Output]].self, from: Data(contentsOf: goldenURL))["cases"] ?? []
        #expect(golden.map(\.name) == outputs.map(\.name), "golden.json 的情境與 cases.json 不同（以 AUM_UPDATE_GOLDEN=1 重新產生）")
        for (expected, actual) in zip(golden, outputs) {
            #expect(expected == actual, "\(actual.name)：\n預期 \(expected.log)\n實際 \(actual.log)")
        }
    }

    @Test func configHasEveryAnimationDuration() throws {
        let timing = try Self.timing()
        for animation in MascotAnimation.allCases {
            let key = MascotTiming.durationKey(of: animation)
            #expect(timing.durationsMs[key] != nil, "mascot-anim.json 缺少 \(key) 的長度")
        }
        // 規格第 5、6 節的數字
        #expect(timing.duration(of: .hop) == 900)
        #expect(timing.duration(of: .dizzy) == 2900)
        #expect(timing.restBeforeQueuedMs == 360)
        #expect(timing.clicksForDizzy == 5)
        #expect(timing.clickWindowMs == 1500)
        #expect(timing.introInteractiveMs == 4680)
    }

    @Test func tapReactionsMatchMachineKinds() throws {
        // 設定檔的短反應清單要和狀態機的 tap 類型一致
        struct File: Decodable { struct M: Decodable { var tap_reactions: [String] }; var machine: M }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.configURL))
        #expect(file.machine.tap_reactions == MascotRequest.taps.map(\.rawValue))
    }

    /// 有排隊的就一定有下一個到期時間（golden 只比紀錄，這裡確認不會卡住）
    @Test func queuedAlwaysHasDeadline() throws {
        var machine = MascotMachine(timing: try Self.timing())
        machine.open(at: 0, intro: false)
        machine.click(at: 0, choice: .hop)
        machine.setStatus(1, at: 100)
        machine.request(.wave, at: 950)
        machine.setStatus(0, at: 1000)
        machine.advance(to: 1300)
        #expect(machine.queued == nil || machine.nextDeadline != nil)
        machine.advance(to: 1700)
        #expect(machine.playing?.animation == .wave)
    }

    @Test func advanceIsIdempotentAndOrdered() throws {
        var machine = MascotMachine(timing: try Self.timing())
        machine.open(at: 0, intro: false)
        machine.request(.shy, at: 10)
        machine.advance(to: 5000)
        let once = machine.log
        machine.advance(to: 5000)
        machine.advance(to: 4000)   // 時間不會倒退
        #expect(machine.log == once)
        #expect(machine.now == 5000)
        #expect(zip(once, once.dropFirst()).allSatisfy { $0.time <= $1.time })
        machine.press(at: 3000)      // 事件時間比狀態機早：以目前時間為準
        machine.advance(to: 6000)
        #expect(zip(machine.log, machine.log.dropFirst()).allSatisfy { $0.time <= $1.time })
    }
}
