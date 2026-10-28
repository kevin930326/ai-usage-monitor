import Foundation
import Testing
@testable import UsageKit

/// 合併 hook 到 Claude Code／Codex 的設定（ADR-0017 第 3 節）：只用假的設定內容，不碰真的 ~/.claude、~/.codex
@Suite struct AgentHookConfigTests {
    static let app = "/Applications/AI Usage Monitor.app/Contents/Helpers/aum-hook"
    static let moved = "/Users/me/Downloads/AI Usage Monitor.app/Contents/Helpers/aum-hook"
    static let claude = AgentHookConfig.command(executable: app, ai: .claude)

    /// 使用者原本的設定：有其他鍵、別人的 hook（另一個瀏海 App）、奇怪的跳脫寫法與數字
    static let existing = """
    {
      "model": "opus",
      "env": {"A": "caf\\u00e9", "N": 1.50},
      "hooks": {
        "Stop": [
          {"matcher": "", "hooks": [{"type": "command", "command": "/usr/local/bin/other-notch-app stop"}]}
        ],
        "PreToolUse": [
          {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard.sh"}]}
        ]
      },
      "permissions": {"allow": []}
    }
    """

    static func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func commands(_ data: Data, event: String) throws -> [String] {
        let hooks = try #require(try json(data)["hooks"] as? [String: Any])
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test func commandIsShellQuoted() {
        #expect(Self.claude == "'/Applications/AI Usage Monitor.app/Contents/Helpers/aum-hook' claude")
        #expect(AgentHookConfig.command(executable: "/a/it's/Contents/Helpers/aum-hook", ai: .codex)
                == "'/a/it'\\''s/Contents/Helpers/aum-hook' codex")
    }

    @Test func installIntoEmptyOrMissingFile() throws {
        for original in [nil, Data(), Data("  \n".utf8), Data("{}".utf8)] {
            let data = try AgentHookConfig.install(into: original, ai: .claude, command: Self.claude)
            for event in AgentHookEvent.installed(for: .claude) {
                #expect(try Self.commands(data, event: event.rawValue) == [Self.claude])
            }
            #expect(try AgentHookConfig.status(of: data, ai: .claude, command: Self.claude) == .installed)
        }
    }

    @Test func installKeepsOtherKeysOrderAndOtherHooks() throws {
        let data = try AgentHookConfig.install(into: Data(Self.existing.utf8), ai: .claude, command: Self.claude)
        let text = String(decoding: data, as: UTF8.self)
        // 鍵的順序與原始寫法不變
        let order = ["\"model\"", "\"env\"", "\"hooks\"", "\"permissions\""].map { text.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        #expect(text.contains("caf\\u00e9") && text.contains("1.50"))
        // 別人的 hook 保留，我們的另外加一組
        #expect(try Self.commands(data, event: "Stop") == ["/usr/local/bin/other-notch-app stop", Self.claude])
        #expect(try Self.commands(data, event: "PreToolUse") == ["~/bin/guard.sh", Self.claude])
        let parsed = try Self.json(data)
        #expect(parsed["model"] as? String == "opus")
        #expect((parsed["env"] as? [String: Any])?["A"] as? String == "café")
    }

    @Test func installTwiceDoesNotDuplicate() throws {
        let once = try AgentHookConfig.install(into: Data(Self.existing.utf8), ai: .claude, command: Self.claude)
        let twice = try AgentHookConfig.install(into: once, ai: .claude, command: Self.claude)
        #expect(once == twice)
    }

    @Test func movedAppNeedsRepairAndRepairReplacesThePath() throws {
        let old = try AgentHookConfig.install(into: Data(Self.existing.utf8), ai: .claude,
                                              command: AgentHookConfig.command(executable: Self.moved, ai: .claude))
        #expect(try AgentHookConfig.status(of: old, ai: .claude, command: Self.claude) == .needsRepair(missing: [], wrongPath: true))
        let fixed = try AgentHookConfig.install(into: old, ai: .claude, command: Self.claude)
        #expect(try Self.commands(fixed, event: "Stop") == ["/usr/local/bin/other-notch-app stop", Self.claude])
        #expect(try AgentHookConfig.status(of: fixed, ai: .claude, command: Self.claude) == .installed)
    }

    @Test func missingEventNeedsRepair() throws {
        let partial = try AgentHookConfig.install(into: nil, ai: .claude, command: Self.claude, events: [.stop, .sessionStart])
        let status = try AgentHookConfig.status(of: partial, ai: .claude, command: Self.claude)
        guard case .needsRepair(let missing, let wrongPath) = status else {
            Issue.record("應該要修：\(status)")
            return
        }
        #expect(!wrongPath && missing.contains(.notification) && !missing.contains(.stop))
    }

    @Test func uninstallRemovesOnlyOurs() throws {
        let installed = try AgentHookConfig.install(into: Data(Self.existing.utf8), ai: .claude, command: Self.claude)
        let removed = try #require(try AgentHookConfig.uninstall(from: installed))
        #expect(try Self.commands(removed, event: "Stop") == ["/usr/local/bin/other-notch-app stop"])
        #expect(try Self.commands(removed, event: "PreToolUse") == ["~/bin/guard.sh"])
        // 只有我們的事件被拿掉
        let hooks = try #require(try Self.json(removed)["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["Stop", "PreToolUse"])
        #expect(try AgentHookConfig.status(of: removed, ai: .claude, command: Self.claude) == .notInstalled)
        // 再移除一次：沒有我們的，不必寫檔
        #expect(try AgentHookConfig.uninstall(from: removed) == nil)
    }

    @Test func uninstallDropsEmptyHooksKey() throws {
        let original = Data("{\"model\": \"opus\"}".utf8)
        let installed = try AgentHookConfig.install(into: original, ai: .codex,
                                                    command: AgentHookConfig.command(executable: Self.app, ai: .codex))
        let removed = try #require(try AgentHookConfig.uninstall(from: installed))
        #expect(try Self.json(removed).keys.sorted() == ["model"])
    }

    @Test func ourHookSharingAGroupWithOthersKeepsTheOthers() throws {
        let shared = """
        {"hooks": {"Stop": [{"hooks": [
          {"type": "command", "command": "/x/other"},
          {"type": "command", "command": "'/Old/AI Usage Monitor.app/Contents/Helpers/aum-hook' claude"}
        ]}]}}
        """
        let removed = try #require(try AgentHookConfig.uninstall(from: Data(shared.utf8)))
        #expect(try Self.commands(removed, event: "Stop") == ["/x/other"])
    }

    @Test func refusesFilesItCannotUnderstand() {
        for bad in ["{\"hooks\": ", "[]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}", "// comment\n{}"] {
            #expect(throws: AgentHookConfig.ConfigError.self) {
                _ = try AgentHookConfig.install(into: Data(bad.utf8), ai: .claude, command: Self.claude)
            }
        }
    }

    @Test func orderedJSONRoundTripsValues() throws {
        let text = #"{"a":[1,2.50,-3e2,true,false,null],"b":{"c":"x\"y\\z\u263A\n","d":{}},"e":[]}"#
        let value = try OrderedJSON.parse(Data(text.utf8))
        let out = value.serialized()
        let a = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: out) as? NSDictionary
        #expect(a == b)
        #expect(String(decoding: out, as: UTF8.self).contains("2.50"))
        #expect(try OrderedJSON.parse(out) == value)
    }

    @Test func orderedJSONRejectsDeepNesting() {
        let deep = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        #expect(throws: OrderedJSON.ParseError.tooDeep) { try OrderedJSON.parse(Data(deep.utf8)) }
    }
}
