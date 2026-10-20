import SwiftUI
import UsageKit

public extension UsageSeverity {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}
