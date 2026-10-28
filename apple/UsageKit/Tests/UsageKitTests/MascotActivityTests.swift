import Foundation
import Testing
@testable import UsageKit

/// 「工作中」偵測（ADR-0016 第 7 節）：只看修改時間，絕不開啟或讀取紀錄檔
@Suite struct MascotActivityTests {
    /// 假的檔案系統：記下列過哪些資料夾
    final class FakeLister: MascotDirectoryLister, @unchecked Sendable {
        var tree: [String: [MascotDirectoryEntry]] = [:]
        var listed: [String] = []

        func add(_ path: String, directory: Bool = false, modified: Date) {
            let url = URL(fileURLWithPath: path)
            tree[url.deletingLastPathComponent().path, default: []]
                .append(MascotDirectoryEntry(url: url, isDirectory: directory, modified: modified))
        }

        func entries(in directory: URL) -> [MascotDirectoryEntry] {
            listed.append(directory.path)
            return tree[directory.path] ?? []
        }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let roots = MascotActivityProbe.defaultRoots(environment: [:], home: URL(fileURLWithPath: "/home/u"))

    @Test func recentClaudeSessionCountsAsWorking() {
        let fs = FakeLister()
        fs.add("/home/u/.claude/projects/app", directory: true, modified: Self.now.addingTimeInterval(-3600))
        fs.add("/home/u/.claude/projects/app/s1.jsonl", modified: Self.now.addingTimeInterval(-10))
        #expect(MascotActivityProbe(roots: Self.roots, lister: fs).isWorking(now: Self.now))
    }

    @Test func oldFilesAndOtherExtensionsDoNot() {
        let fs = FakeLister()
        fs.add("/home/u/.claude/projects/app", directory: true, modified: Self.now)
        fs.add("/home/u/.claude/projects/app/s1.jsonl", modified: Self.now.addingTimeInterval(-46))
        fs.add("/home/u/.claude/projects/app/notes.txt", modified: Self.now)
        #expect(!MascotActivityProbe(roots: Self.roots, lister: fs).isWorking(now: Self.now))
    }

    @Test func codexLooksOnlyAtTheNewestDays() {
        let fs = FakeLister()
        let s = "/home/u/.codex/sessions"
        fs.add("\(s)/2026", directory: true, modified: Self.now)
        fs.add("\(s)/2026/10", directory: true, modified: Self.now)
        for day in ["25", "26", "27", "28"] { fs.add("\(s)/2026/10/\(day)", directory: true, modified: Self.now) }
        fs.add("\(s)/2026/10/28/rollout.jsonl", modified: Self.now.addingTimeInterval(-5))
        #expect(MascotActivityProbe(roots: Self.roots, lister: fs).isWorking(now: Self.now))
        // 舊的日子不列
        #expect(!fs.listed.contains("\(s)/2026/10/25"))
        // 太舊的日子即使有新檔也不看（只看名稱最後的兩天）
        let old = FakeLister()
        old.add("\(s)/2026", directory: true, modified: Self.now)
        old.add("\(s)/2026/10", directory: true, modified: Self.now)
        for day in ["25", "27", "28"] { old.add("\(s)/2026/10/\(day)", directory: true, modified: Self.now) }
        old.add("\(s)/2026/10/25/rollout.jsonl", modified: Self.now)
        #expect(!MascotActivityProbe(roots: Self.roots, lister: old).isWorking(now: Self.now))
    }

    @Test func listingsAreCapped() {
        let fs = FakeLister()
        for i in 0..<(MascotActivityProbe.maxListings + 100) {
            fs.add("/home/u/.claude/projects/p\(i)", directory: true, modified: Self.now)
        }
        _ = MascotActivityProbe(roots: Self.roots, lister: fs).isWorking(now: Self.now)
        #expect(fs.listed.count <= MascotActivityProbe.maxListings)
    }

    @Test func collectorConfigComesFirst() {
        // config.json 的位置優先（Finder 打開的 App 沒有 shell 的環境變數；Codex C-06）
        let config = MascotActivityProbe.logDirectories(fromConfig: Data("""
            {"claude_config_dir": "~/work/claude", "codex_home": "/opt/codex", "relay_url": "https://x", "n": 1}
            """.utf8))
        #expect(config == ["claude_config_dir": "~/work/claude", "codex_home": "/opt/codex"])
        let roots = MascotActivityProbe.defaultRoots(config: config, environment: ["CLAUDE_CONFIG_DIR": "/c", "CODEX_HOME": "/x"],
                                                     home: URL(fileURLWithPath: "/home/u"))
        #expect(roots.map(\.url.path) == ["/home/u/work/claude/projects", "/opt/codex/sessions"])
        // 假的列舉器確認走訪的是設定的位置
        let fs = FakeLister()
        fs.add("/opt/codex/sessions/2026", directory: true, modified: Self.now)
        _ = MascotActivityProbe(roots: roots, lister: fs).isWorking(now: Self.now)
        #expect(fs.listed.contains("/home/u/work/claude/projects") && fs.listed.contains("/opt/codex/sessions/2026"))
        #expect(!fs.listed.contains { $0.hasPrefix("/c") || $0.hasPrefix("/x") })
        // 壞掉的設定：當成沒有
        #expect(MascotActivityProbe.logDirectories(fromConfig: Data("[1]".utf8)).isEmpty)
        #expect(MascotActivityProbe.logDirectories(fromConfig: nil).isEmpty)
    }

    @Test func environmentOverridesHome() {
        let roots = MascotActivityProbe.defaultRoots(environment: ["CLAUDE_CONFIG_DIR": "/c", "CODEX_HOME": "/x"],
                                                     home: URL(fileURLWithPath: "/home/u"))
        #expect(roots.map(\.url.path) == ["/c/projects", "/x/sessions"])
    }

    /// 真的檔案系統：紀錄檔設成誰都不能讀（chmod 000），仍然靠修改時間判斷得出來 → 偵測沒有開檔
    @Test func realFileSystemNeedsNoReadPermission() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mascot-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = tmp.appendingPathComponent("projects/app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let log = project.appendingPathComponent("s1.jsonl")
        try Data("secret\n".utf8).write(to: log)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path) }
        #expect((try? Data(contentsOf: log)) == nil)   // 確實讀不到
        let probe = MascotActivityProbe(roots: [.init(url: tmp.appendingPathComponent("projects"), depth: 2)])
        #expect(probe.isWorking(now: Date()))
        #expect(!probe.isWorking(now: Date().addingTimeInterval(120)))
    }

    /// 原始碼裡沒有讀檔的 API（列資料夾以外的檔案系統呼叫）
    @Test func sourceUsesNoReadAPIs() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UsageKit/MascotActivity.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for api in ["Data(contentsOf", "String(contentsOf", "FileHandle", "InputStream", "fopen", "open(", "read(",
                    "contents(atPath", "mmap"] {
            #expect(!text.contains(api), "MascotActivity.swift 用了 \(api)")
        }
    }
}
