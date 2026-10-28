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

/// 角色動畫的程度（ADR-0016 第 7 節）。系統開了「減少動態效果」時「完整」當成「簡單」。
enum MascotMotionLevel: String, CaseIterable, Identifiable {
    /// 全部：過場、粒子與光環、手勢、點擊反應、眨眼與看滑鼠
    case full
    /// 不播過場、不畫粒子與光環、不偵測繞圈／甩動／停留；點擊、提醒與工作中照常
    case simple
    /// 角色靜止：不眨眼、不看滑鼠、沒有任何反應；狀態點的顏色照常（面板照常展開）
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "完整"
        case .simple: "簡單"
        case .off: "關閉"
        }
    }

    /// 實際用的程度
    static func effective(_ level: MascotMotionLevel, reduceMotion: Bool) -> MascotMotionLevel {
        reduceMotion && level == .full ? .simple : level
    }

    var playsIntro: Bool { self == .full }
    var drawsParticles: Bool { self == .full }
    var detectsGestures: Bool { self == .full }
    var reacts: Bool { self != .off }
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
    /// 停止重畫時畫的那一刻（毫秒）：停下來的那一格是靜止後的畫面，不會停在眨眼一半
    private(set) var stoppedAt = 0
    /// 這次啟動後是否已經播過過場（「只有第一次」）
    private(set) var playedIntro = false

    @ObservationIgnored private let epoch = Date()
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var rateTimer: Timer?
    @ObservationIgnored private var closeTimer: Timer?
    @ObservationIgnored private var workTimer: Timer?
    @ObservationIgnored private var gestures: MascotGestureDetector?
    /// 按下時落在角色上（放開時才當成點擊）
    @ObservationIgnored private var pressedOnCharacter = false
    @ObservationIgnored private var probing = false
    /// 目前 director 依哪個動畫程度建立（彈簧是否回彈）
    @ObservationIgnored private var builtMotion = MascotMotionLevel.full
    @ObservationIgnored private let activity = MascotActivityProbe(roots: MascotActivityProbe.defaultRoots())
    /// 視窗目前該是整張畫布（展開中或收合動畫還沒播完）；建立或移動視窗時照這個決定大小
    @ObservationIgnored private(set) var windowExpanded = false

    init(configData: Data? = MascotController.bundledConfig()) {
        baseConfig = configData.flatMap { try? MascotConfig.decode($0) }
        if baseConfig == nil { UsageStore.log("mascot-anim.json missing or invalid; notch panel disabled") }
        rebuild()
        // 系統的「減少動態效果」改變時跟著換（Codex C-01）
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MascotController.shared.motionChanged() }
            }
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
        // 簡單、關閉（含減少動態效果）：面板展開不回彈
        if motion != .full { config.panel.openSpring.dampingRatio = 1 }
        builtMotion = motion
        director = MascotDirector(config: config, startTime: time(), statusLevel: director?.machine.statusLevel ?? 0)
        gestures = MascotGestureDetector(config: config)
        pressedOnCharacter = false
        // 重建後是收著的：停掉工作中的檢查（下次展開再開始）
        stopWorkChecks()
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
        startWorkChecks()
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
        stopWorkChecks()
        gestures?.reset()
        if pressedOnCharacter {
            pressedOnCharacter = false
            mutate { $0.release(at: time()) }
        }
        mutate { $0.close(at: time()) }
    }

    /// 動畫程度（設定與「減少動態效果」）
    var motion: MascotMotionLevel {
        MascotMotionLevel.effective(PanelSettings.shared.mascotMotion,
                                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// 設定改了：關閉時停掉進行中的工作姿勢，回到靜止
    func motionChanged() {
        if !motion.reacts { mutate { $0.setWorking(false, at: time()) } }
        // 彈簧的參數在建立時決定：收著時才重建（展開中等下次收合）
        if motion != builtMotion, director?.machine.isOpen == false, !windowExpanded { rebuild() }
        refresh()
    }

    /// 滑鼠在面板裡移動（畫布座標）：看滑鼠、叫醒，並偵測繞圈／甩動／停留（只在這個視窗裡）
    func pointerMoved(to point: CGPoint) {
        guard let director else { return }
        let t = time()
        let pose = director.pose(at: t)
        let machine = director.machine
        let canDetect = motion.detectsGestures && machine.isOpen && !machine.isIntro && !machine.isBusy
            && !machine.isHolding && machine.mode != .sleep
        let gesture = gestures?.move(to: point, at: t, center: CGPoint(x: pose[.x], y: pose[.y]), radius: pose[.r],
                                     canDetect: canDetect)
        mutate {
            $0.move(at: t, dx: point.x - pose[.x], dy: point.y - pose[.y])
            if let gesture { $0.gesture(gesture, at: t) }
        }
    }

    /// 按下：落在角色上才算（按住 0.35 秒捏扁）；回傳是否由角色處理（其他位置交給分頁按鈕）
    func pointerDown(at point: CGPoint) -> Bool {
        guard let director, let gestures, motion.reacts, director.machine.isOpen else { return false }
        let t = time()
        let pose = director.pose(at: t)
        guard gestures.hits(point, center: CGPoint(x: pose[.x], y: pose[.y]), radius: pose[.r]) else { return false }
        pressedOnCharacter = true
        mutate { $0.press(at: t) }
        return true
    }

    /// 放開：結束按住；在角色上放開算一次點擊（跳一下或揮手，機率照設定檔）
    func pointerUp(at point: CGPoint) {
        guard pressedOnCharacter, let director, let gestures else { return }
        pressedOnCharacter = false
        let t = time()
        let pose = director.pose(at: t)
        let onCharacter = gestures.hits(point, center: CGPoint(x: pose[.x], y: pose[.y]), radius: pose[.r])
        let choice: MascotRequest = Double.random(in: 0..<1) < director.config.interaction.tapHopProbability ? .hop : .wave
        mutate {
            $0.release(at: t)
            if onCharacter { $0.click(at: t, choice: choice) }
        }
    }

    // MARK: - 工作中（只看紀錄檔的修改時間）

    /// 展開時每 5 秒看一次 Claude／Codex 紀錄檔的修改時間；收合即停（ADR-0016 第 7 節）
    private func startWorkChecks() {
        guard workTimer == nil else { return }
        checkWorking()
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { MascotController.shared.checkWorking() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        workTimer = timer
    }

    private func stopWorkChecks() {
        workTimer?.invalidate()
        workTimer = nil
    }

    private func checkWorking() {
        guard !probing, motion.reacts else { return }
        probing = true
        let probe = activity
        Task.detached(priority: .utility) {
            let working = probe.isWorking(now: Date())
            await MainActor.run {
                let controller = MascotController.shared
                controller.probing = false
                guard controller.director?.machine.isOpen == true,
                      (controller.director?.machine.mode == .work) != working else { return }
                controller.mutate { $0.setWorking(working, at: controller.time()) }
            }
        }
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
        if !motion.playsIntro { return false }
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
        // 展開待著：眨眼、視線追滑鼠、睡覺、工作中才以每秒 30 次重畫；畫面靜止時停止，到下一次眨眼再開始。
        // 動畫關閉時展開待著也不重畫（沒有眨眼、看滑鼠）
        let live = director.isLive && motion.reacts
        let idleMoving = live && director.isIdleMoving(at: now)
        let rate: MascotRenderRate = animating ? .animating : (idleMoving ? .idle : .stopped)
        if rate != renderRate {
            if rate == .stopped { stoppedAt = now }
            renderRate = rate
        }
        // 收合動畫播完才把視窗縮回瀏海大小（展開時是整張畫布）
        let expanded = director.machine.isOpen || animating
        if expanded != windowExpanded {
            windowExpanded = expanded
            NotchPanelController.shared.setExpanded(expanded)
            // 收合動畫播完：動畫程度在展開中改過的話，現在重建
            if !expanded, motion != builtMotion {
                rebuild()
                return
            }
        }
        if live, rate == .stopped {
            // 靜止待著：下一次眨眼時再開始重畫
            rateTimer = oneShot(after: director.nextBlink(after: now) - now) { $0.refresh() }
        } else if rate != .stopped {
            // 動畫或待著的動作還在：之後再看一次（最多 0.25 秒後）
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
