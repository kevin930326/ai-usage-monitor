import Foundation

/// sRGB 顏色（0xRRGGBB），可計算 WCAG 相對亮度與對比度。
public struct RGBColor: Hashable, Sendable {
    public let hex: UInt32

    public init(_ hex: UInt32) { self.hex = hex }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    /// WCAG 2.x 相對亮度
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 對比度（1～21）。文字需 ≥ 4.5，進度條等圖形需 ≥ 3。
    public func contrastRatio(with other: RGBColor) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// 以 `opacity` 疊在 `background` 上的結果（檢查半透明色塊的對比度用）
    public func blended(over background: RGBColor, opacity: Double) -> RGBColor {
        func channel(_ shift: UInt32) -> UInt32 {
            let mix = opacity * Double((hex >> shift) & 0xFF) + (1 - opacity) * Double((background.hex >> shift) & 0xFF)
            return UInt32(mix.rounded()) << shift
        }
        return RGBColor(channel(16) | channel(8) | channel(0))
    }
}

/// 淺色與深色外觀各一個值。手錶與動態島一律是深色背景，用 `dark`。
public struct AdaptiveColor: Hashable, Sendable {
    public let light: RGBColor
    public let dark: RGBColor

    public init(light: UInt32, dark: UInt32) {
        self.light = RGBColor(light)
        self.dark = RGBColor(dark)
    }
}

/// App、Live Activity、Mac、手錶共用的顏色（FR-16）。SwiftUI 的 `Color` 在 UsageKitUI 的 `UsageColors`。
/// 服務以原創圖示（UsageKitUI 的 `ProviderIcon`）與識別色區分，不使用 Anthropic、OpenAI 的官方 logo。
public enum UsagePalette {
    /// 服務識別色。深色外觀為原色（Claude 珊瑚橘 #D97757、Codex 青綠 #5CC2B1）；
    /// 淺色外觀調暗，讓進度條與文字在白色背景上也清楚。
    public static func provider(_ key: String) -> AdaptiveColor {
        switch key {
        case "claude": AdaptiveColor(light: 0xB4532F, dark: 0xD97757)
        case "codex": AdaptiveColor(light: 0x237A6B, dark: 0x5CC2B1)
        default: AdaptiveColor(light: 0x4A5D80, dark: 0x9AAAC8)
        }
    }

    /// 剩餘 < 20% 的進度條（critical）
    public static let critical = AdaptiveColor(light: 0xD70015, dark: 0xFF453A)

    /// 「資料已過期」、服務錯誤等提示文字
    public static let notice = AdaptiveColor(light: 0xA65200, dark: 0xFF9F0A)

    /// 熱力圖的階數（不含「沒有使用」的第 0 階）
    public static let heatmapLevels = 5

    /// 熱力圖「全部」第 1～5 階的藍色（不代表任何服務）：深色外觀由暗藍到亮藍，淺色外觀由淺藍到深藍。
    public static let heatmapAll: [AdaptiveColor] = [
        AdaptiveColor(light: 0xB3CFF2, dark: 0x24497A),
        AdaptiveColor(light: 0x80ADE6, dark: 0x2D62A0),
        AdaptiveColor(light: 0x4D88CF, dark: 0x3E7DC4),
        AdaptiveColor(light: 0x2A64AD, dark: 0x5A98E0),
        AdaptiveColor(light: 0x143F7A, dark: 0x7FB2F0),
    ]

    /// 服務熱力圖第 1～5 階：服務識別色（或過期的灰色）以這些不透明度疊在卡片上
    public static let heatmapOpacities: [Double] = [0.3, 0.47, 0.64, 0.82, 1]

    /// 熱力圖「沒有使用」的格子：primary（深色為白、淺色為黑）以這個不透明度疊在卡片上
    public static let heatmapEmptyOpacity = 0.07

    /// 檢查熱力圖用的卡片底色（Mac 面板截圖實測：視窗底色上疊 primary 4.5%）
    public static let lightCard = RGBColor(0xF5F5F5)
    public static let darkCard = RGBColor(0x272727)

    /// 檢查對比度用的背景：淺色為白色，深色為系統的深灰（#1C1C1E），手錶與動態島為黑色。
    public static let lightBackground = RGBColor(0xFFFFFF)
    public static let darkBackground = RGBColor(0x1C1C1E)
    public static let blackBackground = RGBColor(0x000000)
}

/// 進度條的顏色類別：顏色本身在 UsageKitUI 依此挑選。
public enum UsageBarTone: Equatable, Sendable {
    /// 服務識別色
    case provider
    /// 剩餘 < 20%（紅色）
    case critical
    /// 資料已過期（灰色，FR-11）
    case stale
}

public extension UsageWindow {
    /// 進度條顏色規則（FR-16）：過期灰色；剩餘 < 20% 紅色；其他用服務識別色。
    /// 已重置的額度視為剩餘 100%（FR-26）。
    func barTone(stale: Bool, at now: Date = RenderClock.now) -> UsageBarTone {
        if stale { return .stale }
        return effectiveSeverity(at: now) == .critical ? .critical : .provider
    }
}
