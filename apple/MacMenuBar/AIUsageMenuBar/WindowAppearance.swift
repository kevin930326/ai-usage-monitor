import AppKit
import SwiftUI
import UsageKit
import UsageKitUI

extension View {
    /// 依 `PanelSettings.appearance` 設定所在視窗的外觀，設定改變時跟著換。`PanelSettings` 要在外層以 `.environment` 提供。
    func followsAppearanceSetting() -> some View {
        modifier(FollowsAppearanceSetting())
    }

    /// 依外觀設定（FR-51）設定這個視圖所在視窗的 `NSWindow.appearance`（`.aqua`／`.darkAqua`）；跟隨系統時設回 nil。
    ///
    /// SwiftUI 管理的視窗（面板的 MenuBarExtra、Settings、Window scene）會依內容的 `preferredColorScheme` 重設
    /// `NSWindow.appearance`：只設 appearance 時會被設回 nil，視窗背景跟著系統、內容的顏色卻已依設定解析
    /// （系統深色＋App 淺色時深底黑字）。所以同時給 SwiftUI 相同的 `preferredColorScheme`，兩邊要的外觀一致。
    /// 從淺色／深色改回跟隨系統時，SwiftUI 不會把內容的 `colorScheme` 改回系統的值（視窗已經換了、文字還是舊的），
    /// 所以內容的 `colorScheme` 一律明確給：選了淺色／深色就是它，跟隨系統時是 `SystemAppearance` 觀察到的系統外觀。
    ///
    /// 只改 App 自己的視窗（面板、設定、完整統計、設定精靈），不改 `NSApp.appearance`：
    /// 選單列圖示畫在選單列的視窗裡，顏色依選單列本身的深淺色解析，不跟這個設定。
    /// 內容的 `colorScheme` 改變時，面板等沿用 `PanelTiming.colorScheme` 的過渡（減少動態效果時直接換）。
    /// ImageRenderer 截圖沒有視窗，不受影響（截圖自己指定 `colorScheme`）。
    func windowAppearance(_ choice: AppearanceChoice) -> some View {
        background(WindowAppearanceSetter(choice: choice).frame(width: 0, height: 0))
    }
}

private struct FollowsAppearanceSetting: ViewModifier {
    @Environment(PanelSettings.self) private var settings
    private let system = SystemAppearance.shared

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, settings.appearance.colorScheme ?? system.colorScheme)
            .preferredColorScheme(settings.appearance.colorScheme)
            .windowAppearance(settings.appearance)
    }
}

/// 系統（App 層級）目前的淺色／深色，系統切換時更新。跟隨系統時視窗內容的 `colorScheme` 用這個值。
@MainActor @Observable
final class SystemAppearance {
    static let shared = SystemAppearance()

    private(set) var colorScheme: ColorScheme
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        colorScheme = Self.current
        observation = NSApplication.shared.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let scheme = Self.current
                    if SystemAppearance.shared.colorScheme != scheme { SystemAppearance.shared.colorScheme = scheme }
                }
            }
        }
    }

    private static var current: ColorScheme {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

private struct WindowAppearanceSetter: NSViewRepresentable {
    let choice: AppearanceChoice

    func makeNSView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.choice = choice
        return view
    }

    func updateNSView(_ nsView: AppearanceView, context: Context) {
        nsView.choice = choice
    }

    final class AppearanceView: NSView {
        var choice: AppearanceChoice = .system {
            didSet {
                guard choice != oldValue else { return }
                reapplied = 0
                apply()
            }
        }
        private var observation: NSKeyValueObservation?
        /// 視窗外觀被別人改掉後套回的次數；SwiftUI 若一直改回去，不要和它無限來回
        private var reapplied = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            reapplied = 0
            apply()
            observation = window?.observe(\.appearance) { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.reapplyIfChanged() }
                }
            }
        }

        private var wanted: NSAppearance? { choice.nsAppearance }

        private func reapplyIfChanged() {
            guard let window, window.appearance?.name != wanted?.name, reapplied < 3 else { return }
            reapplied += 1
            apply()
        }

        private func apply() {
            guard let window else { return }
            let appearance = wanted
            #if DEBUG
            if ProcessInfo.processInfo.environment["AUM_DEBUG_APPEARANCE"] == "1" {
                UsageStore.log("appearance \(window.title) \(window.appearance?.name.rawValue ?? "nil") -> \(appearance?.name.rawValue ?? "nil")")
            }
            #endif
            if window.appearance?.name != appearance?.name { window.appearance = appearance }
        }
    }
}

extension AppearanceChoice {
    /// 這個設定對應的 AppKit 外觀；跟隨系統時為 nil。SwiftUI 以外自己顯示的視窗（例如 `NSSavePanel`）也要套用
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
