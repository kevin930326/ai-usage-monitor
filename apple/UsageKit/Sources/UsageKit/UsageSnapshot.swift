import Foundation

/// 收集器輸出的快照，對應 docs/02-architecture.md 的資料格式。
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: Date
    public var providers: [String: ProviderUsage]
    /// 只在 Mac 本機的 usage.json（不上傳）：收集器的本機狀態，例如磁碟空間不足而暫停記錄歷史（ADR-0014 LT-06）
    public var localStatus: LocalStatus?

    public init(schemaVersion: Int = UsageSnapshot.currentSchemaVersion, updatedAt: Date, providers: [String: ProviderUsage],
                localStatus: LocalStatus? = nil) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.providers = providers
        self.localStatus = localStatus
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
        case providers
        case localStatus = "local_status"
    }

    /// App 能解析的 schema 版本（FR-13）
    public static let currentSchemaVersion = 1
    public static let supportedSchemaVersions: Set<Int> = [1]
}

public struct LocalStatus: Codable, Equatable, Sendable {
    /// 暫停記錄歷史的原因；目前只有 "low_disk"
    public var historyPaused: String?
    public var diskFreeMB: Int?
    /// history.sqlite3 損毀、收集器改名保留並建立新檔的時間（7 天內才有，ADR-0014 D-1）
    public var historyResetAt: Date?
    /// 保留下來的舊檔名（`history.corrupt-<時間>.sqlite3`）
    public var historyKeptAs: String?

    public init(historyPaused: String? = nil, diskFreeMB: Int? = nil, historyResetAt: Date? = nil, historyKeptAs: String? = nil) {
        self.historyPaused = historyPaused
        self.diskFreeMB = diskFreeMB
        self.historyResetAt = historyResetAt
        self.historyKeptAs = historyKeptAs
    }

    public var lowDisk: Bool { historyPaused == "low_disk" }

    /// 本機狀態只是提示：個別欄位格式不對時當成沒有，不能讓整份 usage.json 讀不了
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        historyPaused = try? c.decodeIfPresent(String.self, forKey: .historyPaused)
        diskFreeMB = try? c.decodeIfPresent(Int.self, forKey: .diskFreeMB)
        historyResetAt = try? c.decodeIfPresent(Date.self, forKey: .historyResetAt)
        historyKeptAs = try? c.decodeIfPresent(String.self, forKey: .historyKeptAs)
    }

    enum CodingKeys: String, CodingKey {
        case historyPaused = "history_paused"
        case diskFreeMB = "disk_free_mb"
        case historyResetAt = "history_reset_at"
        case historyKeptAs = "history_kept_as"
    }
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public var plan: String?
    public var error: String?
    public var windows: [UsageWindow]
    /// 重置次數卷（目前只有 Codex，FR-58）；收集器沒給時為 nil
    public var resetCredits: ResetCredits?
    /// 服務狀態頁上進行中的事故（ADR-0018 第 4 節）：nil 是沒查到（不知道），空陣列是查過、沒有事故
    public var incidents: [ServiceIncident]?

    public init(plan: String? = nil, error: String? = nil, windows: [UsageWindow] = [], resetCredits: ResetCredits? = nil,
                incidents: [ServiceIncident]? = nil) {
        self.plan = plan
        self.error = error
        self.windows = windows
        self.resetCredits = resetCredits
        self.incidents = incidents
    }

    enum CodingKeys: String, CodingKey {
        case plan, error, windows, incidents
        case resetCredits = "reset_credits"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        windows = try c.decode([UsageWindow].self, forKey: .windows)
        // 選填的附加資訊：格式不對時當成沒有，不讓整份快照讀不了
        resetCredits = try? c.decodeIfPresent(ResetCredits.self, forKey: .resetCredits)
        incidents = try? c.decodeIfPresent([ServiceIncident].self, forKey: .incidents)
    }

    /// 預設顯示的額度（排除各模型等次要額度，FR-14）
    public var visibleWindows: [UsageWindow] { windows.filter { !$0.hidden } }
}

public struct UsageWindow: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var usedPct: Double
    public var resetsAt: Date?
    public var hidden: Bool
    /// 收集器算好的預測（ADR-0018 第 2 節，給沒有歷史的 iPhone）；Mac 自己用歷史算，見 `QuotaForecast.current`
    public var forecast: QuotaForecast?

    public init(id: String, label: String, usedPct: Double, resetsAt: Date? = nil, hidden: Bool = false,
                forecast: QuotaForecast? = nil) {
        self.id = id
        self.label = label
        self.usedPct = usedPct
        self.resetsAt = resetsAt
        self.hidden = hidden
        self.forecast = forecast
    }

    enum CodingKeys: String, CodingKey {
        case id, label, hidden, forecast
        case usedPct = "used_pct"
        case resetsAt = "resets_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        usedPct = try c.decode(Double.self, forKey: .usedPct)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        // v0.1 的輸出沒有 hidden 欄位
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        // 選填的附加資訊：格式不對時當成沒有
        forecast = try? c.decodeIfPresent(QuotaForecast.self, forKey: .forecast)
    }

    /// 剩餘百分比，限制在 0...100
    public var remainingPct: Double { min(max(100 - usedPct, 0), 100) }

    public var severity: UsageSeverity { UsageSeverity(remainingPct: remainingPct) }
}
