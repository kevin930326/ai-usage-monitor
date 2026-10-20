import Foundation

/// 收集器輸出的快照，對應 docs/02-architecture.md 的資料格式。
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: Date
    public var providers: [String: ProviderUsage]

    public init(schemaVersion: Int = UsageSnapshot.currentSchemaVersion, updatedAt: Date, providers: [String: ProviderUsage]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
        case providers
    }

    /// App 能解析的 schema 版本（FR-13）
    public static let currentSchemaVersion = 1
    public static let supportedSchemaVersions: Set<Int> = [1]
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public var plan: String?
    public var error: String?
    public var windows: [UsageWindow]

    public init(plan: String? = nil, error: String? = nil, windows: [UsageWindow] = []) {
        self.plan = plan
        self.error = error
        self.windows = windows
    }

    /// 預設顯示的額度（排除各模型等次要額度，FR-14）
    public var visibleWindows: [UsageWindow] { windows.filter { !$0.hidden } }
}

public struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var usedPct: Double
    public var resetsAt: Date?
    public var hidden: Bool

    public init(id: String, label: String, usedPct: Double, resetsAt: Date? = nil, hidden: Bool = false) {
        self.id = id
        self.label = label
        self.usedPct = usedPct
        self.resetsAt = resetsAt
        self.hidden = hidden
    }

    enum CodingKeys: String, CodingKey {
        case id, label, hidden
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
    }

    /// 剩餘百分比，限制在 0...100
    public var remainingPct: Double { min(max(100 - usedPct, 0), 100) }

    public var severity: UsageSeverity { UsageSeverity(remainingPct: remainingPct) }
}
