// SwiftUI 只有 Apple 平台有；Linux CI 只編譯、測試 UsageKit
#if canImport(SwiftUI)
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
#endif
