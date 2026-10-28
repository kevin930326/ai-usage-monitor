import AppKit
import SwiftUI
import UsageKit

/// 瀏海面板的視窗（ADR-0016 第 4 節）：不會成為主視窗、不搶焦點的 `NSPanel`，蓋在選單列的瀏海上。
/// 有瀏海的螢幕以 `safeAreaInsets`／`auxiliaryTopLeftArea` 算出瀏海大小；沒有瀏海的 Mac 與外接螢幕在選單列中間畫假瀏海。
///
/// 畫面（SwiftUI）固定是 580×190 的畫布、以遮罩顯示目前的形狀（不改版面大小）；視窗本身只在展開時是整張畫布，
/// 收合時縮成瀏海大小，其他地方的點擊照常落到底下的選單列。滑鼠事件只在這個視窗自己的範圍內接收（追蹤區域），
/// 不裝全域監聽。
@MainActor
final class NotchPanelController {
    static let shared = NotchPanelController()

    private var panel: NotchPanel?
    private var observers: [NSObjectProtocol] = []

    /// App 啟動後與設定改變時呼叫
    func apply() {
        var enabled = PanelSettings.shared.notchEnabled && MascotController.shared.baseConfig != nil
        #if DEBUG
        // 截圖、示範與量測不顯示真的瀏海面板
        if DebugTools.isDemo || ProcessInfo.processInfo.environment["AUM_RENDER_DIR"] != nil { enabled = false }
        #endif
        if enabled {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        if panel == nil {
            let panel = NotchPanel()
            self.panel = panel
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { NotchPanelController.shared.place() }
                })
        }
        place()
        panel?.orderFrontRegardless()
    }

    private func hide() {
        MascotController.shared.closeNow()
        panel?.orderOut(nil)
        panel = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// 選螢幕與位置：有瀏海的螢幕優先，否則選單列所在的主螢幕
    func place() {
        guard let panel, let screen = Self.targetScreen() else { return }
        let layout = Self.layout(for: screen)
        MascotController.shared.setLayout(layout)
        panel.place(on: screen, layout: layout, expanded: MascotController.shared.director?.machine.isOpen ?? false)
    }

    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    static func layout(for screen: NSScreen) -> NotchLayout {
        let top = screen.safeAreaInsets.top
        guard top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return .fake
        }
        // 兩側可用區域之間就是瀏海（座標以螢幕左下為原點）
        let width = max(right.minX - left.maxX, 0)
        return NotchLayout(notchWidth: width > 40 ? width : 130, notchHeight: top, hasNotch: true)
    }

    /// 展開、收合時調整視窗大小（畫布本身不動）
    func setExpanded(_ expanded: Bool) {
        guard let panel, let screen = panel.targetScreen ?? Self.targetScreen() else { return }
        panel.place(on: screen, layout: MascotController.shared.layout, expanded: expanded)
    }
}

/// 不搶焦點、在所有桌面空間都看得到的面板
final class NotchPanel: NSPanel {
    private(set) var targetScreen: NSScreen?
    private let container = NotchContainerView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 蓋在選單列上面
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        contentView = container
        setAccessibilityLabel("AI 用量瀏海面板")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 收合時視窗只有瀏海（含鼓一下的空間）大；展開時是整張畫布。畫布的頂端中央永遠對齊瀏海中央
    func place(on screen: NSScreen, layout: NotchLayout, expanded: Bool) {
        targetScreen = screen
        let size: CGSize = expanded
            ? CGSize(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
            : CGSize(width: layout.collapsedWidth + 44, height: layout.collapsedHeight + 5)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        setFrame(frame, display: true)
        container.layoutCanvas()
    }
}

/// 視窗的內容：固定大小的 SwiftUI 畫布（頂端置中），以及這個視窗自己的滑鼠追蹤區域
final class NotchContainerView: NSView {
    private let hosting = NotchHostingView(rootView: AnyView(NotchView()
        .environment(MascotController.shared)
        .environment(UsageStore.shared)
        .environment(PanelSettings.shared)))
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(hosting)
        layoutCanvas()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// 畫布 580×190、頂端置中；視窗變小時超出的部分被裁掉，不重新排版
    func layoutCanvas() {
        hosting.frame = NSRect(x: (bounds.width - NotchLayout.canvasWidth) / 2, y: 0,
                               width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
    }

    override func layout() {
        super.layout()
        layoutCanvas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        MascotController.shared.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        MascotController.shared.pointerExited()
    }

    override func mouseMoved(with event: NSEvent) {
        MascotController.shared.pointerMoved(to: canvasPoint(event))
    }

    /// 事件位置換成畫布座標（左上為原點，寬 580）
    func canvasPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x - hosting.frame.minX, y: local.y - hosting.frame.minY)
    }
}

/// 不搶焦點的面板裡，第一下點擊就要作用（分頁按鈕）
final class NotchHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
