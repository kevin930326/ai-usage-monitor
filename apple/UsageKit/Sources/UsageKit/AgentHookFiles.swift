import Foundation

/// 連接與移除 hook 時的檔案操作（ADR-0017 第 3 節）：路徑由呼叫端決定（測試用暫存資料夾），這裡只負責
/// 讀、備份、寫。內容的合併規則在 `AgentHookConfig`。
public enum AgentHookFiles {
    public enum Result: Equatable, Sendable {
        /// 寫好了；改之前的檔案備份在這裡（原本沒有檔案時是 nil）
        case written(backup: URL?)
        /// 不用改（例如要移除時本來就沒有我們的 hook）
        case unchanged
    }

    /// 每個設定檔最多留幾份我們的備份（設定檔可能有金鑰，副本不無限累積；Fable F-11）
    public static let keepBackups = 3

    /// 連接或修好：合併我們的 hook，寫入前先備份
    public static func connect(file: URL, ai: AgentKind, command: String, now: Date = .now) throws -> Result {
        let file = resolved(file)
        let old = try read(file)
        let new = try AgentHookConfig.install(into: old, ai: ai, command: command)
        guard new != old else { return .unchanged }
        return .written(backup: try write(new, to: file, replacing: old, now: now))
    }

    /// 移除：只刪我們的 hook，寫入前先備份
    public static func disconnect(file: URL, now: Date = .now) throws -> Result {
        let file = resolved(file)
        let old = try read(file)
        guard let new = try AgentHookConfig.uninstall(from: old) else { return .unchanged }
        return .written(backup: try write(new, to: file, replacing: old, now: now))
    }

    public static func status(file: URL, ai: AgentKind, command: String) throws -> AgentHookConfig.Status {
        try AgentHookConfig.status(of: read(resolved(file)), ai: ai, command: command)
    }

    /// Codex 的 `config.toml` 有沒有把 hook 關掉（`[features]` 底下 `hooks = false`，舊名 `codex_hooks`）。
    /// 只逐行看這兩個鍵，其他內容不保留。
    public static func codexHooksDisabled(configTOML data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        var inFeatures = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if line.hasPrefix("[") {
                inFeatures = line == "[features]"
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = inFeatures ? parts[0] : (parts[0].hasPrefix("features.") ? String(parts[0].dropFirst(9)) : "")
            if (key == "hooks" || key == "codex_hooks") && parts[1] == "false" { return true }
        }
        return false
    }

    /// 備份的檔名：`<檔名>.aum-backup-<年月日-時分秒>`（本機時間）
    public static func backupURL(for file: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).aum-backup-\(formatter.string(from: now))")
    }

    // MARK: - 內部

    /// 設定檔是符號連結（例如 dotfiles 管理）時改寫連結指向的檔案：原子寫入會把連結本身換成一般檔案，
    /// 讀到的權限也是連結的 0755（Fable F-01）。備份放在真正的檔案旁邊
    static func resolved(_ file: URL) -> URL {
        file.resolvingSymlinksInPath()
    }

    private static func read(_ file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// 先備份原檔（同一秒內第二次就加序號，不覆蓋舊備份），再以原子方式寫入並保留原本的權限
    private static func write(_ data: Data, to file: URL, replacing old: Data?, now: Date) throws -> URL? {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        var permissions: Any?
        if let old {
            var candidate = backupURL(for: file, now: now)
            var n = 1
            while manager.fileExists(atPath: candidate.path) {
                n += 1
                candidate = URL(fileURLWithPath: backupURL(for: file, now: now).path + "-\(n)")
            }
            // 建立時就用原檔的權限（讀不到就 0600）：設定檔可能有別的敏感設定，備份不能比原檔更開放
            permissions = try? manager.attributesOfItem(atPath: file.path)[.posixPermissions]
            guard manager.createFile(atPath: candidate.path, contents: old,
                                     attributes: [.posixPermissions: permissions ?? 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            backup = candidate
            pruneBackups(of: file, manager: manager)
        }
        try data.write(to: file, options: .atomic)
        if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
        return backup
    }

    /// 只刪我們命名樣式的備份，留最新的幾份（檔名的時間可以照字串排序；同一秒的序號排在後面）
    private static func pruneBackups(of file: URL, manager: FileManager) {
        let folder = file.deletingLastPathComponent()
        let prefix = file.lastPathComponent + ".aum-backup-"
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        let ours = names.filter { $0.hasPrefix(prefix) }.sorted { a, b in
            let (x, y) = (a.dropFirst(prefix.count), b.dropFirst(prefix.count))
            // 「時間」與「時間-序號」：先比時間，再比序號
            let (xt, yt) = (x.prefix(15), y.prefix(15))
            if xt != yt { return xt < yt }
            return (Int(x.dropFirst(16)) ?? 1) < (Int(y.dropFirst(16)) ?? 1)
        }
        for name in ours.dropLast(keepBackups) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
