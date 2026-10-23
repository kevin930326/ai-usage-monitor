import Foundation

/// 顯示「已用 %」或「剩餘 %」（FR-17）。只用在 iPhone（App、Live Activity、iPhone 小工具），Mac 與手錶固定顯示剩餘。
public enum UsageDisplayMode: String, Codable, CaseIterable, Sendable {
    case used
    case remaining

    public var label: String {
        switch self {
        case .used: "已用"
        case .remaining: "剩餘"
        }
    }
}

public extension UsageWindow {
    /// 重置時間已過（FR-26）。Mac 離線時資料停在重置前，舊的百分比已不正確。
    func isReset(at now: Date = .now) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// 考慮重置後的已用百分比：重置時間已過就視為 0%。
    func effectiveUsedPct(at now: Date = .now) -> Double {
        isReset(at: now) ? 0 : min(max(usedPct, 0), 100)
    }

    func effectiveRemainingPct(at now: Date = .now) -> Double {
        100 - effectiveUsedPct(at: now)
    }

    func effectiveSeverity(at now: Date = .now) -> UsageSeverity {
        UsageSeverity(remainingPct: effectiveRemainingPct(at: now))
    }

    /// 依顯示模式取百分比。
    func displayedPct(_ mode: UsageDisplayMode, at now: Date = .now) -> Double {
        mode == .used ? effectiveUsedPct(at: now) : effectiveRemainingPct(at: now)
    }
}

public extension UsageSnapshot {
    /// 與 `tightestWindow` 相同，但把已重置的額度當成剩餘 100%（FR-15 + FR-26）。
    func tightestWindow(at now: Date) -> ProviderWindow? {
        orderedProviderKeys
            .flatMap { key in
                (providers[key]?.error == nil ? providers[key]?.visibleWindows ?? [] : [])
                    .map { ProviderWindow(provider: key, window: $0) }
            }
            .min { a, b in
                let ra = a.window.effectiveRemainingPct(at: now)
                let rb = b.window.effectiveRemainingPct(at: now)
                if ra != rb { return ra < rb }
                return (a.window.resetsAt ?? .distantFuture) < (b.window.resetsAt ?? .distantFuture)
            }
    }
}

/// 到 `date` 還有多久，精確到分鐘（「2天 23小時」「1小時 39分鐘」「12分鐘」）；頁尾的更新時間也用同一格式。
///
/// 手錶列表用這個取代 `Text(date, style: .relative)`：watchOS 的 `List` 列中有每秒更新的相對時間文字時，
/// 版面會不斷重新計算，App 一直吃滿 CPU（直到被系統結束）。手錶 App 已用 `TimelineView(.everyMinute)`
/// 每分鐘重繪，倒數精確到分鐘就夠了。時間已過回傳 nil（畫面顯示「已重置」）。
public enum ResetCountdown {
    public static func text(until date: Date, now: Date = .now) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)天 \(hours)小時" : "\(days)天" }
        if hours > 0 { return mins > 0 ? "\(hours)小時 \(mins)分鐘" : "\(hours)小時" }
        return minutes > 0 ? "\(mins)分鐘" : "不到 1 分鐘"
    }

    /// 手錶頁尾的更新時間（「12分鐘前更新」），同樣精確到分鐘；不到 1 分鐘為「剛剛更新」。
    public static func updatedText(since date: Date, now: Date = .now) -> String {
        guard now.timeIntervalSince(date) >= 60, let elapsed = text(until: now, now: date) else { return "剛剛更新" }
        return "\(elapsed)前更新"
    }
}
