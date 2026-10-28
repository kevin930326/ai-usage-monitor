import Foundation
import Testing
@testable import UsageKit

/// AI 狀態的跨平台一致性（ADR-0017）：讀 `fixtures/agent/cases.json`，用 UsageKit 的
/// `AgentHookInput`、`AgentHookMessage`、`AgentSessions` 算出結果，和 `fixtures/agent/golden.json` 比對。
/// Windows 的 C# 測試讀同一份輸入，必須算出同樣的結果。
///
/// 規則有意改變時：`AUM_UPDATE_GOLDEN=1 swift test --filter AgentGoldenTests` 重新產生 golden.json，
/// 檢查 `git diff` 後和 C# 的修改一起提交。
@Suite struct AgentGoldenTests {
    static let folder = FixtureTests.folder.appendingPathComponent("agent")

    struct Input: Decodable {
        var inputs: [Raw]
        var messages: [Raw]
        var sessions: [SessionCase]
    }

    struct Raw: Decodable {
        var name: String
        var raw: String
    }

    struct SessionCase: Decodable {
        var name: String
        var idle_after_ms: Int64?
        var events: [Event]
    }

    struct Event: Decodable {
        var t: Int64
        var e: String
        var ai: String?
        var ev: String?
        var need: String?
        var sid: String?
        var dir: String?
    }

    struct Output: Codable, Equatable {
        var inputs: [Named]
        var messages: [Named]
        var sessions: [Named]
    }

    struct Named: Codable, Equatable {
        var name: String
        var result: [String]
    }

    static func extract(_ raw: Raw) -> Named {
        guard let input = AgentHookInput.extract(Data(raw.raw.utf8)) else { return Named(name: raw.name, result: ["nil"]) }
        return Named(name: raw.name, result: ["event=\(input.event.rawValue)", "need=\(input.need?.rawValue ?? "")",
                                              "session=\(input.sessionID)", "folder=\(input.folder)"])
    }

    static func parse(_ raw: Raw) -> Named {
        guard let message = AgentHookMessage.parse(Data(raw.raw.utf8)) else { return Named(name: raw.name, result: ["nil"]) }
        return Named(name: raw.name, result: [String(decoding: message.encoded(), as: UTF8.self)])
    }

    static func describe(_ sessions: AgentSessions, at now: Int64) -> String {
        let list = sessions.ordered(at: now).map { s in
            let state = s.state(at: now, idleAfter: sessions.idleAfter)
            return "\(s.ai.rawValue)/\(s.id.prefix(4))/\(s.folder):\(state.rawValue)\(s.need.map { "(\($0.rawValue))" } ?? "")@\(s.since)"
        }
        let top = sessions.top(at: now).map { "\($0.ai.rawValue)/\($0.id.prefix(4))" } ?? "none"
        return "top=\(top) [\(list.joined(separator: ", "))]"
    }

    static func run(_ testCase: SessionCase) -> Named {
        var sessions = AgentSessions(idleAfter: testCase.idle_after_ms ?? 300_000)
        var log: [String] = []
        for event in testCase.events {
            switch event.e {
            case "msg":
                let message = AgentHookMessage(ai: AgentKind(rawValue: event.ai!)!, event: AgentHookEvent(rawValue: event.ev!)!,
                                               need: event.need.flatMap(AgentNeed.init(rawValue:)), session: event.sid!,
                                               time: event.t, folder: event.dir ?? "")
                sessions.apply(message, at: event.t)
                log.append("\(event.t) \(event.ai!) \(event.ev!)\(event.need.map { $0.isEmpty ? "" : "(\($0))" } ?? "") → \(describe(sessions, at: event.t))")
            case "seen":
                sessions.markSeen(at: event.t)
                log.append("\(event.t) seen → \(describe(sessions, at: event.t))")
            case "expire":
                let changed = sessions.expire(at: event.t)
                log.append("\(event.t) expire\(changed ? "" : " (no change)") → \(describe(sessions, at: event.t))")
            default:
                Issue.record("不認得的事件 \(event.e)")
            }
        }
        return Named(name: testCase.name, result: log)
    }

    @Test func matchesGolden() throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: Self.folder.appendingPathComponent("cases.json")))
        let output = Output(inputs: input.inputs.map(Self.extract), messages: input.messages.map(Self.parse),
                            sessions: input.sessions.map(Self.run))
        let goldenURL = Self.folder.appendingPathComponent("golden.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if ProcessInfo.processInfo.environment["AUM_UPDATE_GOLDEN"] == "1" {
            try (encoder.encode(output) + Data("\n".utf8)).write(to: goldenURL)
        }
        let golden = try JSONDecoder().decode(Output.self, from: Data(contentsOf: goldenURL))
        for (expected, actual) in zip(golden.inputs + golden.messages + golden.sessions,
                                      output.inputs + output.messages + output.sessions) {
            #expect(expected == actual, "\(actual.name)：\n預期 \(expected.result)\n實際 \(actual.result)")
        }
        #expect(golden.inputs.count == output.inputs.count && golden.messages.count == output.messages.count
                && golden.sessions.count == output.sessions.count, "golden.json 與 cases.json 的情境數不同")
    }

    /// 隱私：擷取的結果只有事件、種類、ID、資料夾名稱，提示與工具內容不會出現在任何欄位
    @Test func extractDropsContent() throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: Self.folder.appendingPathComponent("cases.json")))
        for raw in input.inputs {
            let joined = Self.extract(raw).result.joined(separator: "\n")
            for secret in ["id_rsa", "rm -rf", "secret?", "/etc/passwd", "curl", "secret answer", "/Users/me", ".jsonl", "step 1"] {
                #expect(!joined.contains(secret), "\(raw.name) 帶出了 \(secret)")
            }
        }
    }

    /// 送出的一行一定能被 App 接受，而且不超過長度上限（最長的資料夾名稱與 ID）
    @Test func encodedMessageRoundTrips() {
        let message = AgentHookMessage(ai: .codex, event: .postToolUseFailure, need: .permission, session: "0123456789abcdef",
                                       time: Int64.max, folder: String(repeating: "名", count: AgentHookInput.maxFolder))
        let data = message.encoded()
        #expect(data.count <= AgentHookMessage.maxLength)
        #expect(AgentHookMessage.parse(data) == message)
    }

    @Test func installedEventsAreHandled() {
        for ai in AgentKind.allCases {
            #expect(!AgentHookEvent.installed(for: ai).isEmpty)
        }
        #expect(!AgentHookEvent.installed(for: .codex).contains(.notification), "Codex 沒有 Notification 事件")
        #expect(!AgentHookEvent.installed(for: .claude).contains(.interrupt), "Claude Code 沒有 Interrupt 事件")
    }
}
