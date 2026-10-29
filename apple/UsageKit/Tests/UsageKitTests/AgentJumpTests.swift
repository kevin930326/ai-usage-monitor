import Foundation
import Testing
@testable import UsageKit

/// 點工作階段跳回那個 session（ADR-0017 第 10 節）：`fixtures/agent-jump/cases.json` 的程序樹、tmux 輸出與 tty，
/// C# 的 `AgentJumpTests` 跑同一份
@Suite struct AgentJumpTests {
    static let folder = FixtureTests.folder.appendingPathComponent("agent-jump")

    struct Cases: Decodable {
        var walk: [Walk]
        var tmux: [Tmux]
        var tty: [TTY]
    }

    struct Walk: Decodable {
        struct Process: Decodable {
            var pid: Int32
            var ppid: Int32
            var start: Int64
            var name: String
            var bundle: String?
            var tty: String?
            var window: Bool?
        }

        struct Mac: Decodable {
            var kind: String
            var pid: Int32?
            var bundle: String?
            var tty: String?
        }

        struct Windows: Decodable {
            var pid: Int32
        }

        var name: String
        var processes: [Process]
        var ai: Int32
        var start: Int64?
        var mac: Mac
        var windows: Windows?
    }

    struct Tmux: Decodable {
        struct Plan: Decodable {
            var pane: String
            var session: String
            var client_tty: String
            var client_pid: Int32
            var `switch`: Bool
        }

        var name: String
        var panes: String
        var clients: String
        var tty: String
        var plan: Plan?
    }

    struct TTY: Decodable {
        var value: String
        var valid: Bool
    }

    static func load() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: folder.appendingPathComponent("cases.json")))
    }

    static func hosts() throws -> AgentHosts {
        let url = FixtureTests.folder.deletingLastPathComponent().appendingPathComponent("shared/agent-hosts.json")
        return AgentHosts.decode(try Data(contentsOf: url))
    }

    @Test func walksTheProcessTree() throws {
        let hosts = try Self.hosts()
        for c in try Self.load().walk {
            let table = Dictionary(uniqueKeysWithValues: c.processes.map {
                ($0.pid, AgentJump.Process(pid: $0.pid, parent: $0.ppid, start: $0.start, name: $0.name, bundleID: $0.bundle,
                                           tty: $0.tty, hasWindow: $0.window ?? false))
            })
            let expected: AgentJump.Target = switch c.mac.kind {
            case "app": .app(pid: c.mac.pid ?? 0, bundleID: c.mac.bundle ?? "", tty: c.mac.tty)
            case "tmux": .tmux(tty: c.mac.tty ?? "")
            default: .none
            }
            #expect(AgentJump.macTarget(ai: c.ai, start: c.start, hosts: hosts) { table[$0] } == expected, "\(c.name)")
            #expect(AgentJump.windowsTarget(ai: c.ai, start: c.start, hosts: hosts) { table[$0] } == c.windows?.pid, "\(c.name)")
        }
    }

    @Test func parsesTmuxOutput() throws {
        for c in try Self.load().tmux {
            let plan = AgentJump.plan(panes: AgentJump.panes(c.panes), clients: AgentJump.clients(c.clients), tty: c.tty)
            #expect(plan?.pane == c.plan?.pane, "\(c.name)")
            #expect(plan?.session == c.plan?.session, "\(c.name)")
            #expect(plan?.client.tty == c.plan?.client_tty, "\(c.name)")
            #expect(plan?.client.pid == c.plan?.client_pid, "\(c.name)")
            #expect(plan?.switchClient == c.plan?.switch, "\(c.name)")
        }
    }

    @Test func validatesTTY() throws {
        for c in try Self.load().tty {
            #expect(AgentJump.isValidTTY(c.value) == c.valid, "\(c.value.debugDescription)")
        }
    }
}
