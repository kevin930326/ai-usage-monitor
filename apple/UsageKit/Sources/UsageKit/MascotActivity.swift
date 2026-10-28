import Foundation

/// 資料夾列表裡的一項：只有名稱、是不是資料夾、修改時間（檔案系統的屬性）
public struct MascotDirectoryEntry: Sendable, Equatable {
    public var url: URL
    public var isDirectory: Bool
    public var modified: Date

    public init(url: URL, isDirectory: Bool, modified: Date) {
        self.url = url
        self.isDirectory = isDirectory
        self.modified = modified
    }
}

/// 「工作中」偵測能用的檔案系統操作：**只有列出資料夾**。沒有讀檔的方法，偵測就不可能讀到紀錄的內容
/// （ADR-0016 第 7 節：只看修改時間，絕不開啟或讀取檔案內容）。
public protocol MascotDirectoryLister: Sendable {
    func entries(in directory: URL) -> [MascotDirectoryEntry]
}

/// 實際的檔案系統：`contentsOfDirectory` 只取 `.isDirectoryKey`、`.contentModificationDateKey`，不開檔
public struct MascotFileSystemLister: MascotDirectoryLister {
    public init() {}

    public func entries(in directory: URL) -> [MascotDirectoryEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate else { return nil }
            return MascotDirectoryEntry(url: url, isDirectory: values.isDirectory ?? false, modified: modified)
        }
    }
}

/// Claude 或 Codex 是否正在跑（ADR-0016 第 5 節）：紀錄檔（`.jsonl`）最近被改過就算工作中，很久沒改就睡覺。
/// 展開時每 5 秒、收著時每 60 秒看一次（收著只為了睡覺）；不常駐監看檔案系統。接上 hook（ADR-0017）後改用 hook 的狀態。
public struct MascotActivityProbe: Sendable {
    /// 一個紀錄資料夾與往下看幾層
    public struct Root: Sendable, Equatable {
        public var url: URL
        /// 最多列出幾層（Claude：projects/<專案>/<session>.jsonl 兩層；Codex：sessions/年/月/日/*.jsonl 四層）
        public var depth: Int
        /// 每層只看名稱排最後的幾個資料夾（Codex 的年／月／日：最近的兩天）；nil 表示全部
        public var newestByName: Int?

        public init(url: URL, depth: Int, newestByName: Int? = nil) {
            self.url = url
            self.depth = depth
            self.newestByName = newestByName
        }
    }

    /// 多久內改過算工作中
    public static let activeWindow: TimeInterval = 45
    /// 一次最多列出幾個資料夾（專案很多時也有上限）
    public static let maxListings = 400

    public var roots: [Root]
    public var lister: any MascotDirectoryLister

    public init(roots: [Root], lister: any MascotDirectoryLister = MascotFileSystemLister()) {
        self.roots = roots
        self.lister = lister
    }

    /// 紀錄的位置，優先序同收集器（ADR-0009 第 3 節）：`config.json` 的 `claude_config_dir`／`codex_home`，
    /// 再來是 `CLAUDE_CONFIG_DIR`／`CODEX_HOME`，最後是 `~/.claude`、`~/.codex`。
    /// 從 Finder 打開的 App 不會繼承 shell 的環境變數，所以要看收集器的設定。
    public static func defaultRoots(config: [String: String] = [:],
                                    environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> [Root] {
        let dirs = configDirectories(config: config, environment: environment, home: home)
        return [
            Root(url: dirs.claude.appendingPathComponent("projects", isDirectory: true), depth: 2),
            Root(url: dirs.codex.appendingPathComponent("sessions", isDirectory: true), depth: 4, newestByName: 2),
        ]
    }

    /// Claude Code 與 Codex 的設定資料夾，優先序同上。hook 的安裝也用這個（Fable 總審查 F-02：和收集器、Windows 一致）
    public static func configDirectories(config: [String: String] = [:],
                                         environment: [String: String] = ProcessInfo.processInfo.environment,
                                         home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> (claude: URL, codex: URL) {
        func dir(_ configKey: String, _ envKey: String, _ fallback: String) -> URL {
            let custom = [config[configKey], environment[envKey]].compactMap { $0 }.first { !$0.isEmpty }
            guard let custom else { return home.appendingPathComponent(fallback, isDirectory: true) }
            let expanded = custom == "~" ? home.path
                : custom.hasPrefix("~/") ? home.appendingPathComponent(String(custom.dropFirst(2))).path : custom
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return (dir("claude_config_dir", "CLAUDE_CONFIG_DIR", ".claude"), dir("codex_home", "CODEX_HOME", ".codex"))
    }

    /// 從收集器的 `config.json` 只取出紀錄位置的兩個欄位（其他欄位不讀出來；讀不到或格式不對時回傳空的）
    public static func logDirectories(fromConfig data: Data?) -> [String: String] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for key in ["claude_config_dir", "codex_home"] {
            if let value = object[key] as? String, !value.isEmpty { result[key] = value }
        }
        return result
    }

    /// 最近 `activeWindow` 秒內有沒有紀錄檔被改過
    public func isWorking(now: Date) -> Bool {
        isActive(within: Self.activeWindow, now: now)
    }

    /// 最近 `seconds` 秒內有沒有紀錄檔被改過（睡覺：Claude 與 Codex 都超過設定的分鐘數沒動就睡）
    public func isActive(within seconds: TimeInterval, now: Date) -> Bool {
        let since = now.addingTimeInterval(-seconds)
        // 每個服務各有一份預算：Claude 的專案再多，也不會讓 Codex 沒得看（Codex 第二輪 C-03）
        let share = Self.maxListings / max(roots.count, 1)
        return roots.contains { root in
            var budget = share
            return scan(root.url, depth: root.depth, root: root, since: since, budget: &budget)
        }
    }

    private func scan(_ directory: URL, depth: Int, root: Root, since: Date, budget: inout Int) -> Bool {
        guard depth > 0, budget > 0 else { return false }
        budget -= 1
        let entries = lister.entries(in: directory)
        if entries.contains(where: { !$0.isDirectory && $0.url.pathExtension == "jsonl" && $0.modified >= since }) {
            return true
        }
        var folders = entries.filter(\.isDirectory)
        if let newest = root.newestByName {
            folders = Array(folders.sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }.prefix(newest))
        } else {
            // 最近改過的資料夾（新的 session 檔）先看
            folders.sort { $0.modified > $1.modified }
        }
        return folders.contains { scan($0.url, depth: depth - 1, root: root, since: since, budget: &budget) }
    }
}
