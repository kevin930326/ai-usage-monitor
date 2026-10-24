import Foundation

/// 收集器寫在 Mac 本機的 `usage.json`（FR-20），選單列 App 從這裡讀取。
/// 路徑規則與 `collector/usage_collector/paths.py` 相同：`AI_USAGE_MONITOR_HOME` 優先，
/// 否則為 `~/Library/Application Support/AIUsageMonitor`。
/// 測試環境（`isTestEnvironment`）沒有指定 `AI_USAGE_MONITOR_HOME` 時直接中止，不使用真的資料夾。
public struct UsageFileLocator: Sendable {
    public static let homeEnvironmentKey = "AI_USAGE_MONITOR_HOME"
    /// 有值時視為測試環境（測試啟動的子行程、截圖與量測）
    public static let testingEnvironmentKey = "AUM_TESTING"
    public static let fileName = "usage.json"
    /// 收集器寫的額度歷史（ADR-0009）；App 只讀
    public static let historyFileName = "history.sqlite3"

    public let directory: URL
    public var usageFile: URL { directory.appendingPathComponent(Self.fileName) }
    public var historyFile: URL { directory.appendingPathComponent(Self.historyFileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `testing` 預設依 `isTestEnvironment` 判斷；測試預設路徑本身時傳 `false`。
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                testing: Bool? = nil) {
        if let custom = environment[Self.homeEnvironmentKey], !custom.isEmpty {
            directory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            precondition(!(testing ?? Self.isTestEnvironment(environment)),
                         "測試環境沒有設定 AI_USAGE_MONITOR_HOME，不使用真的資料夾")
            directory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("AIUsageMonitor", isDirectory: true)
        }
    }

    /// `AUM_TESTING` 有值、`xcodebuild test`（`XCTestConfigurationFilePath`），
    /// 或 `swift test` 的執行檔（macOS 為 swiftpm-testing-helper，Linux 為 *.xctest）
    public static func isTestEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                         processName: String = ProcessInfo.processInfo.processName) -> Bool {
        if let flag = environment[testingEnvironmentKey], !flag.isEmpty { return true }
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        return processName == "swiftpm-testing-helper" || processName == "xctest" || processName.hasSuffix(".xctest")
    }

    /// 讀取並解析；檔案不存在時丟出 `CocoaError(.fileReadNoSuchFile)`。
    public func load() throws -> UsageSnapshot {
        try UsageDecoder.decode(Data(contentsOf: usageFile))
    }
}
