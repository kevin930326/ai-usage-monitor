import Foundation
import SQLite3
import UsageKit

/// 角色等級（ADR-0020）：瀏海展開時從 `history.sqlite3` 的 `level_days` 讀出每天所有電腦合併的主數字，
/// 以 UsageKit 的 `MascotLevel` 計算。只讀（唯讀開檔、不等鎖），一年約 365 列。
/// 等級比上次慶祝過的高時角色歡呼一次（每個等級一次）；第一次看到等級只記下，不慶祝。
@MainActor @Observable
final class MascotLevelStore {
    static let shared = MascotLevelStore()

    private(set) var level: MascotLevel?
    private var loading = false

    /// 瀏海展開時呼叫
    func refresh(now: Date = Date()) {
        guard !loading else { return }
        loading = true
        let url = UsageStore.shared.locator.historyFile
        let today = TokenCalendar.key(now, calendar: TokenCalendar.make())
        Task.detached(priority: .utility) {
            let days = Self.read(url)
            await MainActor.run {
                let store = MascotLevelStore.shared
                store.loading = false
                guard let days else { return }  // 讀不到（還沒有表、被鎖住）：保留上一次的
                store.apply(MascotLevel(days: days, today: today))
            }
        }
    }

    func apply(_ level: MascotLevel?) {
        self.level = level
        guard let level else { return }
        let settings = PanelSettings.shared
        if settings.celebratedLevel == 0 || level.level < settings.celebratedLevel {
            // 第一次：只記下（舊使用者不會一裝就連續慶祝）；清除歷史後等級變低：從新的等級重新算
            settings.celebratedLevel = level.level
        } else if level.level > settings.celebratedLevel {
            settings.celebratedLevel = level.level
            MascotController.shared.levelUp()
        }
    }

    nonisolated static func read(_ url: URL) -> [String: Int64]? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            return nil
        }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT day, tokens FROM level_days", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var days: [String: Int64] = [:]
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let text = sqlite3_column_text(stmt, 0) else { continue }
            days[String(cString: text)] = sqlite3_column_int64(stmt, 1)
        }
        return days
    }
}
