/// 依剩餘比例分級（FR-16）：> 50% 正常、20–50% 警告、< 20% 危險。
public enum UsageSeverity: Int, Comparable, Sendable {
    case normal
    case warning
    case critical

    public static let warningBelow: Double = 50
    public static let criticalBelow: Double = 20

    public init(remainingPct: Double) {
        if remainingPct < Self.criticalBelow {
            self = .critical
        } else if remainingPct <= Self.warningBelow {
            self = .warning
        } else {
            self = .normal
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
