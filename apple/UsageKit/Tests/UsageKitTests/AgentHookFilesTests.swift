import Foundation
import Testing
@testable import UsageKit

/// 連接與移除 hook 的檔案操作（ADR-0017 第 3 節）：全部在暫存資料夾的假設定檔上做，不碰真的 ~/.claude、~/.codex
@Suite struct AgentHookFilesTests {
    let folder: URL
    let command = AgentHookConfig.command(executable: "/Applications/AI Usage.app/Contents/Helpers/aum-hook", ai: .claude)
    let now = Date(timeIntervalSince1970: 1_761_650_000)

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aum-hookfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var file: URL { folder.appendingPathComponent(".claude/settings.json") }

    @Test func connectCreatesTheFileWithoutBackupWhenMissing() throws {
        #expect(try AgentHookFiles.connect(file: file, ai: .claude, command: command, now: now) == .written(backup: nil))
        #expect(try AgentHookFiles.status(file: file, ai: .claude, command: command) == .installed)
        // 再按一次不改檔、不多一份備份
        #expect(try AgentHookFiles.connect(file: file, ai: .claude, command: command, now: now) == .unchanged)
        #expect(try backups().isEmpty)
    }

    @Test func connectBacksUpTheOriginalAndKeepsPermissions() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-notch"}]}]}}"#.utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard case .written(let backup?) = try AgentHookFiles.connect(file: file, ai: .claude, command: command, now: now) else {
            Issue.record("應該寫入並備份")
            return
        }
        #expect(backup == AgentHookFiles.backupURL(for: AgentHookFiles.resolved(file), now: now))
        #expect(try Data(contentsOf: backup) == original)
        #expect(try permissions(file) == 0o600)
        #expect(try permissions(backup) == 0o600)
        // 別人的 hook 還在
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("other-notch"))
        // 移除：再備份一次（同一秒加序號，不覆蓋），只剩別人的
        guard case .written(let second?) = try AgentHookFiles.disconnect(file: file, now: now) else {
            Issue.record("應該寫入並備份")
            return
        }
        #expect(second != backup)
        #expect(try backups().count == 2)
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text.contains("other-notch") && !text.contains(AgentHookConfig.marker))
        #expect(try AgentHookFiles.disconnect(file: file, now: now) == .unchanged)
    }

    @Test func invalidJSONIsNeverTouched() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("{\"hooks\": ".utf8)
        try broken.write(to: file)
        #expect(throws: AgentHookConfig.ConfigError.invalidJSON) {
            try AgentHookFiles.connect(file: file, ai: .claude, command: command, now: now)
        }
        #expect(try Data(contentsOf: file) == broken)
        #expect(try backups().isEmpty)
    }

    @Test func movedAppNeedsRepair() throws {
        let old = AgentHookConfig.command(executable: "/Users/me/Downloads/AI Usage.app/Contents/Helpers/aum-hook", ai: .claude)
        _ = try AgentHookFiles.connect(file: file, ai: .claude, command: old, now: now)
        #expect(try AgentHookFiles.status(file: file, ai: .claude, command: command) == .needsRepair(missing: [], wrongPath: true))
        _ = try AgentHookFiles.connect(file: file, ai: .claude, command: command, now: now)
        #expect(try AgentHookFiles.status(file: file, ai: .claude, command: command) == .installed)
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("Downloads"))
    }

    /// dotfiles 管理的設定檔是符號連結：改連結指向的檔案，連結還是連結，權限照目標（Fable F-01）
    @Test func symlinkedSettingsStayLinkedAndPrivate() throws {
        let manager = FileManager.default
        let dotfiles = folder.appendingPathComponent("dotfiles")
        try manager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("claude-settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: target)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try manager.createSymbolicLink(at: file, withDestinationURL: target)

        guard case .written(let backup?) = try AgentHookFiles.connect(file: file, ai: .claude, command: command, now: now) else {
            Issue.record("應該寫入並備份")
            return
        }
        #expect(try manager.destinationOfSymbolicLink(atPath: file.path) == target.path)
        #expect(String(decoding: try Data(contentsOf: target), as: UTF8.self).contains(AgentHookConfig.marker))
        #expect(try permissions(target) == 0o600)
        #expect(try permissions(backup) == 0o600)
        // 比路徑字串：Linux 的 Foundation 會在資料夾 URL 結尾加 /
        #expect(backup.deletingLastPathComponent().resolvingSymlinksInPath().path == dotfiles.resolvingSymlinksInPath().path)
        #expect(try AgentHookFiles.status(file: file, ai: .claude, command: command) == .installed)
    }

    /// 備份只留最新的 3 份，別人的檔案不動（Fable F-11）
    @Test func keepsOnlyTheNewestBackups() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        let other = file.deletingLastPathComponent().appendingPathComponent("settings.json.bak")
        try Data("{}".utf8).write(to: other)
        var backups: [URL] = []
        for i in 0..<5 {
            let at = now.addingTimeInterval(Double(i))
            if case .written(let b?) = try AgentHookFiles.connect(file: file, ai: .claude, command: command, now: at) { backups.append(b) }
            if case .written(let b?) = try AgentHookFiles.disconnect(file: file, now: at) { backups.append(b) }
        }
        #expect(backups.count == 10)
        let left = try self.backups().sorted()
        #expect(left.count == AgentHookFiles.keepBackups)
        // 最後一次（第 5 秒的移除）的備份一定還在；舊的被刪
        #expect(left.contains(backups.last!.lastPathComponent))
        #expect(!left.contains(backups.first!.lastPathComponent))
        #expect(manager.fileExists(atPath: other.path))
    }

    @Test func changeAfterReadingIsMergedNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: file)
        var changed = false
        let result = try AgentHookFiles.connect(file: file, ai: .claude, command: command, now: now) {
            // 讀了之後、替換之前，別的程式改了設定（只改一次）
            guard !changed else { return }
            changed = true
            try? Data(#"{"model":"sonnet","theme":"dark"}"#.utf8).write(to: file)
        }
        guard case .written(let backup?) = result else {
            Issue.record("應該寫入並備份")
            return
        }
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text.contains("sonnet") && text.contains("dark"))
        #expect(try AgentHookFiles.status(file: file, ai: .claude, command: command) == .installed)
        // 備份是實際被替換的版本
        #expect(String(decoding: try Data(contentsOf: backup), as: UTF8.self).contains("sonnet"))
    }

    @Test func keepsChangingGivesUp() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"n":0}"#.utf8).write(to: file)
        var n = 0
        #expect(throws: AgentHookFiles.ChangedDuringWrite()) {
            try AgentHookFiles.connect(file: file, ai: .claude, command: command, now: now) {
                n += 1
                try? Data(#"{"n":\#(n)}"#.utf8).write(to: file)
            }
        }
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == #"{"n":3}"#)
        #expect(try backups().isEmpty)
    }

    @Test func codexHooksDisabledReadsOnlyTheFeatureFlag() {
        func disabled(_ text: String) -> Bool { AgentHookFiles.codexHooksDisabled(configTOML: Data(text.utf8)) }
        #expect(!AgentHookFiles.codexHooksDisabled(configTOML: nil))
        #expect(!disabled("model = \"gpt\"\n"))
        #expect(disabled("[features]\nhooks = false\n"))
        #expect(disabled("[features]\ncodex_hooks = false # 舊名\n"))
        #expect(disabled("features.hooks = false\n"))
        #expect(!disabled("[features]\nhooks = true\n"))
        #expect(!disabled("[other]\nhooks = false\n"))
        #expect(!disabled("# [features]\n# hooks = false\n"))
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.contains(".aum-backup-") }
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
