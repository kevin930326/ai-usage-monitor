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
    /// 全部：過場、粒子與光環、手勢、點擊與提醒的反應、工作與睡覺的動作、眨眼與看滑鼠
    case full
    /// 身體靜止、只有眼睛會動（眨眼、看滑鼠）：不播過場、反應、光環，也不偵測手勢；面板展開不回彈
    case simple
    /// 角色完全靜止：也不眨眼、不看滑鼠；只有表情（額度的眼睛）會換（面板照常展開）
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
    /// 身體會動：點擊、手勢、提醒的反應，工作與睡覺的動作
    var animatesBody: Bool { self == .full }
    /// 眼睛會動：眨眼、看滑鼠
    var movesEyes: Bool { self != .off }
    /// 外觀的特效會動（ADR-0021）；簡單、關閉與「減少動態效果」時是靜態的一格
    var animatesEffects: Bool { self == .full }
}

/// 重畫的頻率（ADR-0016 第 6 節）：收合或畫面靜止時完全停止；展開待著（眨眼、看滑鼠、工作）每秒 30 次、睡著 12 次；動畫中每秒 60 次
enum MascotRenderRate: Equatable {
    case stopped, effect, breathing, gaze, idle, animating

    var interval: Double {
        switch self {
        // 睡著只有慢慢的呼吸（一次約 4 秒）與飄起來的 z：每秒 10 次就夠
        case .breathing: 1.0 / 10
        // 只有視線在追游標（展開或收合）：每秒 15 次（游標位置本身每秒只讀約 12 次）
        case .gaze: 1.0 / 15
        // 只有外觀的特效在動（收合時 AI 工作中、展開待著）：每秒 12 次（ADR-0021）
        case .effect: 1.0 / 12
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
    /// 角色外觀清單（App 資源，ADR-0021）；讀不到時只有「跟著服務」
    let looks: MascotLooks?
    /// 外觀的特效正在動（AI 工作中，或展開時）；否則畫靜態的一格
    private(set) var effectsLive = false
    /// 特效自己的時鐘（毫秒）：停住時停在最後一格，再動時從那一格接著走，不會跳回第 0 格（Fable F-08）
    private var effectBase = 0
    /// 收合時的特效由 Core Animation 循環播放中（`MascotEffectLoop`）；這時 SwiftUI 不畫角色
    var effectLoopPlaying = false
    /// 目前循環播放的那一輪是依什麼畫的（nil 是沒在播）
    private var effectLoopKey: EffectLoopKey?
    private var effectStart = 0
    private(set) var layout = NotchLayout.fake
    private(set) var director: MascotDirector?
    private(set) var renderRate = MascotRenderRate.stopped
    /// 不在動畫中時，面板形狀與額度卡固定畫的那一刻（毫秒）；完全停止時角色也畫這一刻，不會停在眨眼一半
    private(set) var stoppedAt = 0
    /// 這次啟動後是否已經播過過場（「只有第一次」）
    private(set) var playedIntro = false
    /// 保持展開：滑鼠離開也不收合，再點一次（選單或上緣的圖釘）或按 Esc 才收
    private(set) var pinned = false
    /// 右鍵選單開著（滑鼠移到選單上不算離開）
    @ObservationIgnored private var menuOpen = false
    /// 第一次展開時顯示一次「右鍵有更多」的提示
    private(set) var showsHint = false
    /// 展開時右邊那張卡：額度或 AI 工作階段
    private(set) var page = NotchPage.overview
    /// 等你下一個指令時收合瀏海在脈動（循環由 Core Animation 跑，App 不用每 7 秒醒來）
    private(set) var pulsing = false

    /// 啟動時的系統開機時間（秒）；時間基準用它而不是牆鐘，改系統時間或校時倒退時動畫不會卡住
    @ObservationIgnored private let epoch = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var rateTimer: Timer?
    @ObservationIgnored private var closeTimer: Timer?
    @ObservationIgnored private var workTimer: Timer?
    @ObservationIgnored private var gazeTimer: Timer?
    /// 上一次游標相對角色的位置與連續沒變的次數（沒變一陣子就降低讀取頻率）
    @ObservationIgnored private var lastPointer: CGPoint?
    @ObservationIgnored private var pointerStillTicks = 0
    /// 睡著時輪詢降到每秒 1 次
    @ObservationIgnored private var gazeDozing = false
    @ObservationIgnored private var hoverTimer: Timer?
    @ObservationIgnored private var gestures: MascotGestureDetector?
    /// 按下時落在角色上（放開時才當成點擊）
    @ObservationIgnored private var pressedOnCharacter = false
    /// 正在列舉紀錄資料夾（同時最多一個；卡在無回應的網路磁碟時不再另開，不會累積執行緒）
    @ObservationIgnored private var probing = false
    /// 每次收合或重建遞增：上一輪的列舉結果回來時直接丟掉，不覆寫較新的狀態（Codex C-01、C-02）
    @ObservationIgnored private var probeGeneration = 0
    /// 目前 director 依哪個動畫程度建立（彈簧是否回彈）
    @ObservationIgnored private var builtMotion = MascotMotionLevel.full
    /// 目前 director 依哪個版面建立；展開中換螢幕時等收合後再重建（Fable F-03）
    @ObservationIgnored private var builtLayout: NotchLayout?
    /// 視窗目前該是整張畫布（展開中或收合動畫還沒播完）；建立或移動視窗時照這個決定大小
    @ObservationIgnored private(set) var windowExpanded = false

    init(configData: Data? = MascotController.bundledConfig()) {
        baseConfig = configData.flatMap { try? MascotConfig.decode($0) }
        if baseConfig == nil { UsageStore.log("mascot-anim.json missing or invalid; notch panel disabled") }
        looks = Self.bundledLooks().flatMap { try? MascotLooks.decode($0) }
        if looks == nil { UsageStore.log("mascot-looks.json missing or invalid; only the service colors") }
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

    static func bundledLooks() -> Data? {
        Bundle.main.url(forResource: "mascot-looks", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
    }

    /// 設定裡選的外觀；nil 是跟著服務（沒選、或清單裡已經沒有這個代號）
    var look: MascotLook? { looks?.look(PanelSettings.shared.mascotLook) }

    /// 特效那一格的時間；nil 是靜態的一格（動畫「簡單」「關閉」、減少動態效果、不會動的外觀）
    func effectTime(at t: Int) -> Int? {
        guard motion.animatesEffects, look?.style.animates == true else { return nil }
        return effectsLive ? effectBase + max(t - effectStart, 0) : effectBase
    }

    /// 外觀改了：特效要不要動可能跟著變；循環的那一輪由 `updateEffectLoop` 重建
    func lookChanged() {
        refresh()
    }

    /// 毫秒時間基準（單調遞增；只用來排先後與算動畫進度）。以開機時間計，
    /// `date`（TimelineView 給的牆鐘時刻）只取它和現在的差，系統時間倒退不影響（Fable F-02）
    func time(_ date: Date? = nil) -> Int {
        let uptime = ProcessInfo.processInfo.systemUptime + (date?.timeIntervalSinceNow ?? 0)
        return Int(((uptime - epoch) * 1000).rounded())
    }

    /// 依版面調整設定（迷你角色的位置、收合時的大小）後重建；換螢幕時呼叫
    func setLayout(_ layout: NotchLayout) {
        guard layout != self.layout || director == nil else { return }
        self.layout = layout
        // 展開中（含收合動畫）不重建，不然滑鼠還在面板裡卻縮回瀏海；收合後在 refresh 重建
        if !windowExpanded { rebuild() }
    }

    private func rebuild() {
        guard var config = baseConfig else { return }
        config.hero.mini = MascotConfig.Point(x: layout.miniX, y: layout.miniY, radius: config.hero.mini.radius)
        config.panel.collapsed.width = layout.collapsedWidth
        config.panel.collapsed.height = layout.collapsedHeight
        // 簡單、關閉（含減少動態效果）：面板展開不回彈
        if motion != .full { config.panel.openSpring.dampingRatio = 1 }
        builtMotion = motion
        builtLayout = layout
        director = MascotDirector(config: config, startTime: time(), statusLevel: director?.machine.statusLevel ?? 0)
        director?.setStill(!motion.animatesBody, at: time())
        gestures = MascotGestureDetector(config: config)
        pressedOnCharacter = false
        lastPointer = nil
        // 重建後是收著的：活動改成收著的頻率（只為了睡覺）
        restartActivityChecks()
        updateStatus()
        restartGaze()
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
        if !PanelSettings.shared.notchHintShown { showsHint = true }
        let monitor = AgentMonitor.shared
        if monitor.sessions.count(.needsYou, at: monitor.now) > 0 { page = .agents }
        refresh()
        restartActivityChecks()
        // 展開就算看過了：「完成」與「出錯」不再當成新消息（ADR-0017）
        AgentMonitor.shared.markSeen()
        // 等級（ADR-0020）：每次展開重新讀；升級時 levelUp 歡呼
        MascotLevelStore.shared.refresh()
    }

    /// 滑鼠移出：等 350 ms 再收回（保持展開、右鍵選單開著時不收）
    func pointerExited() {
        guard let config = baseConfig, !pinned, !menuOpen else { return }
        closeTimer?.invalidate()
        closeTimer = oneShot(after: config.panel.closeDelayMs) { $0.closeNow() }
    }

    /// 保持展開：開了就不因滑鼠離開而收合；關掉時滑鼠不在面板上就收
    func setPinned(_ on: Bool) {
        guard pinned != on else { return }
        pinned = on
        if on {
            closeTimer?.invalidate()
            closeTimer = nil
            if director?.machine.isOpen != true { pointerEntered() }
            // 讓面板接收 Esc（不搶焦點的面板：成為 key 也不會啟用 App）
            NotchPanelController.shared.makeKey()
        } else if !NotchPanelController.shared.containsPointer() {
            closeNow()
        }
    }

    func closeNow() {
        closeTimer?.invalidate()
        closeTimer = nil
        pinned = false
        if showsHint {
            showsHint = false
            PanelSettings.shared.notchHintShown = true
        }
        gestures?.reset()
        hoverTimer?.invalidate()
        hoverTimer = nil
        if pressedOnCharacter {
            pressedOnCharacter = false
            mutate { $0.release(at: time()) }
        }
        mutate { $0.close(at: time()) }
        page = .overview
        restartActivityChecks()
        updatePulse()
    }

    /// 上緣的分頁：額度或 AI 工作階段
    func setPage(_ page: NotchPage) {
        self.page = page
    }

    /// 動畫程度（設定與「減少動態效果」）
    var motion: MascotMotionLevel {
        MascotMotionLevel.effective(PanelSettings.shared.mascotMotion,
                                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// 設定改了：關閉時停掉進行中的工作姿勢，回到靜止
    func motionChanged() {
        restartGaze()
        // 身體不動的程度：正在播的反應與特效立刻停（Codex C-02、C-03）
        mutate { $0.setStill(!motion.animatesBody, at: time()) }
        // 彈簧的參數在建立時決定：收著時才重建（展開中等下次收合）
        if motion != builtMotion, director?.machine.isOpen == false, !windowExpanded { rebuild() }
        refresh()
        // 脈動：開了「減少動態效果」或動畫關閉時，進行中的也立刻停
        updatePulse()
    }

    /// 滑鼠在面板裡移動（畫布座標）：偵測繞圈／甩動／停留（只在這個視窗裡）。看滑鼠另外由 `pollPointer` 處理（整個螢幕）
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
            $0.move(at: t)
            if let gesture { $0.gesture(gesture, at: t) }
        }
        scheduleHoverCheck()
    }

    /// 停在角色上不動時沒有移動事件：在停留到期時檢查一次（Codex C-04）
    private func scheduleHoverCheck() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard let deadline = gestures?.hoverDeadline else { return }
        hoverTimer = oneShot(after: deadline - time()) { $0.hoverDue() }
    }

    private func hoverDue() {
        hoverTimer = nil
        guard let director else { return }
        let machine = director.machine
        let canDetect = motion.detectsGestures && machine.isOpen && !machine.isIntro && !machine.isBusy
            && !machine.isHolding && machine.mode != .sleep
        let t = time()
        if let gesture = gestures?.checkHover(at: t, canDetect: canDetect) {
            mutate { $0.gesture(gesture, at: t) }
        }
    }

    /// 按下：落在角色上才算（按住 0.35 秒捏扁）；回傳是否由角色處理（其他位置交給分頁按鈕）
    func pointerDown(at point: CGPoint) -> Bool {
        guard let director, let gestures, motion.animatesBody, director.machine.isOpen else { return false }
        let t = time()
        let pose = director.pose(at: t)
        guard gestures.hits(point, center: CGPoint(x: pose[.x], y: pose[.y]), radius: pose[.r]) else { return false }
        pressedOnCharacter = true
        mutate { $0.press(at: t) }
        AgentMonitor.shared.markSeen()
        return true
    }

    /// 放開：結束按住；在角色上放開算一次點擊（從所有短反應平均隨機挑一個，清單照設定檔）
    func pointerUp(at point: CGPoint) {
        guard pressedOnCharacter, let director, let gestures else { return }
        pressedOnCharacter = false
        let t = time()
        let pose = director.pose(at: t)
        let onCharacter = gestures.hits(point, center: CGPoint(x: pose[.x], y: pose[.y]), radius: pose[.r])
        let choice = director.config.interaction.tapReactions.compactMap(MascotRequest.init).randomElement() ?? .hop
        mutate {
            $0.release(at: t)
            if onCharacter { $0.click(at: t, choice: choice) }
        }
    }

    // MARK: - 工作中與睡覺（只看紀錄檔的修改時間）

    /// 展開時每 5 秒、收著時每 60 秒看一次 Claude／Codex 紀錄檔的修改時間（收著只為了睡覺；ADR-0016 第 5 節）
    private func restartActivityChecks() {
        workTimer?.invalidate()
        workTimer = nil
        probeGeneration += 1
        guard director != nil, NotchPanelController.shared.isShown else { return }
        checkWorking()
        let open = director?.machine.isOpen == true
        let timer = Timer(timeInterval: open ? 5 : 60, repeats: true) { _ in
            MainActor.assumeIsolated { MascotController.shared.checkWorking() }
        }
        timer.tolerance = open ? 1 : 10
        RunLoop.main.add(timer, forMode: .common)
        workTimer = timer
    }

    /// 瀏海面板顯示或隱藏：看滑鼠與活動檢查跟著開關
    func panelVisibilityChanged() {
        // 面板換了一個：舊的循環跟著舊視窗不見，新的視窗依目前狀態重建（Codex C-02）
        effectLoopKey = nil
        effectLoopPlaying = false
        updateEffectLoop()
        restartGaze()
        restartActivityChecks()
    }

    /// 設定改了（睡覺的分鐘數）：馬上看一次
    func checkActivitySoon() {
        restartActivityChecks()
    }

    private func checkWorking() {
        guard !probing, motion.animatesBody else { return }
        #if DEBUG
        if debugSkipsActivity { return }
        #endif
        let idleAfter = TimeInterval(PanelSettings.shared.mascotSleepMinutes * 60)
        probing = true
        let generation = probeGeneration
        let dataDirectory = UsageStore.shared.locator.directory
        let configURL = dataDirectory.appendingPathComponent("config.json")
        // 測試、截圖與量測：只看暫存資料夾裡的紀錄，不碰真的 ~/.claude、~/.codex
        var testing = UsageFileLocator.isTestEnvironment()
        #if DEBUG
        testing = testing || DebugTools.isDemo
        #endif
        // 有 hook 工作階段的 AI 照 hook 的狀態，不必再列它的紀錄資料夾（ADR-0017 第 4 節）
        let hooked = Set(AgentKind.allCases.filter { AgentMonitor.shared.hasSessions($0) })
        Task.detached(priority: .utility) {
            // 紀錄的位置同收集器：config.json 優先（只取兩個欄位），再來是環境變數與預設位置（Codex C-06）
            // 測試與示範：不讀 config.json，只看暫存資料夾（示範模式沒設 AI_USAGE_MONITOR_HOME 時 config.json 是真的，Fable F-04）
            let dirs = testing ? [:] : MascotActivityProbe.logDirectories(fromConfig: try? Data(contentsOf: configURL))
            let roots = testing
                ? MascotActivityProbe.defaultRoots(config: dirs, environment: [:], home: dataDirectory)
                : MascotActivityProbe.defaultRoots(config: dirs)
            let now = Date()
            // defaultRoots 的順序是 Claude、Codex
            var fallback: [AgentKind: (working: Bool, active: Bool)] = [:]
            for (ai, root) in zip([AgentKind.claude, .codex], roots) where !hooked.contains(ai) {
                let probe = MascotActivityProbe(roots: [root])
                let working = probe.isWorking(now: now)
                fallback[ai] = (working, working || probe.isActive(within: idleAfter, now: now))
            }
            let result = fallback
            await MainActor.run {
                let controller = MascotController.shared
                controller.probing = false
                guard generation == controller.probeGeneration else { return }
                controller.fallbackActivity = result
                controller.applyActivity()
            }
        }
    }

    /// 修改時間判斷的上一次結果（沒接 hook 的 AI 用）
    @ObservationIgnored private var fallbackActivity: [AgentKind: (working: Bool, active: Bool)] = [:]

    /// hook 的狀態變了：馬上重算工作中、需要你與睡覺（不等下一次修改時間的檢查），以及表情與脈動
    func agentStateChanged() {
        applyActivity()
        updateStatus()
        updatePulse()
        // 工作階段都結束了：沒有東西可列，回到額度
        if AgentMonitor.shared.sessions.isEmpty { page = .overview }
    }

    /// 一個回合完成：展開時揮手；收著時瀏海鼓一下、迷你角色揮手。靜音、勿擾時不動；瀏海沒顯示時不排任何動畫（NFR-8，Codex C-02）
    func agentFinished() {
        guard NotchPanelController.shared.isShown else { return }
        let quiet = PanelSettings.shared.isMascotQuiet(at: Date())
        mutate { $0.cheer(at: time(), react: !quiet) }
    }

    /// 升級（ADR-0020 第 4 節）：展開時跳一下再開心（和回合完成的揮手分得出來）。
    /// 回傳是否處理完：收合、首次提示顯示中、靜音或勿擾、過場或其他動作中時回傳 false（呼叫端稍後再試或下次展開再播）；
    /// 動畫「簡單」「關閉」（含系統減少動態效果）不播身體的反應（ADR-0016），只更新數字、算處理完
    func levelUp() -> Bool {
        guard NotchPanelController.shared.isShown, let machine = director?.machine, machine.isOpen, !showsHint,
              !PanelSettings.shared.isMascotQuiet(at: Date()) else { return false }
        guard motion.animatesBody else { return true }
        // 過場或其他動作中：排隊只留最後一個，「跳一下」會被「開心」蓋掉（Codex C-02）。等可以馬上播時再來
        guard !machine.isIntro, !machine.isBusy, !machine.isHolding else { return false }
        mutate {
            $0.request(.hop, at: time())
            $0.request(.faceHappy, at: time())
        }
        return true
    }

    /// 等你下一個指令（而且沒有更優先的狀態）：收著時每 7 秒輕輕脈動一次（1.6 秒）；
    /// 展開、靜音或勿擾、動畫關閉、系統「減少動態效果」、設定關掉時不脈動（FR-25、ADR-0010，Codex C-03）
    private func updatePulse() {
        let monitor = AgentMonitor.shared
        let settings = PanelSettings.shared
        let wanted = settings.notchWaitingPulse && NotchPanelController.shared.isShown && director?.machine.isOpen == false
            && motion != .off && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !settings.isMascotQuiet(at: Date())
            && monitor.sessions.top(at: monitor.now)?.state(at: monitor.now, idleAfter: monitor.sessions.idleAfter) == .waiting
        if pulsing != wanted { pulsing = wanted }
    }

    static let pulseEveryMs = 7000
    static let pulseMs = 1600

    private func applyActivity() {
        guard motion.animatesBody, let machine = director?.machine else { return }
        #if DEBUG
        if debugSkipsActivity { return }
        #endif
        let monitor = AgentMonitor.shared
        let (working, idle) = monitor.sessions.activity(at: monitor.now, fallback: fallbackActivity)
        let needsYou = monitor.sessions.count(.needsYou, at: monitor.now) > 0
        guard machine.isWorking != working || machine.isAgentIdle != idle || machine.isNeedsYou != needsYou else { return }
        mutate {
            $0.setWorking(working, at: time())
            $0.setAgentIdle(idle, at: time())
            $0.setNeedsYou(needsYou, at: time())
        }
    }

    /// 依目前的快照與角色更新表情（讀到新資料、每分鐘、換角色時）
    func updateStatus() {
        let store = UsageStore.shared
        let provider = PanelSettings.shared.mascotCharacter.provider
        let level = NotchQuota.statusLevel(in: store.snapshot, provider: provider, now: store.now)
        let unavailable = MascotMood.isQuotaUnavailable(store.snapshot, provider: provider,
                                                        readFailed: store.errorMessage != nil, now: store.now)
        let quota = MascotMood.quota(level: level, unavailable: unavailable,
                                     incident: MascotMood.hasIncident(store.snapshot, provider: provider),
                                     runsOut: MascotMood.runsOut(store.snapshot, provider: provider, now: store.now))
        let monitor = AgentMonitor.shared
        let mood = MascotMood.agent(monitor.sessions.top(at: monitor.now)?.state(at: monitor.now, idleAfter: monitor.sessions.idleAfter),
                                    quota: quota)
        if director?.mood != mood { mutate { $0.setMood(mood) } }
        setStatus(level)
        // 換了服務、表情沒變時不會經過 refresh：循環的那一輪照新的配色重建（Codex C-01）
        updateEffectLoop()
        // 每分鐘也重算脈動：等你超過睡覺分鐘數會變成閒置（沒有計時器，靠這裡停）
        updatePulse()
    }

    /// 額度狀態（0 正常、1 偏高、2 用完或出錯）：靜音、勿擾時只換表情，不播提醒也不鼓一下
    func setStatus(_ level: Int) {
        guard director?.machine.statusLevel != level else { return }
        let quiet = PanelSettings.shared.isMascotQuiet(at: Date())
        mutate { $0.setStatus(level, at: time(), react: !quiet) }
    }

    // MARK: - 右鍵選單

    /// 選單「動作」：照按鈕的規則排隊播
    func play(_ request: MascotRequest) {
        mutate { $0.request(request, at: time()) }
    }

    /// 選單「表情」：正面看著你、顯示那個表情一下
    func playFace(_ mood: MascotMood) {
        mutate { $0.requestFace(mood, at: time()) }
    }

    /// 選單開著時滑鼠移到選單上不算離開；關掉後滑鼠不在面板上就照常收合
    func menuWillOpen() {
        menuOpen = true
        closeTimer?.invalidate()
        closeTimer = nil
    }

    func menuDidClose() {
        menuOpen = false
        if !pinned, !NotchPanelController.shared.containsPointer() { pointerExited() }
    }

    /// 靜音 1 小時／勿擾到明天早上 8 點／取消
    func setQuiet(until date: Date?) {
        PanelSettings.shared.mascotQuietUntil = date
        // 開始靜音：已經排隊的提醒也不播（Codex C-03）
        if date != nil { mutate { $0.silence(at: time()) } }
    }

    // MARK: - 看滑鼠（整個螢幕）

    /// 用 `NSEvent.mouseLocation` 讀游標位置（不裝事件監聽、不需要權限）：游標有動時每秒約 12 次，
    /// 沒動 1 秒後降到每秒 4 次；視線變化小於門檻不重畫，畫面的重畫在視線轉到位後停止（ADR-0016 第 6 節）
    private func restartGaze() {
        gazeTimer?.invalidate()
        gazeTimer = nil
        lastPointer = nil
        pointerStillTicks = 0
        gazeDozing = false
        guard PanelSettings.shared.mascotFollowPointer, motion.movesEyes, director != nil,
              NotchPanelController.shared.isShown else {
            if var director, director.look(at: time(), dx: 0, dy: 0, threshold: 0.001) {
                self.director = director
                refresh()
            }
            return
        }
        scheduleGaze(interval: 1.0 / 12)
    }

    private func scheduleGaze(interval: Double) {
        gazeTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { MascotController.shared.pollPointer() }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        gazeTimer = timer
    }

    func followPointerChanged() {
        restartGaze()
    }

    /// 視線的門檻（弧度）：游標小小移動不重畫
    static let gazeThreshold = 0.02

    #if DEBUG
    /// 量測用：以假的游標位置驅動同一段程式（不移動真的游標）
    @ObservationIgnored var debugPointer: (() -> CGPoint)?
    /// 量測用：不看紀錄檔（工作中與睡覺由時間表直接設定）
    @ObservationIgnored var debugSkipsActivity = false
    #endif

    private func pollPointer() {
        // 睡著（臉不跟著轉）時不必看游標：降到每秒 1 次，醒來後恢復
        if let director, director.pose(at: time())[.follow] <= 0.01 {
            if !gazeDozing {
                gazeDozing = true
                scheduleGaze(interval: 1)
            }
            return
        }
        if gazeDozing {
            gazeDozing = false
            pointerStillTicks = 0
            scheduleGaze(interval: 1.0 / 12)
        }
        var pointer = NSEvent.mouseLocation
        #if DEBUG
        if let debugPointer { pointer = debugPointer() }
        #endif
        guard var director, let origin = NotchPanelController.shared.canvasOrigin() else { return }
        let t = time()
        let pose = director.pose(at: t)
        // 畫布座標：左上為原點、y 往下；螢幕座標：左下為原點、y 往上。
        // 比較的是「游標相對角色」的位置：游標沒動但角色移動（展開、收合、換螢幕）時也會重新對準（Codex 第二輪 C-02）
        let dx = pointer.x - (origin.x + pose[.x])
        let dy = (origin.y - pointer.y) - pose[.y]
        let relative = CGPoint(x: dx, y: dy)
        guard relative != lastPointer else {
            pointerStillTicks += 1
            // 游標與角色都停住 1 秒：降到每秒 4 次
            if pointerStillTicks == 12 { scheduleGaze(interval: 0.25) }
            return
        }
        if pointerStillTicks >= 12 { scheduleGaze(interval: 1.0 / 12) }
        pointerStillTicks = 0
        lastPointer = relative
        if director.look(at: t, dx: dx, dy: dy, threshold: Self.gazeThreshold) {
            self.director = director
            refresh()
        }
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
        // 展開待著：眨眼、視線追滑鼠、工作中以每秒 30 次、睡著以 10 次重畫；畫面靜止時停止，到下一次眨眼再開始。
        // 動畫關閉時展開待著也不重畫（沒有眨眼、看滑鼠）
        let live = director.isLive && motion.movesEyes
        let idleMoving = motion.movesEyes && director.isIdleMoving(at: now)
        let breathing = live && director.mode == .sleep && !director.isStill && director.blink(at: now) == 0
        // 只有視線在轉（沒在眨眼、工作、睡覺）：低頻率
        let gazeOnly = idleMoving && !breathing && director.blink(at: now) == 0
            && !(live && !director.isStill && director.mode == .work)
        // 外觀的特效（ADR-0021，ADR-0010 的例外）：展開時、或收合時 AI 工作中才動，每秒最多 12 次；
        // 收合閒置、睡著時停在靜態的一格
        // 收合動畫播完才停（Fable F-08）
        let effects = motion.animatesEffects && look?.style.animates == true
            && (director.machine.isOpen || animating || (director.mode == .work && !director.isStill))
        if effects != effectsLive {
            if effects { effectStart = now } else { effectBase += max(now - effectStart, 0) }
            effectsLive = effects
        }
        var rate: MascotRenderRate = animating ? .animating
            : !idleMoving ? .stopped : breathing ? .breathing : gazeOnly ? .gaze : .idle
        // 只取代「完全停止」：睡著的呼吸、看滑鼠照原本的頻率，特效跟著那個頻率動（Fable F-01）。
        // 收合時 AI 工作中或睡著：所有外觀都有動態（敲鍵盤、呼吸），由 Core Animation 循環播放（ADR-0021 收合時的動態）
        let collapsedMotion = motion.animatesEffects && !director.machine.isOpen && !animating && !director.isStill
            && (director.mode == .work || director.mode == .sleep)
        if effects || collapsedMotion, rate == .stopped { rate = .effect }
        if rate != renderRate {
            if rate != .animating { stoppedAt = now }
            renderRate = rate
        }
        updateEffectLoop()
        // 收合動畫播完才把視窗縮回瀏海大小（展開時是整張畫布）
        let expanded = director.machine.isOpen || animating
        if expanded != windowExpanded {
            windowExpanded = expanded
            NotchPanelController.shared.setExpanded(expanded)
            // 收合動畫播完：動畫程度在展開中改過的話，現在重建
            if !expanded, motion != builtMotion || layout != builtLayout {
                rebuild()
                return
            }
        }
        if live, rate == .stopped || rate == .effect {
            // 靜止待著：下一次眨眼時再開始重畫。特效由角色自己的 TimelineView 驅動，不用輪詢（Fable F-05）；
            // 收合時 AI 工作狀態改變由 nextDeadline／mutate 叫醒，視線由 pollPointer
            rateTimer = oneShot(after: director.nextBlink(after: now) - now) { $0.refresh() }
        } else if rate != .stopped, rate != .effect {
            // 動畫或待著的動作還在：之後再看一次（最多 0.25 秒後）
            rateTimer = oneShot(after: 250) { $0.refresh() }
        }
    }

    /// 收合時循環播放的那一輪依這些畫：任何一個改了就重建（相位照時鐘接著走）（Codex C-01）
    private struct EffectLoopKey: Equatable {
        var mode: MascotMode
        var mood: MascotMood
        var statusLevel: Int
        var character: MascotCharacter
        var look: String?
        var layout: NotchLayout
        var motion: MascotMotionLevel
    }

    private func updateEffectLoop() {
        guard let director else { return }
        let key = renderRate == .effect && !director.machine.isOpen
            ? EffectLoopKey(mode: director.mode, mood: director.mood, statusLevel: director.machine.statusLevel,
                            character: PanelSettings.shared.mascotCharacter, look: look?.id, layout: layout, motion: motion)
            : nil
        guard key != effectLoopKey else { return }
        effectLoopKey = key
        NotchPanelController.shared.effectLoopChanged()
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
