import SwiftUI
import UsageKit

public extension AppearanceChoice {
    /// 對應的 SwiftUI 外觀；跟隨系統時為 nil
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
