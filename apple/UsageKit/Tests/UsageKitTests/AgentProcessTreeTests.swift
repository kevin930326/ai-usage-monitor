#if os(macOS)
import Foundation
import Testing
@testable import UsageKit

/// 程序樹（ADR-0017 第 7 節）：只看 PID、父 PID、開始時間；hook 的父程序是 shell 時 AI 是再上一層
@Suite struct AgentProcessTreeTests {
    @Test func findsChildrenAndGrandchildrenOnly() throws {
        // sh 底下再開一個 sleep：孫程序也要找得到
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "/bin/sleep 30; true"]
        try child.run()
        defer { child.terminate() }
        let me = getpid()
        var found: Set<AgentProcess> = []
        for _ in 0..<50 {
            found = AgentProcessTree.descendants(of: me) ?? []
            if found.count >= 2 { break }
            usleep(20_000)
        }
        let pids = Set(found.map(\.pid))
        #expect(pids.contains(child.processIdentifier))
        #expect(found.count >= 2, "sh 底下的 sleep 也要算")
        #expect(!pids.contains(me))
        // 開始時間不同（PID 被重用）就當成不在
        let start = try #require(AgentProcessTree.start(me))
        #expect(AgentProcessTree.descendants(of: me, start: start) != nil)
        #expect(AgentProcessTree.descendants(of: me, start: start + 1) == nil)
    }

    @Test func missingProcessIsNil() {
        #expect(AgentProcessTree.descendants(of: 999_999) == nil)
        #expect(AgentProcessTree.start(999_999) == nil)
    }

    /// 假事件填 launchd 或別的使用者的程序：不列整台電腦的程序（Fable F-02）
    @Test func otherUsersProcessesAreNotListed() {
        #expect(AgentProcessTree.descendants(of: 1) == nil)
        #expect(AgentProcessTree.descendants(of: 0) == nil)
    }

    @Test func hookParentShellIsSkipped() throws {
        // 測試程序的父程序不是 shell：就是它自己
        #expect(AgentProcessTree.aiProcess(hookParent: getpid()) == getpid())
        #expect(AgentProcessTree.aiProcess(hookParent: 1) == 0)
        // sh 當父程序：往上一層是我們
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sleep 30; true"]
        try shell.run()
        defer { shell.terminate() }
        usleep(100_000)
        #expect(AgentProcessTree.aiProcess(hookParent: shell.processIdentifier) == getpid())
    }
}
#endif
