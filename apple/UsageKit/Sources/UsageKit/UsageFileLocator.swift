import Foundation

/// 收集器寫在 Mac 本機的 `usage.json`（FR-20），選單列 App 從這裡讀取。
/// 路徑規則與 `collector/usage_collector/paths.py` 相同：`AI_USAGE_MONITOR_HOME` 優先，
/// 否則為 `~/Library/Application Support/AIUsageMonitor`。
public struct UsageFileLocator: Sendable {
    public static let homeEnvironmentKey = "AI_USAGE_MONITOR_HOME"
    public static let fileName = "usage.json"
    /// 收集器寫的額度歷史（ADR-0009）；App 只讀
    public static let historyFileName = "history.sqlite3"

    public let directory: URL
    public var usageFile: URL { directory.appendingPathComponent(Self.fileName) }
    public var historyFile: URL { directory.appendingPathComponent(Self.historyFileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        if let custom = environment[Self.homeEnvironmentKey], !custom.isEmpty {
            directory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            directory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("AIUsageMonitor", isDirectory: true)
        }
    }

    /// 讀取並解析；檔案不存在時丟出 `CocoaError(.fileReadNoSuchFile)`。
    public func load() throws -> UsageSnapshot {
        try UsageDecoder.decode(Data(contentsOf: usageFile))
    }
}
