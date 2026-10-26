import Foundation
import Observation
import SQLite3
import UsageKit

/// 讀取收集器寫的 `history.sqlite3`（FR-37、ADR-0009）。
///
/// - App 只讀：只有收集器建表與執行 migration。例外是設定中的「清除歷史」與「縮短保留期間」，由 App 立即刪除。
/// - 只在面板看得見時開啟連線並查詢；面板開著時監看 `-wal`，收集器提交新資料（`PRAGMA data_version` 改變）才重新查詢；
///   面板關閉時關閉連線（ADR-0009 第 7 節、NFR-8）。
/// - 不建立檔案：檔案不存在（收集器還沒更新或還沒執行）時狀態為 `.missing`，面板顯示「正在收集」。
@Observable
@MainActor
final class HistoryStore {
    static let shared = HistoryStore(url: UsageStore.shared.locator.historyFile)

    /// App 支援的資料庫版本（`meta.schema_version`）；收集器的 `history.SCHEMA_VERSION` 改了這裡要一起改
    nonisolated static let supportedSchema = 3
    /// 面板需要的範圍：本週走勢最長 7 天、額度消耗 7 天、近期速度 24 小時，多留一天給跨日的差值
    nonisolated static let lookback: TimeInterval = 8 * 86400
    /// 讀取時最多等收集器多久（WAL 模式下讀取通常不會被寫入擋住）
    nonisolated static let readBusyTimeoutMs: Int32 = 1000
    nonisolated static let writeBusyTimeoutMs: Int32 = 5000
    nonisolated static let retentionChoices: [(days: Int, title: String)] = [
        (7, "7 天"), (30, "30 天"), (90, "90 天"), (365, "1 年"), (0, "永久"),
    ]
    nonisolated static let defaultRetentionDays = 365

    enum Status: Equatable {
        /// 面板關閉，沒有連線
        case closed
        /// 檔案不存在：收集器還沒寫入（剛安裝或收集器尚未更新）
        case missing
        case ready
        /// 檔案版本比 App 支援的舊（收集器尚未更新）：請重新執行安裝腳本
        case olderSchema(Int)
        /// 檔案版本較新：照樣讀取，但不寫入（清除、改保留期間），請更新 App
        case newerSchema(Int)
        /// 讀不了（損毀、權限）；只記錄類別，不顯示 SQLite 的訊息（可能含路徑）
        case failed

        var canRead: Bool {
            switch self {
            case .ready, .newerSchema: true
            default: false
            }
        }
    }

    let url: URL
    private(set) var status: Status = .closed
    private(set) var history: QuotaHistory = .empty
    /// Token 統計（面板的統計卡片；不含每小時資料）。有第二層時含其他電腦的每日資料，畫面依裝置範圍 `scoped` 後使用
    private(set) var tokens: TokenStatsData = .empty
    /// 最後一次查詢的時間（Debug 量測與測試用）
    private(set) var loadedAt: Date?

    @ObservationIgnored private var db: OpaquePointer?
    /// 面板看得見（open 到 close 之間）
    @ObservationIgnored private var active = false
    /// 上次查詢時的 `PRAGMA data_version`；收集器提交新資料後會變
    @ObservationIgnored private var dataVersion: Int64?
    /// 面板開著時監看 `-wal`：App 開著連線時收集器只改寫既有的 -wal，資料夾監看收不到
    @ObservationIgnored private var walSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pendingCheck: DispatchWorkItem?

    init(url: URL) {
        self.url = url
    }

    // MARK: - 面板用的唯讀連線

    /// 面板變成看得見時呼叫：開啟連線並查詢。
    func open(now: Date = RenderClock.now) {
        active = true
        if db == nil {
            guard FileManager.default.fileExists(atPath: url.path) else {
                status = .missing
                history = .empty
                return
            }
            // 不用 SQLITE_OPEN_READONLY：WAL 模式的唯讀連線在 -shm 不存在時開不了。
            // 改以讀寫模式開啟（不建立檔案）並設 query_only，不會寫入任何資料。
            var handle: OpaquePointer?
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(handle)
                fail("open")
                return
            }
            sqlite3_busy_timeout(handle, Self.readBusyTimeoutMs)
            sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil)
            db = handle
            Self.tightenPermissions(url)
        }
        reload(now: now)
        if walSource == nil { watchWAL() }
    }

    /// 收集器寫入後呼叫（資料夾或 -wal 有變動）：面板開著且資料庫有新的提交時才重新查詢。
    /// 收集器先寫 usage.json、上傳後才寫歷史，只在 usage.json 更新時查詢會落後一輪（C-01）。
    func collectorWrote() {
        guard active else { return }
        guard let db else {
            // 之前檔案不存在或開不了：收集器可能剛建立
            open()
            return
        }
        guard Self.dataVersion(db) != dataVersion else { return }
        reload()
    }

    /// 一次寫入會觸發好幾個事件：0.5 秒內合併成一次檢查
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.collectorWrote() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func watchWAL() {
        let fd = Darwin.open(url.path + "-wal", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.walSource else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    // -wal 被換掉：改監看新的檔案
                    self.stopWatchingWAL()
                    if self.active { self.watchWAL() }
                }
                self.scheduleCheck()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        walSource = source
    }

    private func stopWatchingWAL() {
        walSource?.cancel()
        walSource = nil
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    /// `usage.json` 有新內容時重新查詢（只在連線開著時）。
    func reload(now: Date = RenderClock.now) {
        guard let db else { return }
        let version = Self.schemaVersion(db)
        switch version {
        case nil:
            fail("schema")
            return
        case let v? where v < Self.supportedSchema:
            status = .olderSchema(v)
            history = .empty
            tokens = .empty
            return
        case let v? where v > Self.supportedSchema:
            status = .newerSchema(v)
        default:
            status = .ready
        }
        let since = Int64(now.addingTimeInterval(-Self.lookback).timeIntervalSince1970)
        guard let samples = Self.samples(db, since: since), let runs = Self.runs(db, since: since) else {
            fail("query")
            return
        }
        history = QuotaHistory(samples: samples, runs: runs)
        // Token 統計讀不了（例如收集器還在建立表）時不影響額度歷史
        tokens = Self.tokenStats(db, now: now, hourly: false) ?? .empty
        dataVersion = Self.dataVersion(db)
        loadedAt = now
    }

    /// 面板關閉時呼叫：關閉連線，查詢結果保留到下次開啟（不再重新查詢）。
    func close() {
        active = false
        stopWatchingWAL()
        guard let db else { return }
        sqlite3_close_v2(db)
        self.db = nil
        dataVersion = nil
        status = .closed
    }

    private func fail(_ stage: String) {
        UsageStore.log("history: \(stage) failed")
        let wasActive = active
        close()
        active = wasActive
        status = .failed
        history = .empty
        tokens = .empty
    }

    // MARK: - 設定視窗（保留期間、匯出、清除）

    struct Info: Equatable {
        var status: Status
        var retentionDays: Int
        var sampleCount: Int
        var oldest: Date?
        /// 資料庫大小與各表佔用；讀不到檔案大小時為 nil
        var size: HistorySize? = nil
    }

    /// 設定視窗顯示的資訊：每次另開一個短暫的連線，用完就關。
    nonisolated func info(now: Date = RenderClock.now) -> Info {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Info(status: .missing, retentionDays: Self.defaultRetentionDays, sampleCount: 0, oldest: nil)
        }
        return withConnection(write: false) { db -> Info in
            guard let version = Self.schemaVersion(db) else {
                return Info(status: .failed, retentionDays: Self.defaultRetentionDays, sampleCount: 0, oldest: nil)
            }
            let status: Status = version < Self.supportedSchema ? .olderSchema(version)
                : version > Self.supportedSchema ? .newerSchema(version) : .ready
            let retention = Self.meta(db, "retention_days").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } ?? Self.defaultRetentionDays
            let count = Self.scalar(db, "SELECT COUNT(*) FROM quota_samples") ?? 0
            let oldest = Self.scalar(db, "SELECT MIN(ts) FROM quota_samples").map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return Info(status: status, retentionDays: retention, sampleCount: Int(count), oldest: count > 0 ? oldest : nil,
                        size: size(db, now: now))
        } ?? Info(status: .failed, retentionDays: Self.defaultRetentionDays, sampleCount: 0, oldest: nil)
    }

    /// 各表在設定「歷史資料」預估裡的分類（`HistorySize`）；沒列出的（meta、掃描進度等）算「其他」
    private nonisolated static func sizeGroup(_ table: String) -> WritableKeyPath<HistorySize, Int64> {
        switch table {
        case "quota_samples", "collector_runs": \.quotaBytes
        case "daily_tokens", "upload_state": \.dailyBytes
        case "hourly_tokens": \.hourlyBytes
        case "record_days", "record_days_cached": \.recordBytes
        case "seen_ids", "seen_tasks", "file_tokens": \.seenBytes
        default: \.otherBytes
        }
    }

    /// 檔案大小（主檔＋WAL）與各表佔用（`dbstat`，含索引）；`dbstat` 不能用時只有檔案大小，不估算
    private nonisolated func size(_ db: OpaquePointer, now: Date) -> HistorySize? {
        func bytes(_ url: URL) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let fileBytes = bytes(url) + bytes(URL(fileURLWithPath: url.path + "-wal"))
        guard fileBytes > 0 else { return nil }
        var size = HistorySize(fileBytes: fileBytes)
        let tables = Self.rows(db, """
            SELECT m.tbl_name, SUM(d.pgsize) FROM dbstat d JOIN sqlite_master m ON m.name = d.name
            WHERE d.aggregate = 1 GROUP BY m.tbl_name
            """, []) { stmt -> (String, Int64)? in
            Self.text(stmt, 0).map { ($0, sqlite3_column_int64(stmt, 1)) }
        }
        guard let tables else { return size }
        for (name, pages) in tables {
            size[keyPath: Self.sizeGroup(name)] += pages
        }
        let nowTS = Int64(now.timeIntervalSince1970)
        let present = Set(Self.existingTables(db, ["quota_samples", "collector_runs", "daily_tokens", "hourly_tokens",
                                                   "record_days", "seen_ids"]))
        for table in ["quota_samples", "collector_runs"] where present.contains(table) {
            size.quotaRows += Self.scalar(db, "SELECT COUNT(*) FROM \(table)") ?? 0
            let recent = Self.rows(db, "SELECT COUNT(*) FROM \(table) WHERE ts >= ?", [.int(nowTS - 7 * 86400)]) { sqlite3_column_int64($0, 0) }
            size.quotaRowsPerDay += Double(recent?.first ?? 0) / 7
        }
        if let oldest = Self.scalar(db, "SELECT MIN(ts) FROM quota_samples") {
            size.dataDays = Int(max(0, nowTS - oldest) / 86400)
        }
        func days(_ sql: String, _ values: [Value] = []) -> Int {
            Int(max(0, Self.rows(db, sql, values) { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 0) }?.first ?? 0))
        }
        if present.contains("daily_tokens") { size.dailyDays = days("SELECT COUNT(DISTINCT day) FROM daily_tokens") }
        if present.contains("hourly_tokens") { size.hourlyDays = days("SELECT COUNT(DISTINCT day) FROM hourly_tokens") }
        if present.contains("record_days") { size.recordDays = days("SELECT COUNT(DISTINCT day) FROM record_days") }
        if present.contains("seen_ids") {
            // 最早一筆到今天（含）；沒有去重紀錄時是 0，不放大
            size.seenSpanDays = days("SELECT CAST(julianday(?) - julianday(MIN(day)) AS INTEGER) + 1 FROM seen_ids", [.text(Self.tokenDay(now))])
        }
        size.seenBounded = Self.meta(db, "seen_cutoff_day") != nil
        return size
    }

    enum WriteError: Error, Equatable {
        case missing
        case unsupportedSchema
        case failed
    }

    /// 改保留期間：寫入 `meta.retention_days`；縮短時立即刪除超出的資料（收集器每天也會依 meta 再刪一次）。
    /// 延長時舊期間以前的每日 Token 已刪除，把邊界記在 `meta.token_days_from`，統計才不會把它們畫成 0。
    /// 收集器停過時實際刪到的地方比「現在 − 舊期間」早，所以取它與資料庫裡最早一天較早的一個：
    /// 還在的資料一定不會被藏起來；最早一天之前若剛好沒有使用，會顯示成「沒有資料」而不是 0（保守）。
    nonisolated func setRetention(days: Int, now: Date = RenderClock.now) throws {
        try write { db in
            let old = Self.meta(db, "retention_days").flatMap(Int.init) ?? Self.defaultRetentionDays
            guard Self.exec(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('retention_days', ?)", [.text(String(days))]) else { return false }
            let shorter = days > 0 && (old == 0 || days < old)
            guard shorter else {
                guard old > 0, days != old else { return true }
                var boundary = Self.tokenDay(now.addingTimeInterval(-TimeInterval(old) * 86400))
                if Self.existingTables(db, ["daily_tokens"]).count == 1,
                   let earliest = Self.firstTokenDay(db), earliest < boundary {
                    boundary = earliest
                }
                return Self.raiseTokenDaysFrom(db, boundary)
            }
            let cutoff = Int64(now.timeIntervalSince1970) - Int64(days) * 86400
            return Self.existingTables(db, ["quota_samples", "collector_runs", "daily_tokens", "hourly_tokens"]).allSatisfy { table in
                let column = table.hasSuffix("_tokens") ? "day" : "ts"
                if column == "day" {
                    let day = Self.dayString(Date(timeIntervalSince1970: TimeInterval(cutoff)))
                    return Self.exec(db, "DELETE FROM \(table) WHERE day < ?", [.text(day)])
                }
                return Self.exec(db, "DELETE FROM \(table) WHERE ts < ?", [.int(cutoff)])
            }
        }
    }

    /// 清除歷史（ADR-0009 第 5 節）。`rescan` 為真時連同掃描進度與去重表一起清除（Token 統計會從對話紀錄重建；
    /// 額度歷史沒有來源可以重建）。保留 `meta`（裝置 ID、保留期間）。
    /// 不重新掃描時 `file_tokens` 歸零而不刪除：對應的加總已清除，之後收集器重算該檔時只清空、不會扣到新的資料。
    nonisolated func clear(rescan: Bool, now: Date = RenderClock.now) throws {
        var tables = ["quota_samples", "collector_runs", "daily_tokens", "hourly_tokens", "records", "record_days", "record_days_cached"]
        if rescan { tables += ["scan_state", "seen_ids", "seen_tasks", "file_tokens"] }
        try write(vacuum: true) { db in
            Self.existingTables(db, tables).allSatisfy { Self.exec(db, "DELETE FROM \($0)", []) }
                && (rescan || Self.existingTables(db, ["file_tokens"]).allSatisfy {
                    Self.exec(db, "UPDATE \($0) SET input_tokens = 0, cache_write_tokens = 0, cache_read_tokens = 0,"
                        + " output_tokens = 0, reasoning_tokens = 0", [])
                })
                && (!rescan || Self.exec(db, "DELETE FROM meta WHERE key IN ('first_scan_progress', 'first_scan_done',"
                    + " 'token_bad_lines', 'token_long_lines', 'token_days_from', 'seen_cutoff_day')", []))
                // 不重新掃描時，今天以前的每日 Token 不會再算回來
                && (rescan || Self.raiseTokenDaysFrom(db, Self.tokenDay(now)))
                // 第二層：其他電腦的每日資料也一起刪了，收集器下一輪就重新下載（不用等一小時，也不等失敗後的退避）
                && Self.exec(db, "DELETE FROM meta WHERE key IN ('sync_last_success', 'sync_next_at', 'sync_failures')", [])
        }
        removeCopies()
    }

    /// 清除歷史時一併刪掉收集器的每週備份、損毀時保留的舊檔與提示（ADR-0014 D-1），「無法復原」才成立
    nonisolated func removeCopies() {
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        try? fm.removeItem(at: folder.appendingPathComponent("backups"))
        try? fm.removeItem(at: folder.appendingPathComponent("history-recovered.json"))
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("history.corrupt-") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// `daily_tokens` 最早的一天；沒有資料時為 nil
    private nonisolated static func firstTokenDay(_ db: OpaquePointer) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT MIN(day) FROM daily_tokens", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    /// `meta.token_days_from` 只往後移（YYYY-MM-DD 可以直接比較字串）
    private nonisolated static func raiseTokenDaysFrom(_ db: OpaquePointer, _ day: String) -> Bool {
        if let current = meta(db, "token_days_from"), current >= day { return true }
        return exec(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('token_days_from', ?)", [.text(day)])
    }

    /// 匯出額度 CSV 的內容：每小時的額度歷史（`QuotaHistoryCSV`）。
    nonisolated func exportCSV() throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw WriteError.missing }
        guard let csv = withConnection(write: false, { db in Self.samples(db, since: 0).map(QuotaHistoryCSV.make) }) ?? nil else {
            throw WriteError.failed
        }
        return csv
    }

    /// 匯出 Token CSV 的內容：這台電腦的每日 Token（`TokenCSV`，不設日期下界）。沒有 Token 統計的資料表時丟出 `missing`。
    nonisolated func exportTokenCSV() throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw WriteError.missing }
        let result: String?? = withConnection(write: false) { db -> String? in
            guard Self.existingTables(db, ["daily_tokens"]).count == 1 else { return nil }
            return Self.tokenDays(db, local: Self.meta(db, "device_id") ?? "", onlyLocal: true, since: "").map { TokenCSV.make(rows: $0) }
        }
        guard let opened = result else { throw WriteError.failed }
        guard let csv = opened else { throw WriteError.missing }
        return csv
    }

    // MARK: - SQLite

    private nonisolated func write(vacuum: Bool = false, _ body: (OpaquePointer) -> Bool) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw WriteError.missing }
        let result: Result<Void, WriteError>? = withConnection(write: true) { db in
            guard Self.schemaVersion(db) == Self.supportedSchema else { return .failure(.unsupportedSchema) }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return .failure(.failed) }
            guard body(db), sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return .failure(.failed)
            }
            if vacuum { sqlite3_exec(db, "VACUUM", nil, nil, nil) }
            return .success(())
        }
        Self.tightenPermissions(url)
        switch result {
        case .success: return
        case let .failure(error): throw error
        case nil: throw WriteError.failed
        }
    }

    private nonisolated func withConnection<T>(write: Bool, _ body: (OpaquePointer) -> T) -> T? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, write ? Self.writeBusyTimeoutMs : Self.readBusyTimeoutMs)
        if !write { sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil) }
        return body(handle)
    }

    enum Value {
        case int(Int64)
        case text(String)
    }

    private nonisolated static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private nonisolated static func exec(_ db: OpaquePointer, _ sql: String, _ values: [Value]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in values.enumerated() {
            switch value {
            case let .int(v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case let .text(v): sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
            }
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private nonisolated static func scalar(_ db: OpaquePointer, _ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private nonisolated static func meta(_ db: OpaquePointer, _ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    /// `meta.schema_version`；沒有 meta 表或沒有這個鍵時為 0（舊版或空檔案），讀不了時為 nil。
    /// 其他連線（收集器）每提交一次就會變；同一個連線自己的寫入不會改變它
    nonisolated static func dataVersion(_ db: OpaquePointer) -> Int64? {
        scalar(db, "PRAGMA data_version")
    }

    nonisolated static func schemaVersion(_ db: OpaquePointer) -> Int? {
        guard scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'") != nil else { return nil }
        guard scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'") == 1 else { return 0 }
        return meta(db, "schema_version").flatMap(Int.init) ?? 0
    }

    private nonisolated static func existingTables(_ db: OpaquePointer, _ names: [String]) -> [String] {
        names.filter { scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\($0)'") == 1 }
    }

    private nonisolated static func samples(_ db: OpaquePointer, since: Int64) -> [QuotaSample]? {
        var stmt: OpaquePointer?
        let sql = "SELECT ts, provider, window_id, used_pct, resets_at FROM quota_samples WHERE ts >= ? ORDER BY ts"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)
        var result: [QuotaSample] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW, let provider = sqlite3_column_text(stmt, 1), let window = sqlite3_column_text(stmt, 2) else { return nil }
            let resets = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
            result.append(QuotaSample(
                ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                provider: String(cString: provider), windowID: String(cString: window),
                usedPct: sqlite3_column_double(stmt, 3), resetsAt: resets))
        }
        return result
    }

    private nonisolated static func runs(_ db: OpaquePointer, since: Int64) -> [CollectorRun]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ts, ok, runs FROM collector_runs WHERE ts >= ? ORDER BY ts", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)
        var result: [CollectorRun] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { return nil }
            result.append(CollectorRun(ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                                       ok: Int(sqlite3_column_int64(stmt, 1)), runs: Int(sqlite3_column_int64(stmt, 2))))
        }
        return result
    }

    private nonisolated static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// App 開啟時 SQLite 可能建立 -shm／-wal（App 的 umask 是 022），改回 0600（ADR-0009 第 1 節）。
    private nonisolated static func tightenPermissions(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mode = attrs[.posixPermissions] as? Int, mode & 0o777 != 0o600 else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}

// Token 統計的讀取（FR-43、ADR-0009 第 4、7 節）。查詢結果交給 UsageKit 的 TokenStats 計算。
// 面板只讀最近一年的每日資料（熱力圖 22 週、活動 30 天／12 週、四個數字）；每小時資料只在完整統計視窗讀。
// 第二層（FR-49、ADR-0011）：收集器下載的其他電腦的每日資料也在 daily_tokens（其他 device_id）與 devices 表；
// 每日資料全部讀出、以 `TokenDayRow.device` 標示（這台 Mac 是 `TokenDevices.local`），每小時資料與個人紀錄只有這台 Mac 的。

extension HistoryStore {
    /// 面板讀的每日資料範圍：完整統計視窗的一年熱力圖也用這個範圍
    nonisolated static let tokenLookbackDays = 371

    /// 面板開著時一起讀取（與額度歷史同一個連線）
    nonisolated static func tokenStats(_ db: OpaquePointer, now: Date, hourly: Bool) -> TokenStatsData? {
        guard existingTables(db, ["daily_tokens", "records", "record_days"]).count == 3 else { return nil }
        let device = meta(db, "device_id") ?? ""
        let since = tokenDay(now.addingTimeInterval(-TimeInterval(tokenLookbackDays) * 86400))
        guard let days = tokenDays(db, local: device, onlyLocal: false, since: since),
              let records = tokenRecords(db),
              let recordDays = tokenRecordDays(db) else { return nil }
        let hours = hourly ? tokenHours(db, device: device) : []
        guard let hours else { return nil }
        let skipped = ["token_bad_lines", "token_long_lines"].compactMap { meta(db, $0).flatMap(Int.init) }.reduce(0, +)
        let retention = meta(db, "retention_days").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } ?? defaultRetentionDays
        return TokenStatsData(
            days: days, hours: hours, records: records, recordDays: recordDays,
            firstScanDone: meta(db, "first_scan_done") == "1",
            firstScanProgress: meta(db, "first_scan_progress").flatMap(Int.init).map { min(max($0, 0), 100) },
            skippedLines: skipped, retentionDays: retention, dataFrom: meta(db, "token_days_from"),
            formatSuspect: meta(db, "token_format_suspect") == "1",
            devices: tokenDevices(db))
    }

    /// 中繼的裝置清單（收集器下載時整批取代）與這台 Mac 的上傳狀態；沒有第二層時是空的
    private nonisolated static func tokenDevices(_ db: OpaquePointer) -> TokenDevices {
        let revoked = meta(db, "upload_status") == "revoked"
        guard existingTables(db, ["devices"]).count == 1 else { return TokenDevices(uploadRevoked: revoked) }
        let list = rows(db, "SELECT device_id, name, last_upload_at, revoked, is_self FROM devices ORDER BY rowid", []) { stmt -> TokenDevice? in
            guard let id = text(stmt, 0), let name = text(stmt, 1) else { return nil }
            let last = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))
            return TokenDevice(id: id, name: name, lastUpload: last, revoked: sqlite3_column_int64(stmt, 3) != 0,
                               isSelf: sqlite3_column_int64(stmt, 4) != 0)
        }
        return TokenDevices(devices: list ?? [], uploadRevoked: revoked)
    }

    /// 完整統計視窗：另開一個短暫的連線讀完就關，結果由視窗保存，關閉視窗時釋放（ADR-0009 第 7 節）。
    nonisolated func loadFullTokenStats(now: Date = RenderClock.now) -> TokenStatsData? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return withConnection(write: false) { db -> TokenStatsData? in
            guard let version = Self.schemaVersion(db), version >= Self.supportedSchema else { return nil }
            return Self.tokenStats(db, now: now, hourly: true)
        } ?? nil
    }

    private nonisolated static let tokenColumns = "input_tokens, cache_write_tokens, cache_read_tokens, output_tokens, reasoning_tokens"

    private nonisolated static func counts(_ stmt: OpaquePointer?, from column: Int32) -> TokenCounts {
        TokenCounts(input: sqlite3_column_int64(stmt, column), cacheWrite: sqlite3_column_int64(stmt, column + 1),
                    cacheRead: sqlite3_column_int64(stmt, column + 2), output: sqlite3_column_int64(stmt, column + 3),
                    reasoning: sqlite3_column_int64(stmt, column + 4))
    }

    private nonisolated static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    /// `local` 是這台 Mac 的 device_id（`meta.device_id`）；`onlyLocal` 為假時也讀其他電腦的列
    private nonisolated static func tokenDays(_ db: OpaquePointer, local: String, onlyLocal: Bool, since: String) -> [TokenDayRow]? {
        let sql = """
            SELECT device_id, day, provider, model, \(tokenColumns), task_count, task_seconds, longest_task_seconds
            FROM daily_tokens WHERE (device_id = ? OR ? = 0) AND day >= ? ORDER BY day
            """
        return rows(db, sql, [.text(local), .int(onlyLocal ? 1 : 0), .text(since)]) { stmt in
            guard let device = text(stmt, 0), let day = text(stmt, 1), let provider = text(stmt, 2), let model = text(stmt, 3) else { return nil }
            return TokenDayRow(day: day, provider: provider, model: model, counts: counts(stmt, from: 4),
                               taskCount: Int(sqlite3_column_int64(stmt, 9)), taskSeconds: Int(sqlite3_column_int64(stmt, 10)),
                               longestTaskSeconds: Int(sqlite3_column_int64(stmt, 11)),
                               device: device == local ? TokenDevices.local : device)
        }
    }

    private nonisolated static func tokenHours(_ db: OpaquePointer, device: String) -> [TokenHourRow]? {
        guard existingTables(db, ["hourly_tokens"]).count == 1 else { return [] }
        let sql = "SELECT day, hour, provider, model, \(tokenColumns) FROM hourly_tokens WHERE device_id = ?"
        return rows(db, sql, [.text(device)]) { stmt in
            guard let day = text(stmt, 0), let provider = text(stmt, 2), let model = text(stmt, 3) else { return nil }
            return TokenHourRow(day: day, hour: Int(sqlite3_column_int64(stmt, 1)), provider: provider, model: model, counts: counts(stmt, from: 4))
        }
    }

    private nonisolated static func tokenRecords(_ db: OpaquePointer) -> [String: TokenRecord]? {
        rows(db, "SELECT key, value, day FROM records", []) { stmt -> (String, TokenRecord)? in
            guard let key = text(stmt, 0) else { return nil }
            return (key, TokenRecord(value: sqlite3_column_int64(stmt, 1), day: text(stmt, 2)))
        }.map { Dictionary($0, uniquingKeysWith: { a, _ in a }) }
    }

    /// 不設下界：目前的連續天數可能比圖表範圍長（每天最多兩列，多年也只有幾千列）
    private nonisolated static func tokenRecordDays(_ db: OpaquePointer) -> [String: [String: Int64]]? {
        rows(db, "SELECT day, provider, tokens FROM record_days", []) { stmt -> (String, String, Int64)? in
            guard let day = text(stmt, 0), let provider = text(stmt, 1) else { return nil }
            return (day, provider, sqlite3_column_int64(stmt, 2))
        }.map { list in
            var result: [String: [String: Int64]] = [:]
            for (day, provider, tokens) in list { result[day, default: [:]][provider] = tokens }
            return result
        }
    }

    /// 查詢每一列；`make` 回傳 nil 的列略過（欄位是 NULL），查詢失敗時整個回傳 nil
    private nonisolated static func rows<T>(_ db: OpaquePointer, _ sql: String, _ values: [Value], _ make: (OpaquePointer?) -> T?) -> [T]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in values.enumerated() {
            switch value {
            case let .int(v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case let .text(v): sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
            }
        }
        var result: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return result }
            guard rc == SQLITE_ROW else { return nil }
            if let item = make(stmt) { result.append(item) }
        }
    }

    /// 收集器以本機時區寫入的 `YYYY-MM-DD`
    nonisolated static func tokenDay(_ date: Date) -> String {
        TokenCalendar.key(date, calendar: .current)
    }
}
