import Foundation

// 服務狀態（FR-45、ADR-0008 第 2 節第 8 項）：收集器讀 Anthropic 與 OpenAI 的公開狀態頁，寫入本機
// `service-status.json`；App 只讀這個檔案、不連網。這裡是解碼與「服務異常還是額度用完」的判斷。

public struct ServiceStatusFile: Decodable, Equatable, Sendable {
    public var updatedAt: Date
    public var providers: [String: ProviderStatus]

    public static let fileName = "service-status.json"
    /// 收集器每 5 分鐘抓一次；超過 30 分鐘沒更新就不採信（與 usage.json 的過期門檻相同）
    public static let staleAfter: TimeInterval = UsageSnapshot.staleAfter

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case providers
    }

    public init(updatedAt: Date, providers: [String: ProviderStatus]) {
        self.updatedAt = updatedAt
        self.providers = providers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .updatedAt)
        guard let date = ISO8601DateFormatter().date(from: text) else {
            throw DecodingError.dataCorruptedError(forKey: .updatedAt, in: c, debugDescription: "updated_at")
        }
        updatedAt = date
        providers = try c.decode([String: ProviderStatus].self, forKey: .providers)
    }

    public static func decode(_ data: Data) -> ServiceStatusFile? {
        try? JSONDecoder().decode(ServiceStatusFile.self, from: data)
    }

    public func isStale(now: Date) -> Bool {
        abs(now.timeIntervalSince(updatedAt)) > Self.staleAfter
    }
}

public struct ProviderStatus: Decodable, Equatable, Sendable {
    public struct Component: Decodable, Equatable, Sendable {
        public var name: String
        public var status: String
        public var related: Bool
    }

    public struct Incident: Decodable, Equatable, Sendable {
        public var name: String
        public var impact: String
        /// 事故頁（收集器從狀態頁的事故清單組成；舊版的 service-status.json 沒有）
        public var url: String?

        public var isDisruption: Bool { ServiceIncident.disruptionImpacts.contains(impact) }
    }

    /// 「事故頁」按鈕要開的：第一筆 minor 以上、有官方事故頁的事故（維護不算）
    public var disruptionLink: URL? {
        incidents.lazy.filter(\.isDisruption).compactMap { ServiceIncident.link($0.url) }.first
    }

    /// none／minor／major／critical／maintenance；抓不到時為 nil（看 `error`）
    public var indicator: String?
    public var description: String?
    public var components: [Component]
    public var incidents: [Incident]
    public var page: String?
    public var error: String?

    public init(indicator: String?, description: String? = nil, components: [Component] = [], incidents: [Incident] = [],
                page: String? = nil, error: String? = nil) {
        self.indicator = indicator
        self.description = description
        self.components = components
        self.incidents = incidents
        self.page = page
        self.error = error
    }

    /// 有異常（維護也算，畫面上分開說明）
    public var isDisrupted: Bool { indicator.map { $0 != "none" } ?? false }

    /// 異常的元件中有這個工具相關的（Claude Code、Claude API、Codex…）
    public var affectsTool: Bool { components.contains(where: \.related) }
}

/// usage.json 裡的進行中事故（ADR-0018 第 4 節）：只有名稱、等級、事故頁與開始時間。
public struct ServiceIncident: Codable, Hashable, Sendable {
    public var name: String
    /// none／minor／major／critical／maintenance
    public var impact: String
    public var url: String?
    public var startedAt: Date?

    public init(name: String, impact: String, url: String? = nil, startedAt: Date? = nil) {
        self.name = name
        self.impact = impact
        self.url = url
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, impact, url
        case startedAt = "started_at"
    }

    /// 會影響使用的等級（minor 以上）；維護與 none 不算服務異常（瀏海、表情、iPhone 共用，同 C# 的 `IsDisruption`）
    public static let disruptionImpacts: Set<String> = ["minor", "major", "critical"]

    public var isDisruption: Bool { Self.disruptionImpacts.contains(impact) }

    /// 只接受兩個官方狀態頁的事故頁，其他網址不顯示成連結（收集器實際查的兩個狀態頁，`service_status.PAGES`）
    public static let allowedHosts: Set<String> = ["status.claude.com", "status.openai.com"]

    public var link: URL? { Self.link(url) }

    /// 整個字串必須剛好是 `https://<白名單網域>/incidents/<ID>`，ID 只有英數字、底線、連字號（1～64 字）；
    /// 大小寫、空白、帳號、連接埠、查詢字串、片段、多一層路徑都不收。和 C# 的 `IncidentLink.Link` 同一份規則，
    /// `fixtures/incident-links.json` 兩邊比對（ADR-0018 第 4 節、ADR-0015 第 2 節）。
    public static func link(_ text: String?) -> URL? {
        guard let text else { return nil }
        for host in allowedHosts.sorted() {
            let prefix = "https://\(host)/incidents/"
            guard text.hasPrefix(prefix) else { continue }
            let id = text.dropFirst(prefix.count)
            guard (1...64).contains(id.utf8.count),
                  id.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 })
            else { return nil }
            return URL(string: text)
        }
        return nil
    }
}

/// 一個服務在面板上的狀態。
public enum ServiceHealth: Equatable, Sendable {
    case operational
    /// 狀態頁回報異常；`affectsTool` 為真時寫「可能影響 Claude Code」
    case disrupted(summary: String, affectsTool: Bool)
    case maintenance(summary: String)
    /// 狀態檔太舊、沒有這個服務或抓取失敗
    case unknown

    public var isProblem: Bool {
        switch self {
        case .disrupted, .maintenance: true
        default: false
        }
    }
}

public enum ServiceStatusSummary {
    public static func health(_ file: ServiceStatusFile?, provider: String, now: Date) -> ServiceHealth {
        guard let file, !file.isStale(now: now), let status = file.providers[provider], status.error == nil,
              let indicator = status.indicator else { return .unknown }
        let names = (status.incidents.map(\.name) + status.components.map(\.name))
        let summary = names.first ?? status.description ?? "部分服務異常"
        switch indicator {
        case "none": return .operational
        case "maintenance": return .maintenance(summary: summary)
        default: return .disrupted(summary: summary, affectsTool: status.affectsTool)
        }
    }

    /// 這個服務的額度用完了嗎（任何可見額度剩 0%，且未重置）
    public static func quotaExhausted(_ snapshot: UsageSnapshot?, provider: String, now: Date) -> Bool {
        guard let usage = snapshot?.providers[provider], usage.error == nil else { return false }
        return usage.visibleWindows.contains { $0.effectiveRemainingPct(at: now) <= 0 }
    }

    /// 分辨「服務異常」與「額度用完」（FR-45）。兩者都成立時兩個都說；都沒有時 nil。
    public static func explanation(health: ServiceHealth, quotaExhausted: Bool, provider: String) -> String? {
        let name = ProviderInfo.displayName(provider)
        let maintenance = if case .maintenance = health { true } else { false }
        switch (health.isProblem, quotaExhausted) {
        case (true, true): return "\(name) 的額度已用完，同時服務也\(maintenance ? "在維護" : "有異常")"
        case (true, false): return "\(name) \(maintenance ? "正在維護" : "服務異常")，不是額度用完；稍後再試"
        // 只有確認狀態頁正常時才說「服務正常」；狀態不明時不下判斷
        case (false, true) where health == .unknown: return "\(name) 的額度已用完，等重置（服務狀態暫時無法取得）"
        case (false, true): return "\(name) 的額度已用完（服務正常），等重置"
        default: return nil
        }
    }
}
