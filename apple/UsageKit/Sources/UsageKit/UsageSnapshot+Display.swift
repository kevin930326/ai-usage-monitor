import Foundation

/// 某個服務的某個額度，用來表示「最吃緊的額度」。
public struct ProviderWindow: Equatable, Sendable {
    public var provider: String
    public var window: UsageWindow
}

public extension UsageSnapshot {
    /// 固定順序：已知服務在前，其他依名稱排序。
    static let knownProviderOrder = ["claude", "codex"]

    var orderedProviderKeys: [String] {
        providers.keys.sorted { a, b in
            let ia = Self.knownProviderOrder.firstIndex(of: a) ?? Int.max
            let ib = Self.knownProviderOrder.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }
    }

    /// 所有服務的可見額度中，剩餘最少的一項（FR-15）；同分時取較早重置的。
    /// 不考慮重置時間，畫面上請用 `tightestWindow(at:)`（FR-26）。
    var tightestWindow: ProviderWindow? {
        // 在 distantPast 時沒有額度已重置，結果等同只看 remainingPct
        tightestWindow(at: .distantPast)
    }

    /// 超過門檻沒更新就視為過期（FR-11），例如 Mac 關機。
    static let staleAfter: TimeInterval = 30 * 60

    func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.staleAfter
    }
}

public enum ProviderInfo {
    public static func displayName(_ key: String) -> String {
        switch key {
        case "claude": "Claude"
        case "codex": "Codex"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    /// 動態島精簡版面與錶面圓形複雜功能用的兩個字母標示。
    /// Claude 與 Codex 都是 C 開頭，只取首字母無法分辨。
    public static func shortName(_ key: String) -> String {
        switch key {
        case "claude": "CL"
        case "codex": "CX"
        default: String(key.prefix(2)).uppercased()
        }
    }
}
