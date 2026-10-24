import SwiftUI
import UIKit
import UsageKit

extension View {
    /// 外觀設定（FR-52）：設定這個視圖所在視窗的 `overrideUserInterfaceStyle`，設定畫面等 sheet 也跟著換。
    /// 只影響 App 本身；Live Activity、動態島、小工具與手錶由系統決定，不讀這個設定。
    /// 切換時 0.3 秒交叉淡入，「減少動態效果」時直接換。
    func windowAppearance(_ choice: AppearanceChoice) -> some View {
        background(WindowAppearanceSetter(choice: choice).frame(width: 0, height: 0))
    }
}

private struct WindowAppearanceSetter: UIViewRepresentable {
    let choice: AppearanceChoice

    func makeUIView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.isUserInteractionEnabled = false
        view.choice = choice
        return view
    }

    func updateUIView(_ uiView: AppearanceView, context: Context) {
        uiView.update(choice)
    }

    final class AppearanceView: UIView {
        var choice: AppearanceChoice = .system

        func update(_ newChoice: AppearanceChoice) {
            guard newChoice != choice else { return }
            choice = newChoice
            apply(animated: true)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply(animated: false)
        }

        private func apply(animated: Bool) {
            guard let window else { return }
            let style: UIUserInterfaceStyle = switch choice {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
            guard window.overrideUserInterfaceStyle != style else { return }
            if animated, !UIAccessibility.isReduceMotionEnabled {
                UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
                    window.overrideUserInterfaceStyle = style
                }
            } else {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
