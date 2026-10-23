import Foundation

/// 「更新」按鈕觸發收集器的節流（FR-50、ADR-0008 第 8 節）。
///
/// 每次觸發收集器都會執行 `claude -p /usage`、`codex app-server`，並上傳一次快照到中繼（Cloudflare KV
/// 免費額度每天 1,000 次寫入，排程本身每天約 288 次）。所以除了「60 秒內只觸發一次」，
/// 另限制最近 24 小時最多 `dailyLimit` 次，連按或卡住的按鈕也不會用完中繼的額度。
public struct CollectorKickThrottle: Codable, Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// 可以觸發；呼叫端觸發後要呼叫 `record(at:)`
        case kick
        /// 距上次觸發不到 `minimumInterval`
        case tooSoon
        /// 最近 24 小時已達 `dailyLimit` 次
        case dailyLimitReached
    }

    public static let minimumInterval: TimeInterval = 60
    public static let dailyLimit = 100
    static let window: TimeInterval = 24 * 3600

    /// 最近 24 小時內的觸發時間（由舊到新，最多 `dailyLimit` 筆）
    public private(set) var kicks: [Date] = []

    public init() {}

    public func decision(at now: Date) -> Decision {
        let recent = kicks.filter { now.timeIntervalSince($0) < Self.window }
        // 時鐘倒退（上次觸發在未來）也視為剛觸發過，等時間追上
        if let last = recent.last, now.timeIntervalSince(last) < Self.minimumInterval { return .tooSoon }
        if recent.count >= Self.dailyLimit { return .dailyLimitReached }
        return .kick
    }

    public mutating func record(at now: Date) {
        kicks = kicks.filter { now.timeIntervalSince($0) < Self.window && $0 <= now }
        kicks.append(now)
        if kicks.count > Self.dailyLimit { kicks.removeFirst(kicks.count - Self.dailyLimit) }
    }
}
