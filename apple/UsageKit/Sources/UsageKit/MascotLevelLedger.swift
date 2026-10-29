import Foundation

/// 角色等級的獨立檔案 `level.json`（ADR-0020 第 1 節，2026-10-29 修訂）：App 把每天的合併主數字另存一份，只增不減。
/// 清除歷史、資料庫損毀重建或從備份還原讓 `level_days` 變少時，等級不會跟著變低。
/// 規則和 C#（UsageCore/MascotLevelLedger.cs）相同，`fixtures/level` 的 golden 兩邊比對。
///
/// - 格式：`{"schema_version": 1, "xp": 123, "level": 3, "days": {"2026-10-29": 12345, …}}`。`xp`、`level` 只是方便人看，
///   讀取時以 `days` 重算。
/// - 合併：每一天取較大值；只留合法的 `YYYY-MM-DD` 而且 `tokens > 0` 的日子（和 `MascotLevel` 的活躍日相同）。
/// - 讀取：不是 JSON 物件、沒有 `days` 物件時當成壞掉（nil），由呼叫端從歷史重算；`days` 裡格式不對的項目
///   （日期不合法、不是非負整數、布林值）略過，其他照用。
public enum MascotLevelLedger {
    public static let schemaVersion = 1

    /// 每天取較大值
    public static func merge(_ a: [String: Int64], _ b: [String: Int64]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (day, tokens) in a where tokens > 0 && MascotLevel.dayNumber(day) != nil {
            result[day] = max(result[day] ?? 0, tokens)
        }
        for (day, tokens) in b where tokens > 0 && MascotLevel.dayNumber(day) != nil {
            result[day] = max(result[day] ?? 0, tokens)
        }
        return result
    }

    /// 讀 `level.json` 的內容；壞掉時 nil
    public static func decode(_ data: Data) -> [String: Int64]? {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        var result: [String: Int64] = [:]
        for (day, entry) in file.days {
            if let tokens = entry.tokens, tokens > 0, MascotLevel.dayNumber(day) != nil { result[day] = tokens }
        }
        return result
    }

    private struct File: Decodable {
        var days: [String: Entry]
    }

    /// 一天的數字；不是整數（字串、布林值、小數、超出範圍）時 nil，只略過這一天
    private struct Entry: Decodable {
        var tokens: Int64?
        init(from decoder: Decoder) throws {
            tokens = try? decoder.singleValueContainer().decode(Int64.self)
        }
    }

    public static let fileName = "level.json"
    public static let corruptName = "level.corrupt.json"
    private static let lock = NSLock()

    /// 把 `days`（歷史的 `level_days`，加上這次執行已經看過的日子）併進 `file`，回傳合併後的每一天。
    /// - 檔案不在：從 `days` 建立。
    /// - 讀不懂（壞掉）：改名成 `level.corrupt.json` 保留，從 `days` 重建（每天取較大值，所以不會比歷史低）。
    /// - 讀不到（權限之類）：不改寫，只回傳 `days`，下次再試。
    /// - 內容沒有變大就不改寫；寫入先寫暫存檔（0600）再改名取代（不會留下寫一半的檔案）。
    public static func update(file: URL, adding days: [String: Int64], today: String) -> [String: Int64] {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        var stored: [String: Int64] = [:]
        var exists = fm.fileExists(atPath: file.path)
        if exists {
            guard let data = try? Data(contentsOf: file) else { return merge(days, [:]) }
            if let decoded = decode(data) {
                stored = decoded
            } else {
                let corrupt = file.deletingLastPathComponent().appendingPathComponent(corruptName)
                guard rename(file.path, corrupt.path) == 0 else { return merge(days, [:]) }
                exists = false
            }
        }
        let merged = merge(stored, days)
        if exists && merged == stored { return merged }
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(fileName).tmp")
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.createFile(atPath: temp.path, contents: encode(merged, today: today), attributes: [.posixPermissions: 0o600]),
           rename(temp.path, file.path) != 0 {
            try? fm.removeItem(at: temp)
        }
        return merged
    }

    /// 寫入 `level.json` 的內容（鍵排序、日期排序，內容相同時位元組相同，沒變就不用改寫）
    public static func encode(_ days: [String: Int64], today: String) -> Data {
        let level = MascotLevel(days: days, today: today)
        let object: [String: Any] = ["schema_version": schemaVersion, "xp": level?.xp ?? 0, "level": level?.level ?? 0,
                                     "days": days]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
}
