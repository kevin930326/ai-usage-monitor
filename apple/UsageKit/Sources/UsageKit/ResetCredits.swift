import Foundation

/// 可用的重置次數卷（目前只有 Codex，FR-58）：快照中服務的選填欄位 `reset_credits`。
/// 收集器在同一個 schema_version 新增，舊版收集器沒有這個欄位；App 只顯示，不使用卷。
/// 明細依到期時間分組（`count` 張同時到期，沒有時當 1 張）、早的在前、不會到期的在最後；
/// 可能比 `available` 少（後端沒給或有上限），少的部分是到期日不明。
public struct ResetCredits: Codable, Equatable, Sendable {
    public var available: Int
    public var credits: [ResetCredit]

    public struct ResetCredit: Codable, Equatable, Sendable {
        /// nil：不會到期
        public var expiresAt: Date?
        /// 這個到期時間的張數
        public var count: Int

        public init(expiresAt: Date?, count: Int = 1) {
            self.expiresAt = expiresAt
            self.count = count
        }

        enum CodingKeys: String, CodingKey {
            case expiresAt = "expires_at"
            case count
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        }
    }

    public init(available: Int, credits: [ResetCredit] = []) {
        self.available = available
        self.credits = credits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decode(Int.self, forKey: .available)
        credits = try c.decodeIfPresent([ResetCredit].self, forKey: .credits) ?? []
    }

    /// 通知「快到期」的範圍（FR-59）
    public static let expiringWithin: TimeInterval = 3 * 86400

    /// 現在還能用的張數：資料停在 Mac 上次更新時，扣掉明細中已經過了到期時間的卷
    public func usableCount(at now: Date) -> Int {
        let expired = credits.filter { $0.expiresAt.map { $0 <= now } ?? false }.reduce(0) { $0 + $1.count }
        return max(available - expired, 0)
    }

    /// 還沒到期的明細（早的在前，不會到期的排最後）
    public func upcoming(at now: Date) -> [ResetCredit] {
        credits
            .filter { $0.expiresAt.map { $0 > now } ?? true }
            .sorted { a, b in
                switch (a.expiresAt, b.expiresAt) {
                case let (a?, b?): a < b
                case (_?, nil): true
                default: false
                }
            }
    }

    /// 面板與 iPhone 的一行：「重置卷 2 張 · 最早 11/20 到期」。沒有可用的卷時為 nil（不顯示）。
    public func summary(at now: Date, calendar: Calendar = .current) -> String? {
        let count = usableCount(at: now)
        guard count > 0 else { return nil }
        guard let earliest = upcoming(at: now).compactMap(\.expiresAt).first else { return "重置卷 \(count) 張" }
        return "重置卷 \(count) 張 · \(count > 1 ? "最早 " : "")\(Self.day(earliest, calendar: calendar)) 到期"
    }

    /// 滑鼠移上去的說明：每個到期時間一行（「11/20 14:00 到期」「10/23 12:00 到期（2 張）」「不會到期」
    /// 「另 1 張到期日不明」）
    public func detailLines(at now: Date, calendar: Calendar = .current) -> [String] {
        let upcoming = upcoming(at: now)
        var lines = upcoming.map { credit in
            let when = credit.expiresAt.map { "\(Self.day($0, calendar: calendar)) \(Self.time($0, calendar: calendar)) 到期" } ?? "不會到期"
            return credit.count > 1 ? "\(when)（\(credit.count) 張）" : when
        }
        let unknown = usableCount(at: now) - upcoming.reduce(0) { $0 + $1.count }
        if unknown > 0 { lines.append(upcoming.isEmpty ? "到期日不明" : "另 \(unknown) 張到期日不明") }
        return lines
    }

    /// VoiceOver：「重置卷 2 張，最早 10 月 23 日到期」
    public func accessibilityLabel(at now: Date, calendar: Calendar = .current) -> String? {
        let count = usableCount(at: now)
        guard count > 0 else { return nil }
        guard let earliest = upcoming(at: now).compactMap(\.expiresAt).first else { return "重置卷 \(count) 張" }
        let parts = calendar.dateComponents([.month, .day], from: earliest)
        return "重置卷 \(count) 張，\(count > 1 ? "最早 " : "")\(parts.month ?? 0) 月 \(parts.day ?? 0) 日到期"
    }

    /// 將在 `expiringWithin` 內到期的卷，依到期時間分組（同一刻到期的算一組）
    public func expiring(at now: Date) -> [(expiresAt: Date, count: Int)] {
        var groups: [Date: Int] = [:]
        for credit in credits {
            guard let date = credit.expiresAt, date > now, date.timeIntervalSince(now) <= Self.expiringWithin else { continue }
            groups[date, default: 0] += credit.count
        }
        return groups.map { ($0.key, $0.value) }.sorted { $0.expiresAt < $1.expiresAt }
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
