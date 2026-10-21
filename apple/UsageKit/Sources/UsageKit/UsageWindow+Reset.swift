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
