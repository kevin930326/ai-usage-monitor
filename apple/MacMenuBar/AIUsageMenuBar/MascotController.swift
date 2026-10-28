import AppKit
import Observation
import SwiftUI
import UsageKit

/// 瀏海面板的過場設定（MASCOT-SPEC 第 4、9 節）
enum NotchIntroChoice: String, CaseIterable, Identifiable {
    case every
    case firstOnly
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .every: "每次展開"
        case .firstOnly: "只有第一次"
        case .off: "關閉"
        }
    }
}

/// 重畫的頻率（ADR-0016 第 6 節）：收合而且沒在動時完全停止；展開待著每秒 30 次；動畫中每秒 60 次
enum MascotRenderRate: Equatable {
    case stopped, idle, animating

    var interval: Double {
        switch self {
        case .stopped, .idle: 1.0 / 30
        case .animating: 1.0 / 60
        }
    }
}

/// 瀏海面板的版面：依實際瀏海寬度決定收合時的寬度、迷你角色與迷你圓環的位置（畫布座標，寬 580）
struct NotchLayout: Equatable {
    static let canvasWidth = 580.0
    static let canvasHeight = 190.0
    static let center = canvasWidth / 2

    /// 實體瀏海（或假瀏海中間留給相機的寬度）
    var notchWidth: Double
    var notchHeight: Double
    var hasNotch: Bool

    /// 沒有瀏海時：假瀏海中間留 130 給「相機」，左右放迷你角色與迷你圓環（總寬 250）
    static let fake = NotchLayout(notchWidth: 130, notchHeight: 32, hasNotch: false)

    var collapsedWidth: Double { max(250, notchWidth + 120) }
    var collapsedHeight: Double { max(32, notchHeight) }
    var miniX: Double { Self.center - notchWidth / 2 - 30 }
    var miniY: Double { collapsedHeight / 2 }
    /// 迷你圓環的中心；百分比接在右邊，「100%」也留在面板內
    var ringX: Double { Self.center + notchWidth / 2 + 12 }
}

/// 角色與瀏海面板的狀態（ADR-0016）。狀態機與畫面在 UsageKit 的 `MascotDirector`（純函式）；
/// 這裡負責時間基準、到期時叫 `advance`、決定重畫頻率，以及把設定與額度狀態接進去。
@Observable
@MainActor
final class MascotController {
    static let shared = MascotController()

    /// 共用設定檔（App 資源）；讀不到時瀏海面板不顯示
    let baseConfig: MascotConfig?
    private(set) var layout = NotchLayout.fake
    private(set) var director: MascotDirector?
    private(set) var renderRate = MascotRenderRate.stopped
    /// 這次啟動後是否已經播過過場（「只有第一次」）
    private(set) var playedIntro = false

    @ObservationIgnored private let epoch = Date()
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var rateTimer: Timer?
    @ObservationIgnored private var closeTimer: Timer?
    @ObservationIgnored private var windowExpanded = false

    init(configData: Data? = MascotController.bundledConfig()) {
        baseConfig = configData.flatMap { try? MascotConfig.decode($0) }
        if baseConfig == nil { UsageStore.log("mascot-anim.json missing or invalid; notch panel disabled") }
        rebuild()
    }

    static func bundledConfig() -> Data? {
        Bundle.main.url(forResource: "mascot-anim", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
    }

    /// 毫秒時間基準（單調遞增；只用來排先後與算動畫進度）
    func time(_ date: Date = Date()) -> Int {
        Int((date.timeIntervalSince(epoch) * 1000).rounded())
    }

    /// 依版面調整設定（迷你角色的位置、收合時的大小）後重建；換螢幕時呼叫
    func setLayout(_ layout: NotchLayout) {
        guard layout != self.layout || director == nil else { return }
        self.layout = layout
        rebuild()
    }

    private func rebuild() {
        guard var config = baseConfig else { return }
        config.hero.mini = MascotConfig.Point(x: layout.miniX, y: layout.miniY, radius: config.hero.mini.radius)
        config.panel.collapsed.width = layout.collapsedWidth
        config.panel.collapsed.height = layout.collapsedHeight
        director = MascotDirector(config: config, startTime: time(), statusLevel: director?.machine.statusLevel ?? 0)
        refresh()
    }

    // MARK: - 事件

    /// 滑鼠移入瀏海：展開（依設定播過場）
    func pointerEntered() {
        closeTimer?.invalidate()
        closeTimer = nil
        guard var director, !director.machine.isOpen else { return }
        let intro = shouldPlayIntro
        if intro { playedIntro = true }
        director.open(at: time(), intro: intro)
        self.director = director
        refresh()
    }

    /// 滑鼠移出：等 350 ms 再收回
    func pointerExited() {
        guard let config = baseConfig else { return }
        closeTimer?.invalidate()
        closeTimer = oneShot(after: config.panel.closeDelayMs) { $0.closeNow() }
    }

    func closeNow() {
        closeTimer?.invalidate()
        closeTimer = nil
        mutate { $0.close(at: time()) }
    }

    /// 滑鼠在面板裡移動（畫布座標）
    func pointerMoved(to point: CGPoint) {
        guard let director else { return }
        let t = time()
        let pose = director.pose(at: t)
        mutate { $0.move(at: t, dx: point.x - pose[.x], dy: point.y - pose[.y]) }
    }

    /// 依目前的快照與角色更新狀態點（讀到新資料、每分鐘、換角色時）
    func updateStatus() {
        let store = UsageStore.shared
        setStatus(NotchQuota.statusLevel(in: store.snapshot, provider: PanelSettings.shared.mascotCharacter.provider, now: store.now))
    }

    /// 額度狀態（0 正常、1 偏高、2 用完或出錯）
    func setStatus(_ level: Int) {
        guard director?.machine.statusLevel != level else { return }
        mutate { $0.setStatus(level, at: time()) }
    }

    private var shouldPlayIntro: Bool {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        switch PanelSettings.shared.notchIntro {
        case .every: return true
        case .firstOnly: return !playedIntro
        case .off: return false
        }
    }

    func mutate(_ body: (inout MascotDirector) -> Void) {
        guard var director else { return }
        body(&director)
        self.director = director
        refresh()
    }

    // MARK: - 到期與重畫頻率

    /// 依狀態機的下一個到期時間排一次計時器（不輪詢）；並決定重畫頻率，動畫結束時再降下來
    private func refresh() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        rateTimer?.invalidate()
        rateTimer = nil
        guard let director else {
            renderRate = .stopped
            return
        }
        let now = time()
        if let deadline = director.nextDeadline {
            deadlineTimer = oneShot(after: deadline - now) { controller in
                controller.mutate { $0.advance(to: controller.time()) }
            }
        }
        let animating = director.isAnimating(at: now)
        let rate: MascotRenderRate = animating ? .animating : (director.isLive ? .idle : .stopped)
        if rate != renderRate { renderRate = rate }
        // 收合動畫播完才把視窗縮回瀏海大小（展開時是整張畫布）
        let expanded = director.machine.isOpen || animating
        if expanded != windowExpanded {
            windowExpanded = expanded
            NotchPanelController.shared.setExpanded(expanded)
        }
        if rate == .animating {
            // 動畫還在跑：之後再看一次（最多 0.25 秒後）
            rateTimer = oneShot(after: 250) { $0.refresh() }
        }
    }

    private func oneShot(after ms: Int, _ action: @escaping @MainActor (MascotController) -> Void) -> Timer {
        let timer = Timer(timeInterval: max(Double(ms) / 1000, 0.001), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
