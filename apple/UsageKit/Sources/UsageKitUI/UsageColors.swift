// SwiftUI 只有 Apple 平台有；Linux CI 只編譯、測試 UsageKit
#if canImport(SwiftUI)

import SwiftUI
import UsageKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension Color {
    init(_ rgb: UsageKit.RGBColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// 依淺色／深色外觀自動切換。watchOS 一律是深色背景，直接用深色值。
    init(_ adaptive: UsageKit.AdaptiveColor) {
        #if os(watchOS)
        self.init(adaptive.dark)
        #elseif canImport(UIKit)
        self.init(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? adaptive.dark : adaptive.light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #elseif canImport(AppKit)
        self.init(NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? adaptive.dark : adaptive.light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #endif
    }
}

/// 所有畫面共用的顏色（FR-16），數值與對比度測試在 UsageKit 的 `UsagePalette`。
/// 文字一律用 primary／secondary，不以顏色表示狀態；顏色只用在進度條、服務標示與提示文字。
public enum UsageColors {
    /// 服務識別色（Claude 珊瑚橘、Codex 青綠），進度條與 CL／CX 標示使用
    public static func provider(_ key: String) -> Color {
        Color(UsagePalette.provider(key))
    }

    /// 黑底上的服務標示（動態島、手錶錶面），固定用深色外觀的識別色
    public static func providerMark(_ key: String) -> Color {
        Color(UsagePalette.provider(key).dark)
    }

    /// 剩餘 < 20% 的進度條
    public static let critical = Color(UsagePalette.critical)

    /// 「資料已過期」、服務錯誤等提示文字（淺色與深色都 ≥ 4.5:1）
    public static let notice = Color(UsagePalette.notice)

    /// 資料過期時的進度條
    public static let stale = Color.gray

    /// 進度條顏色：過期灰色、剩餘 < 20% 紅色、其他為服務識別色。
    public static func bar(_ window: UsageWindow, provider key: String, stale: Bool, now: Date = .now) -> Color {
        switch window.barTone(stale: stale, at: now) {
        case .provider: provider(key)
        case .critical: critical
        case .stale: Self.stale
        }
    }
}

#endif
