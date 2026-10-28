#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import UsageKit

/// hook 與 App 之間的 Unix socket（ADR-0017 第 2 節）：在暫存資料夾裡實際收送，不碰真的資料夾
@Suite(.serialized) struct AgentSocketTests {
    /// sun_path 只有 104 位元組：用短的暫存路徑
    static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/aum-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    static let claudeEvent = Data("""
    {"session_id":"sess-1","transcript_path":"/Users/me/.claude/projects/p/sess-1.jsonl","cwd":"/Users/me/work/alpha",
     "hook_event_name":"UserPromptSubmit","prompt":"print my secrets"}
    """.utf8)

    @Test func prepareCreatesPrivateFolderAndSalt() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let salt = try AgentSocket.prepare(in: dir)
        #expect(salt.count == 32)
        #expect(try Self.permissions(AgentSocket.folder(in: dir)) == 0o700)
        #expect(try Self.permissions(AgentSocket.saltURL(in: dir)) == 0o600)
        // 第二次沿用同一個鹽
        #expect(try AgentSocket.prepare(in: dir) == salt)
        #expect(AgentSocket.readSalt(in: dir) == salt)
    }

    @Test func hookSendsOnlyTheAllowedFieldsToTheApp() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let salt = try AgentSocket.prepare(in: dir)
        let server = try AgentSocket.listen(at: AgentSocket.socketURL(in: dir))
        defer { close(server) }
        #expect(try Self.permissions(AgentSocket.socketURL(in: dir)) == 0o600)

        let received = Task.detached { () -> AgentHookMessage? in
            let client = accept(server, nil, nil)
            return client >= 0 ? AgentSocket.receive(on: client) : nil
        }
        let now = Date(timeIntervalSince1970: 1_761_650_000)
        #expect(AgentHookRunner.run(ai: .claude, input: Self.claudeEvent, directory: dir, now: now))
        let message = try #require(await received.value)
        #expect(message == AgentHookMessage(ai: .claude, event: .userPromptSubmit, need: nil,
                                            session: AgentSocket.sessionHash("sess-1", salt: salt),
                                            time: 1_761_650_000_000, folder: "alpha"))
        #expect(message.session != "sess-1" && AgentHookMessage.isSessionHash(message.session))
    }

    @Test func hookGivesUpQuicklyWhenTheAppIsNotRunning() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 沒有鹽（App 沒跑過）
        #expect(!AgentHookRunner.run(ai: .claude, input: Self.claudeEvent, directory: dir))
        // 有鹽但沒有 socket（App 沒在跑）
        _ = try AgentSocket.prepare(in: dir)
        let start = Date.now
        #expect(!AgentHookRunner.run(ai: .claude, input: Self.claudeEvent, directory: dir))
        // 有 socket 檔但沒人聽（App 當掉留下的）
        let stale = try AgentSocket.listen(at: AgentSocket.socketURL(in: dir))
        close(stale)
        #expect(!AgentHookRunner.run(ai: .claude, input: Self.claudeEvent, directory: dir))
        #expect(Date.now.timeIntervalSince(start) < 0.5)
    }

    @Test func hookIgnoresEventsItDoesNotUnderstand() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try AgentSocket.prepare(in: dir)
        for input in ["", "not json", #"{"hook_event_name":"FileChanged","session_id":"a"}"#] {
            #expect(!AgentHookRunner.run(ai: .codex, input: Data(input.utf8), directory: dir))
        }
    }

    @Test func appDropsGarbageAndOversizedLines() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try AgentSocket.prepare(in: dir)
        let server = try AgentSocket.listen(at: AgentSocket.socketURL(in: dir))
        defer { close(server) }
        for payload in [Data("hello\n".utf8), Data(repeating: UInt8(ascii: "x"), count: 5000), Data()] {
            let received = Task.detached { () -> AgentHookMessage? in
                let client = accept(server, nil, nil)
                return client >= 0 ? AgentSocket.receive(on: client) : nil
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = AgentSocket.socketURL(in: dir).path
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let ok = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(ok == 0)
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            #expect(await received.value == nil)
        }
    }

    @Test func sessionHashIsSaltedAndStable() {
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
        #expect(AgentSocket.sessionHash("x", salt: a) == AgentSocket.sessionHash("x", salt: a))
        #expect(AgentSocket.sessionHash("x", salt: a) != AgentSocket.sessionHash("x", salt: b))
        #expect(AgentHookMessage.isSessionHash(AgentSocket.sessionHash("x", salt: a)))
    }
}
#endif
