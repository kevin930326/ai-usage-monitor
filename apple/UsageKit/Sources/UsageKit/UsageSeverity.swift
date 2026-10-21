/// 依剩餘比例分級（FR-16）：< 20% 危險（進度條紅色），其他為正常（進度條用服務識別色）。
public enum UsageSeverity: Int, Comparable, Sendable {
    case normal
    case critical

    public static let criticalBelow: Double = 20

    public init(remainingPct: Double) {
        self = remainingPct < Self.criticalBelow ? .critical : .normal
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
