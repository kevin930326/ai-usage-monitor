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

    /// 瀏海面板顯示中（設定開著、不是截圖或示範）
    var isShown: Bool { panel != nil }
    /// 完整面板分辨「別的視窗成為 key」用
    var panelID: ObjectIdentifier? { panel.map(ObjectIdentifier.init) }

    /// 畫布左上角的螢幕座標（左下為原點；x 是畫布左緣，y 是螢幕頂端）：看滑鼠用
    func canvasOrigin() -> CGPoint? {
        guard let screen = panel?.targetScreen else { return nil }
        return CGPoint(x: screen.frame.midX - NotchLayout.canvasWidth / 2, y: screen.frame.maxY)
    }

    /// 跟著面板所在螢幕更新率的 display link（看滑鼠的高幀率用，ADR-0016 第 6 節）；面板沒顯示時 nil
    func displayLink(target: Any, selector: Selector) -> CADisplayLink? {
        panel?.contentView?.displayLink(target: target, selector: selector)
    }

    /// 游標是否在面板視窗裡
    func containsPointer() -> Bool {
        panel.map { $0.frame.contains(NSEvent.mouseLocation) } ?? false
    }

    /// 保持展開時讓面板接收 Esc（`nonactivatingPanel`：成為 key 也不會把 App 帶到前面）
    func makeKey() {
        panel?.makeKey()
    }

    /// App 啟動後與設定改變時呼叫
    func apply() {
        var enabled = PanelSettings.shared.notchEnabled && MascotController.shared.baseConfig != nil
        #if DEBUG
        // 截圖、示範與面板的量測不顯示真的瀏海面板（瀏海面板自己的量測除外）
        let env = ProcessInfo.processInfo.environment
        if (DebugTools.isDemo && env["AUM_DEMO_NOTCH_PERF"] != "1" && (env["AUM_DEMO_LOOK_PERF"] ?? "").isEmpty)
            || env["AUM_RENDER_DIR"] != nil { enabled = false }
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
        // 新的面板：控制器還在看滑鼠的話（`heroOnLayer` 沒變、不會再通知）由這裡啟動角色的圖層
        heroLayerChanged()
        MascotController.shared.panelVisibilityChanged()
    }

    private func hide() {
        MascotController.shared.closeNow()
        // 收合時看滑鼠的圖層可能正在畫：先停掉它的 display link，之後的 heroLayerChanged 已經找不到這個面板（Codex C-01）
        panel?.container.stopHeroLayer()
        panel?.orderOut(nil)
        panel = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        MascotController.shared.panelVisibilityChanged()
    }

    /// 選螢幕與位置：有瀏海的螢幕優先，否則選單列所在的主螢幕
    func place() {
        guard let panel, let screen = Self.targetScreen() else { return }
        let layout = Self.layout(for: screen)
        MascotController.shared.setLayout(layout)
        // 和控制器記錄的大小一致（收著時的提醒動畫也算展開中），之後的 setExpanded 才不會漏掉（Codex C-03）
        panel.place(on: screen, layout: layout, expanded: MascotController.shared.windowExpanded)
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
    /// 截圖檢查用（`DebugTools`）
    var debugContainer: NSView? { panel?.container }

    /// 特效要不要由 Core Animation 循環播放（收合、只有特效在動）改變了
    func effectLoopChanged() {
        panel?.container.updateEffectLoop()
    }

    func heroLayerChanged() {
        panel?.container.updateHeroLayer()
    }

    func setExpanded(_ expanded: Bool) {
        guard let panel, let screen = panel.targetScreen ?? Self.targetScreen() else { return }
        panel.place(on: screen, layout: MascotController.shared.layout, expanded: expanded)
    }
}

/// 不搶焦點、在所有桌面空間都看得到的面板
final class NotchPanel: NSPanel {
    private(set) var targetScreen: NSScreen?
    let container = NotchContainerView()

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

    /// 平常不成為 key（不搶焦點）；保持展開時才成為 key，好接收 Esc
    override var canBecomeKey: Bool { MascotController.shared.pinned }
    override var canBecomeMain: Bool { false }

    /// Esc：取消保持展開並收合
    override func cancelOperation(_ sender: Any?) {
        MascotController.shared.setPinned(false)
        MascotController.shared.closeNow()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }

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
        .environment(PanelSettings.shared)
        .environment(AgentMonitor.shared)))
    /// 只有特效在動時的角色（ADR-0021）：獨立的畫面，每一格不會讓上面整個瀏海的畫面重新排版；不接收滑鼠
    private let effectHosting = PassThroughHostingView(rootView: AnyView(NotchEffectHero()
        .environment(MascotController.shared)
        .environment(PanelSettings.shared)))
    /// 收合時 AI 工作中的特效：Core Animation 循環播放預先畫好的一輪（`MascotEffectLoop`）
    private let effectLoopView = PassThroughView()
    private var effectLoopBox = CGRect.zero
    /// 看滑鼠時的角色（CoreGraphics，每一格不經過 SwiftUI）
    private let heroLayerView = MascotHeroLayerView()
    private var tracking: NSTrackingArea?

    /// 收合、只有特效在動時播一輪；其他時候停掉並釋放圖片
    func updateEffectLoop() {
        let controller = MascotController.shared
        let wanted = controller.renderRate == .effect && controller.director?.machine.isOpen == false
        effectLoopView.layer?.removeAnimation(forKey: "effect")
        effectLoopView.layer?.contents = nil
        guard wanted, let loop = MascotEffectLoop.make(scale: Double(window?.backingScaleFactor ?? 2)) else {
            if controller.effectLoopPlaying { controller.effectLoopPlaying = false }
            return
        }
        effectLoopBox = loop.box
        layoutCanvas()
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = loop.images
        animation.calculationMode = .discrete
        animation.duration = loop.duration
        animation.repeatCount = .infinity
        animation.timeOffset = loop.offset
        animation.isRemovedOnCompletion = false
        effectLoopView.layer?.contents = loop.images.first
        effectLoopView.layer?.add(animation, forKey: "effect")
        if !controller.effectLoopPlaying { controller.effectLoopPlaying = true }
    }

    func stopHeroLayer() {
        heroLayerView.stop()
    }

    /// 只有視線在轉時由 `MascotHeroLayerView` 畫角色；其他時候停掉它的 display link
    func updateHeroLayer() {
        if MascotController.shared.heroOnLayer {
            heroLayerView.start()
            layoutCanvas()
        } else {
            heroLayerView.stop()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(hosting)
        addSubview(effectHosting)
        effectLoopView.wantsLayer = true
        addSubview(effectLoopView)
        addSubview(heroLayerView)
        layoutCanvas()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// 畫布 580×190、頂端置中；視窗變小時超出的部分被裁掉，不重新排版
    func layoutCanvas() {
        hosting.frame = NSRect(x: (bounds.width - NotchLayout.canvasWidth) / 2, y: 0,
                               width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
        effectHosting.frame = hosting.frame
        effectLoopView.frame = effectLoopBox.offsetBy(dx: hosting.frame.minX, dy: hosting.frame.minY)
        heroLayerView.frame = heroLayerView.box.offsetBy(dx: hosting.frame.minX, dy: hosting.frame.minY)
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
        if ignoresRealPointer { return }
        MascotController.shared.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        if ignoresRealPointer { return }
        MascotController.shared.pointerExited()
    }

    override func mouseMoved(with event: NSEvent) {
        if ignoresRealPointer { return }
        MascotController.shared.pointerMoved(to: canvasPoint(event))
    }

    /// 量測與截圖時游標固定（`debugPointer`）：真的滑鼠停在瀏海上也不展開，結果才不受游標位置影響
    private var ignoresRealPointer: Bool {
        #if DEBUG
        MascotController.shared.debugPointer != nil
        #else
        false
        #endif
    }

    /// 事件位置換成畫布座標（左上為原點，寬 580）
    func canvasPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x - hosting.frame.minX, y: local.y - hosting.frame.minY)
    }
}

/// 只用來顯示、不接收滑鼠的 AppKit 畫面
final class PassThroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 只用來顯示、不接收滑鼠的畫面（滑鼠交給下面的瀏海畫面）
final class PassThroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 不搶焦點的面板裡，第一下點擊就要作用（分頁按鈕）。按在角色上的交給角色（點擊、按住捏扁），其他交給 SwiftUI。
/// 只處理這個視窗自己收到的事件，不裝全域滑鼠監聽（ADR-0016 第 7 節）。
final class NotchHostingView: NSHostingView<AnyView> {
    private var characterTracking = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 設定「點瀏海直接打開完整面板」：只在真的收合時、點在瀏海那一塊才算；展開後上緣的分頁與圖釘照常（Fable F-04）
        if PanelSettings.shared.notchClickOpensPanel, MascotController.shared.director?.machine.isOpen == false,
           MascotController.shared.layout.collapsedRect.contains(canvasPoint(event)) {
            FullPanelController.shared.toggle()
            return
        }
        if MascotController.shared.pointerDown(at: canvasPoint(event)) {
            characterTracking = true
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if characterTracking {
            MascotController.shared.pointerMoved(to: canvasPoint(event))
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if characterTracking {
            characterTracking = false
            MascotController.shared.pointerUp(at: canvasPoint(event))
        } else {
            super.mouseUp(with: event)
        }
    }

    /// 右鍵（或 control＋點擊）：列出所有動作與表情、保持展開、靜音、勿擾、設定
    override func rightMouseDown(with event: NSEvent) {
        let menu = NotchMenu.build()
        menu.delegate = NotchMenu.delegate
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    /// 畫布座標（左上為原點）；畫布就是這個 view
    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
    }
}

/// 瀏海的右鍵選單（第二輪第 0 部分：表情與動作找得到）。每一項都是按鈕，照狀態機的排隊規則播；
/// 動畫程度不是「完整」時動作與表情不播（角色身體不動），項目停用並寫出原因。
/// 項目先組成 `Entry` 清單：選單與截圖（`DebugMascot`）用同一份。
@MainActor
enum NotchMenu {
    static let delegate = MenuDelegate()

    final class MenuDelegate: NSObject, NSMenuDelegate {
        func menuWillOpen(_ menu: NSMenu) { MainActor.assumeIsolated { MascotController.shared.menuWillOpen() } }
        func menuDidClose(_ menu: NSMenu) { MainActor.assumeIsolated { MascotController.shared.menuDidClose() } }
    }

    /// 動作（單擊的短反應＋長動畫）；順序就是選單的順序
    static let actions: [(MascotRequest, String)] = [
        (.hop, "跳一下"), (.wave, "揮手"), (.nod, "點頭"), (.tilt, "歪頭"), (.giggle, "偷笑"), (.look, "東張西望"),
        (.pinch, "捏一下"), (.dizzy, "轉暈"), (.shy, "害羞"), (.scared, "嚇到"),
    ]

    /// 表情（之後的 AI 狀態與服務異常也用這套）
    static let faces: [MascotMood] = [.happy, .worried, .sad, .sick, .surprised, .out, .stale]

    enum Entry {
        case header(String)
        case item(String, enabled: Bool, checked: Bool, action: @MainActor () -> Void)
        case note(String)
        case separator
    }

    /// `animates`：動畫程度是「完整」；`quietUntil`：靜音或勿擾到這個時間（沒有為 nil）
    static func entries(animates: Bool, simple: Bool, pinned: Bool, quietUntil: Date?) -> [Entry] {
        let controller = MascotController.shared
        var entries: [Entry] = [.header("動作")]
        entries += actions.map { request, title in .item(title, enabled: animates, checked: false) { controller.play(request) } }
        entries.append(.header("表情"))
        entries += faces.map { mood in .item(mood.title, enabled: animates, checked: false) { controller.playFace(mood) } }
        if !animates {
            entries.append(.note(simple ? "角色動畫是「簡單」：不播動作與表情" : "角色動畫已關閉：不播動作與表情"))
        }
        entries.append(.separator)
        entries.append(.item("保持展開", enabled: true, checked: pinned) { controller.setPinned(!controller.pinned) })
        if let quietUntil {
            entries.append(.item("取消靜音（靜音到\(quietUntil.formatted(date: .omitted, time: .shortened))）", enabled: true, checked: false) {
                controller.setQuiet(until: nil)
            })
        } else {
            entries.append(.item("靜音 1 小時", enabled: true, checked: false) { controller.setQuiet(until: Date().addingTimeInterval(3600)) })
            entries.append(.item("勿擾到明天早上 8 點", enabled: true, checked: false) {
                controller.setQuiet(until: MascotQuiet.tomorrowMorning(after: Date()))
            })
        }
        entries.append(.separator)
        // 選單列圖示可以關（ADR-0008 第 9 節）：完整面板、設定與結束都要能從這裡到達
        entries.append(.item(FullPanelController.openTitle, enabled: true, checked: false) { FullPanelController.shared.open() })
        entries.append(.item("設定…", enabled: true, checked: false) {
            AppActions.openSettings?()
            NSApplication.shared.activate()
        })
        entries.append(.item(AppActions.quitTitle, enabled: true, checked: false) { NSApplication.shared.terminate(nil) })
        return entries
    }

    static func build(now: Date = Date()) -> NSMenu {
        let controller = MascotController.shared
        let quiet = PanelSettings.shared.mascotQuietUntil.flatMap { $0 > now ? $0 : nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries(animates: controller.motion.animatesBody, simple: controller.motion == .simple,
                             pinned: controller.pinned, quietUntil: quiet) {
            switch entry {
            case .header(let title): menu.addItem(.sectionHeader(title: title))
            case .separator: menu.addItem(.separator())
            case .note(let title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .item(let title, let enabled, let checked, let action):
                let item = ClosureMenuItem(title: title, key: "") { MainActor.assumeIsolated { action() } }
                item.isEnabled = enabled
                item.state = checked ? .on : .off
                if title == "保持展開" { item.toolTip = "滑鼠離開也不收合；再點一次或按 Esc 收起" }
                if title == FullPanelController.openTitle {
                    item.image = NSImage(systemSymbolName: FullPanelController.symbol, accessibilityDescription: nil)
                    item.toolTip = FullPanelController.openHelp
                }
                menu.addItem(item)
            }
        }
        return menu
    }
}
