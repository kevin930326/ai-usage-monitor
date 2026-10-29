import Foundation
import SQLite3
import UsageKit

/// 角色等級（ADR-0020 第 4 節）：瀏海展開時另開短暫的唯讀連線，從 `history.sqlite3` 的 `level_days` 讀出每天的合併主數字
/// （這台＋這台下載到的其他電腦），併進獨立的 `level.json`（`MascotLevelLedger`，只增不減：清除歷史、資料庫重建後等級不變低），
/// 以 UsageKit 的 `MascotLevel` 計算；一年約 365 列。展開期間不重讀；兩邊都讀不到時沿用上次的值，沒有上次的值就不顯示。
/// 等級比上次慶祝過的高時角色慶祝一次（每個等級一次）；第一次看到等級只記下，不慶祝。
@MainActor @Observable
final class MascotLevelStore {
    static let shared = MascotLevelStore()

    private(set) var level: MascotLevel?
    /// 這次執行看過的每一天：`level.json` 讀不到（權限之類）時也不倒退
    private var knownDays: [String: Int64] = [:]
    private var loading = false
    private var retry: Task<Void, Never>?

    /// 瀏海展開時呼叫
    func refresh(now: Date = Date()) {
        guard !loading else { return }
        loading = true
        let url = UsageStore.shared.locator.historyFile
        let today = TokenCalendar.key(now, calendar: TokenCalendar.make())
        let known = knownDays
        Task.detached(priority: .utility) {
            let history = Self.read(url)
            let days = MascotLevelLedger.update(file: Self.ledger(for: url), adding: MascotLevelLedger.merge(known, history ?? [:]),
                                                today: today)
            await MainActor.run {
                let store = MascotLevelStore.shared
                store.loading = false
                // 歷史讀不到（還沒有表、被鎖住）而且 level.json 也沒有東西：保留上一次的
                guard history != nil || !days.isEmpty else { return }
                store.knownDays = days
                store.apply(MascotLevel(days: days, today: today))
            }
        }
    }

    func apply(_ level: MascotLevel?) {
        self.level = level
        retry?.cancel()
        let settings = PanelSettings.shared
        guard let level else {
            // 成功讀到、但沒有任何活躍日（新安裝，或 level.json 也被刪掉）：從頭算，之後的第一個等級只記下（Codex C-03）
            settings.celebratedLevel = 0
            return
        }
        if settings.celebratedLevel == 0 || level.level < settings.celebratedLevel {
            // 第一次：只記下（舊使用者不會一裝就連續慶祝）；等級變低（使用者刪了 level.json）：從新的等級重新算
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

    /// `level.json` 和 `history.sqlite3` 在同一個資料夾
    nonisolated static func ledger(for history: URL) -> URL {
        history.deletingLastPathComponent().appendingPathComponent(MascotLevelLedger.fileName)
    }

    /// 清除歷史之前呼叫：把 `level_days` 先併進 `level.json`，清除後等級不變低（ADR-0020 第 1 節）
    nonisolated static func preserve(history url: URL, now: Date) {
        guard let days = read(url) else { return }
        _ = MascotLevelLedger.update(file: ledger(for: url), adding: days, today: TokenCalendar.key(now, calendar: TokenCalendar.make()))
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
