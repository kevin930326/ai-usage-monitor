import AppKit
import SwiftUI
import UsageKit

/// 選單列圖示的右鍵選單、全域快捷鍵與通知共用的動作（FR-47、FR-19，ADR-0008 第 7 節）。
///
/// SwiftUI 的 `MenuBarExtra` 沒有右鍵選單與「以程式打開面板」的 API：
/// - 打開面板：找到選單列圖示的按鈕（`NSStatusBarButton`，在 `NSStatusBarWindow` 裡）並 `performClick`。
/// - 右鍵選單：在 App 內監看右鍵（與 Control＋左鍵）按下事件，事件落在選單列圖示的視窗時顯示系統原生的選單。
/// 找不到按鈕時（系統改了內部結構）右鍵選單與「打開面板」不作用，其他功能照常。
@MainActor
enum AppActions {
    /// 打開完整統計視窗（由 SwiftUI 的 `openWindow` 提供；選單列標籤出現時設定）
    static var openStats: (() -> Void)?
    /// 打開設定視窗（由 SwiftUI 的 `openSettings` 提供）
    static var openSettings: (() -> Void)?
    /// 面板打開時要亮一下的卡片（點通知打開面板時設定，面板顯示後播放並清除）
    static var pendingHighlight: String?

    private static var monitor: Any?

    /// App 啟動後呼叫：開始監看選單列圖示上的右鍵。
    static func installRightClickMenu() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let isSecondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard isSecondary, let window = event.window, isStatusBarWindow(window), let button = statusButton(in: window) else {
                return event
            }
            showMenu(from: button)
            return nil
        }
    }

    /// 打開（或關閉）選單列面板，與點選單列圖示相同。
    static func togglePanel() {
        guard let button = statusButton() else {
            UsageStore.log("status item button not found")
            return
        }
        NSApplication.shared.activate()
        button.performClick(nil)
    }

    /// 打開面板；已經打開時不再點一次（否則會關掉）。
    static func openPanel(highlight cardID: String? = nil) {
        pendingHighlight = cardID
        if PanelVisibility.isVisible {
            NotificationCenter.default.post(name: PanelVisibility.highlightRequested, object: nil)
        } else {
            togglePanel()
        }
    }

    /// 立即更新：與面板的更新按鈕相同（重讀 usage.json，並請 launchd 執行收集器；60 秒內一次）
    static func refreshNow() {
        let store = UsageStore.shared
        store.reload()
        Task { _ = await CollectorTrigger.shared.trigger(usesCustomHome: store.usesCustomHome) }
    }

    // MARK: - 選單列圖示

    private static func isStatusBarWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("StatusBarWindow")
    }

    private static func statusButton(in window: NSWindow? = nil) -> NSStatusBarButton? {
        let windows = window.map { [$0] } ?? NSApplication.shared.windows.filter(isStatusBarWindow)
        for window in windows {
            if let button = findButton(window.contentView) { return button }
        }
        return nil
    }

    private static func findButton(_ view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = findButton(sub) { return found }
        }
        return nil
    }

    private static func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "立即更新", key: "r") { refreshNow() })
        let stats = ClosureMenuItem(title: "完整統計…", key: "") {
            NSApplication.shared.activate()
            openStats?()
        }
        stats.isEnabled = openStats != nil
        menu.addItem(stats)
        menu.addItem(ClosureMenuItem(title: "設定…", key: ",") {
            NSApplication.shared.activate()
            openSettings?()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "結束 AI 用量", key: "q") { NSApplication.shared.terminate(nil) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }
}

/// 面板是否看得見（`PanelView` 依視窗的可見狀態更新），以及「卡片亮一下」的請求。
@MainActor
enum PanelVisibility {
    static var isVisible = false
    static let highlightRequested = Notification.Name("AUMPanelHighlightRequested")
}

/// 以 closure 執行動作的選單項目
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func run() {
        handler()
    }
}
