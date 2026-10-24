import AppKit
import SwiftUI
import UsageKit

extension View {
    /// 依 `PanelSettings.appearance` 設定所在視窗的外觀，設定改變時跟著換。`PanelSettings` 要在外層以 `.environment` 提供。
    func followsAppearanceSetting() -> some View {
        modifier(FollowsAppearanceSetting())
    }

    /// 依外觀設定（FR-51）設定這個視圖所在視窗的 `NSWindow.appearance`；跟隨系統時設回 nil。
    ///
    /// 只改 App 自己的視窗（面板、設定、完整統計、設定精靈），不改 `NSApp.appearance`：
    /// 選單列圖示畫在選單列的視窗裡，顏色依選單列本身的深淺色解析，不跟這個設定。
    /// 視窗的外觀改變後 SwiftUI 的 `colorScheme` 跟著改，面板沿用 `PanelTiming.colorScheme` 的過渡（減少動態效果時直接換）。
    /// ImageRenderer 截圖沒有視窗，不受影響（截圖自己指定 `colorScheme`）。
    func windowAppearance(_ choice: AppearanceChoice) -> some View {
        background(WindowAppearanceSetter(choice: choice).frame(width: 0, height: 0))
    }
}

private struct FollowsAppearanceSetting: ViewModifier {
    @Environment(PanelSettings.self) private var settings

    func body(content: Content) -> some View {
        content.windowAppearance(settings.appearance)
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
            didSet { if choice != oldValue { apply() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            let appearance: NSAppearance? = switch choice {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
            if window.appearance?.name != appearance?.name { window.appearance = appearance }
        }
    }
}
