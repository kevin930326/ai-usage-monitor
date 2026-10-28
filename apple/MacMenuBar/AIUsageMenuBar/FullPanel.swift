import AppKit
import SwiftUI

/// 從瀏海打開的完整面板（ADR-0008 第 9 節）：和選單列圖示點開的是同一個 `PanelView`，放在不搶焦點的 `NSPanel` 裡，
/// 開在滑鼠所在螢幕的瀏海（或假瀏海）正下方、水平置中。Esc、點面板外面、再按一次快捷鍵都會關。
/// 關閉時釋放畫面（`PanelView` 看到視窗不見就停止動畫、關資料庫，同選單列的面板）。
@MainActor
final class FullPanelController {
    static let shared = FullPanelController()

    private var panel: FullPanelWindow?
    private var monitors: [Any] = []
    private var resizeObserver: NSObjectProtocol?
    /// 其他視窗（設定、統計、精靈）成為 key 時關掉（Fable F-02）
    private var keyObserver: NSObjectProtocol?
    /// 面板上緣的螢幕座標（內容高度改變時上緣不動、往下長）
    private var anchorTop: CGFloat = 0
    /// 關閉動畫播放中再按打開：取消關閉
    private var closing = false
    /// 第幾次打開：舊的關閉動畫播完時，不能收掉後來打開的那一次（Codex C-03）
    private var generation = 0

    var isOpen: Bool { panel != nil && !closing }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else {
            panel?.makeKey()
            return
        }
        // 瀏海展開中先收回（點分頁按鈕、點瀏海打開時）
        MascotController.shared.closeNow()
        let screen = Self.screenUnderPointer()
        // 上一次關閉動畫還沒播完：先收尾，不留舊的觀察者（Fable F-06）
        if closing { finishClose() }
        generation += 1
        let host = NSHostingController(rootView: FullPanelContent(screenHeight: screen.visibleFrame.height))
        host.sizingOptions = [.preferredContentSize]
        let panel = panel ?? FullPanelWindow()
        closing = false
        panel.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        anchorTop = Self.top(of: screen)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: anchorTop - size.height,
                              width: size.width, height: size.height), display: false)
        self.panel = panel
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { FullPanelController.shared.keepTop() }
        }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let id = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                // 瀏海面板（保持展開時會成為 key）不算
                guard let id, id != FullPanelController.shared.panel.map(ObjectIdentifier.init),
                      id != NotchPanelController.shared.panelID else { return }
                FullPanelController.shared.close()
            }
        }
        let instant = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = instant ? 1 : 0
        // VoiceOver 跟著前景 App 的焦點：開著 VoiceOver 時把 App 帶到前面，游標才會進面板（Fable F-08）
        if NSWorkspace.shared.isVoiceOverEnabled { NSApplication.shared.activate() }
        panel.makeKeyAndOrderFront(nil)
        if !instant {
            // ADR-0010：打開 ≤ 0.3 秒；淡入加往下 6 pt
            let target = panel.frame
            panel.setFrameOrigin(NSPoint(x: target.minX, y: target.minY + 6))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(target.origin)
            }
        }
        installMonitors()
        NSAccessibility.post(element: panel, notification: .windowCreated)
    }

    func close() {
        guard let panel, !closing else { return }
        closing = true
        removeMonitors()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        let round = generation
        let finish = { @MainActor in
            let controller = FullPanelController.shared
            guard controller.closing, controller.generation == round else { return }
            controller.finishClose()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
        }
    }

    private func finishClose() {
        closing = false
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        panel?.orderOut(nil)
        // 釋放畫面：PanelView 的可見度讀取看到視窗不見，停止動畫、關資料庫
        panel?.contentViewController = nil
        panel = nil
    }

    private func keepTop() {
        guard let panel, !closing, panel.frame.maxY != anchorTop else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: anchorTop - panel.frame.height))
    }

    /// 點面板外面就關：其他 App 的點擊（全域監看只收滑鼠按下，不讀內容）與這個 App 其他視窗的點擊
    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { _ in
            MainActor.assumeIsolated { FullPanelController.shared.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { event in
            MainActor.assumeIsolated {
                // 瀏海上的點擊由瀏海自己決定（分頁按鈕、點瀏海打開），不在這裡先關掉再被重開（Fable F-06）
                let window = event.window
                if window !== FullPanelController.shared.panel, !(window is NotchPanel),
                   window?.parent !== FullPanelController.shared.panel {
                    FullPanelController.shared.close()
                }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// 多螢幕時開在滑鼠所在的螢幕
    static func screenUnderPointer() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 面板上緣：瀏海（或選單列）正下方，留 6 pt
    static func top(of screen: NSScreen) -> CGFloat {
        let bar = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, NotchLayout.fake.notchHeight)
        return screen.frame.maxY - bar - 6
    }
}

/// 不會成為主視窗、不把 App 帶到前面的面板；可以成為 key（接收 Esc 與 VoiceOver 焦點）
final class FullPanelWindow: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityLabel("AI 用量完整面板")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        FullPanelController.shared.close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            FullPanelController.shared.close()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 同選單列面板的內容與外觀（系統選單的材質、圓角）
private struct FullPanelContent: View {
    /// 開在哪個螢幕：高度上限照那個螢幕（Fable F-11）
    let screenHeight: Double

    var body: some View {
        PanelView()
            .environment(\.panelScreenHeight, screenHeight)
            .followsAppearanceSetting()
            .environment(UsageStore.shared)
            .environment(PanelSettings.shared)
            .environment(HistoryStore.shared)
            .background(FullPanelMaterial(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// 系統選單的材質。視窗背後的模糊照視窗形狀、不看圖層遮罩，所以圓角要用 `maskImage` 裁（Fable F-09）
private struct FullPanelMaterial: NSViewRepresentable {
    let cornerRadius: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        let side = cornerRadius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        view.maskImage = mask
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
