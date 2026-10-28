import Foundation
import SQLite3
import UsageKit

/// 角色等級（ADR-0020 第 4 節）：瀏海展開時另開短暫的唯讀連線，從 `history.sqlite3` 的 `level_days` 讀出每天的合併主數字
/// （這台＋這台下載到的其他電腦），以 UsageKit 的 `MascotLevel` 計算；一年約 365 列。展開期間不重讀；
/// 讀不到時沿用上次的值，沒有上次的值就不顯示。
/// 等級比上次慶祝過的高時角色慶祝一次（每個等級一次）；第一次看到等級只記下，不慶祝。
@MainActor @Observable
final class MascotLevelStore {
    static let shared = MascotLevelStore()

    private(set) var level: MascotLevel?
    private var loading = false
    private var retry: Task<Void, Never>?

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
        retry?.cancel()
        let settings = PanelSettings.shared
        guard let level else {
            // 成功讀到、但沒有任何活躍日（清除歷史後）：從頭算，之後的第一個等級只記下（Codex C-03）
            settings.celebratedLevel = 0
            return
        }
        if settings.celebratedLevel == 0 || level.level < settings.celebratedLevel {
            // 第一次：只記下（舊使用者不會一裝就連續慶祝）；清除歷史後等級變低：從新的等級重新算
            settings.celebratedLevel = level.level
        } else if level.level > settings.celebratedLevel {
            celebrate(level.level)
        }
    }

    /// 真的播了（或動畫設定讓它不播）才記下。過場或其他動作中每 0.5 秒再試，最多 8 秒；
    /// 收合、靜音時不記，下次展開再播
    private func celebrate(_ target: Int) {
        if MascotController.shared.levelUp() {
            PanelSettings.shared.celebratedLevel = target
            return
        }
        retry = Task { @MainActor in
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, NotchPanelController.shared.isShown,
                      MascotController.shared.director?.machine.isOpen == true else { return }
                if MascotController.shared.levelUp() {
                    PanelSettings.shared.celebratedLevel = target
                    return
                }
            }
        }
    }

    nonisolated static func read(_ url: URL) -> [String: Int64]? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            return nil
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 200)  // 收集器正在寫入時稍等（展開時讀，不能讓瀏海卡住）
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
