import Foundation

// 預期進度與用量節奏（FR-38、ADR-0008 第 4 節）。只用快照本身的資料，不需要歷史。

public extension UsageWindow {
    /// 額度長度，由 id 推得（收集器 `window_label` 的規則）：
    /// `five_hour` 5 小時、`weekly`／`weekly_*` 7 天、`<n>h` n 小時、`<n>m` n 分鐘；其他為不明（nil）。
    var duration: TimeInterval? {
        if id == "five_hour" { return 5 * 3600 }
        if id == "weekly" || id.hasPrefix("weekly_") { return 7 * 86400 }
        for (suffix, unit) in [("h", 3600.0), ("m", 60.0)] where id.hasSuffix(suffix) {
            if let n = Int(id.dropLast()), n > 0 { return Double(n) * unit }
        }
        return nil
    }

    /// 額度已經過的比例（0...1）；長度或重置時間不明、或已重置時為 nil。
    func elapsedFraction(at now: Date) -> Double? {
        guard let duration, let resetsAt, !isReset(at: now) else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / duration, 0), 1)
    }

    /// 距離重置的剩餘時間占額度長度的比例（雙圓環的內圈）。
    func timeRemainingFraction(at now: Date) -> Double? {
        elapsedFraction(at: now).map { 1 - $0 }
    }

    /// 照時間比例應剩多少 %（預期進度標記的位置）。
    func expectedRemainingPct(at now: Date) -> Double? {
        elapsedFraction(at: now).map { 100 * (1 - $0) }
    }
}

/// 用量節奏：是否用得太快，以及照目前速度大約何時用完。
public struct UsagePace: Equatable, Sendable {
    /// 已用 % 比照時間的預期多出這麼多個百分點才算太快
    public static let fastMargin: Double = 10
    /// 額度剛開始時一次大請求就會超前，經過這個比例之前不判斷
    public static let minimumElapsed: Double = 0.1

    /// 已用 % 減去照時間的預期已用 %（正數＝超前）
    public let aheadBy: Double
    /// 照本額度開始至今的平均速度，預計用完的時間；早於重置時間才有值（FR-18）
    public let exhaustsAt: Date?

    public var isTooFast: Bool { aheadBy >= Self.fastMargin }

    /// 資料過期、已重置、長度不明或經過不足 10% 時為 nil（不判斷）。
    public init?(window: UsageWindow, stale: Bool, now: Date) {
        guard !stale, let elapsed = window.elapsedFraction(at: now), elapsed >= Self.minimumElapsed,
              let duration = window.duration, let resetsAt = window.resetsAt else { return nil }
        let used = window.effectiveUsedPct(at: now)
        aheadBy = used - 100 * elapsed
        let elapsedSeconds = elapsed * duration
        if used > 0, used < 100, elapsedSeconds > 0 {
            let at = now.addingTimeInterval((100 - used) / (used / elapsedSeconds))
            exhaustsAt = at < resetsAt ? at : nil
        } else {
            exhaustsAt = used >= 100 ? now : nil
        }
    }
}

/// 選單列圖示的狀態（ADR-0008 第 1 節）。不能只靠顏色區分：太快有小點、過期整個轉灰。
public enum MenuBarState: Hashable, Sendable {
    case normal
    case tooFast
    case critical
    case stale

    public init(window: UsageWindow, stale: Bool, now: Date) {
        if stale {
            self = .stale
        } else if window.effectiveSeverity(at: now) == .critical {
            self = .critical
        } else if UsagePace(window: window, stale: stale, now: now)?.isTooFast == true {
            self = .tooFast
        } else {
            self = .normal
        }
    }
}

/// 選單列圖示要顯示哪個額度：自動（最吃緊）或指定「服務/額度 id」。
public enum MenuBarWindowChoice: Hashable, Sendable {
    case automatic
    case specific(provider: String, windowID: String)

    public init(rawValue: String) {
        let parts = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        self = parts.count == 2 ? .specific(provider: parts[0], windowID: parts[1]) : .automatic
    }

    public var rawValue: String {
        switch self {
        case .automatic: "auto"
        case let .specific(provider, windowID): "\(provider)/\(windowID)"
        }
    }
}

public extension UsageSnapshot {
    /// 依選擇取額度；指定的額度不存在、被隱藏或服務有錯誤時退回最吃緊的一項，不顯示空白圖示。
    func window(for choice: MenuBarWindowChoice, at now: Date) -> ProviderWindow? {
        if case let .specific(provider, windowID) = choice,
           let usage = providers[provider], usage.error == nil,
           let window = usage.visibleWindows.first(where: { $0.id == windowID }) {
            return ProviderWindow(provider: provider, window: window)
        }
        return tightestWindow(at: now)
    }
}
