import Foundation
import Testing
@testable import UsageKit

/// `level.json` 的讀寫（ADR-0020 第 1 節，2026-10-29 修訂）。合併規則的跨平台一致性在 LevelGoldenTests。
@Suite struct MascotLevelLedgerTests {
    let folder: URL
    let file: URL
    let today = "2026-10-29"
    let days: [String: Int64] = ["2026-10-27": 50_000, "2026-10-28": 80_000, "2026-10-29": 20_000]

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aum-level-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent(MascotLevelLedger.fileName)
    }

    @Test func createsPrivateFile() throws {
        #expect(MascotLevelLedger.update(file: file, adding: days, today: today) == days)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(MascotLevelLedger.decode(try Data(contentsOf: file)) == days)
    }

    /// 清除歷史後 `level_days` 是空的：等級不變
    @Test func clearedHistoryKeepsDays() throws {
        _ = MascotLevelLedger.update(file: file, adding: days, today: today)
        let after = MascotLevelLedger.update(file: file, adding: [:], today: today)
        #expect(after == days)
        #expect(MascotLevel(days: after, today: today) == MascotLevel(days: days, today: today))
        // 之後的新日子照常累加
        let more = MascotLevelLedger.update(file: file, adding: ["2026-10-30": 1], today: "2026-10-30")
        #expect(more.count == 4)
    }

    @Test func corruptFileIsKeptAndRebuiltFromHistory() throws {
        try Data("{\"days\": {".utf8).write(to: file)
        #expect(MascotLevelLedger.update(file: file, adding: days, today: today) == days)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MascotLevelLedger.corruptName).path))
        #expect(MascotLevelLedger.decode(try Data(contentsOf: file)) == days)
    }

    @Test func smallerHistoryDoesNotRewrite() throws {
        _ = MascotLevelLedger.update(file: file, adding: days, today: today)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        #expect(MascotLevelLedger.update(file: file, adding: ["2026-10-28": 1], today: today) == days)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        #expect(before == after)  // 沒有用暫存檔取代
    }
}
