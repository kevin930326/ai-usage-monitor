import Foundation

/// 把狀態機的事件串接成畫面（ADR-0016 第 1 節）：每個事件換一段腳本，起點是上一段在那一刻的姿勢；
/// 任一時間點的畫面都可以由 `frame(at:)` 直接算出（純函式），App 只需要在有事件時呼叫對應的方法。
public struct MascotDirector: Sendable {
    public let config: MascotConfig
    public let scripts: MascotScripts
    /// 粒子與眨眼的種子
    public let seed: UInt64

    public private(set) var machine: MascotMachine
    public private(set) var script: MascotScript
    public private(set) var effects: [MascotEffect] = []
    public private(set) var spring = MascotSpring.resting(at: 0)
    public private(set) var bumpStart: Int?
    public private(set) var ripple: MascotRipple?
    /// 內容（額度卡）開始浮現的時間；收著或過場中為 nil
    public private(set) var contentShownAt: Int?
    public private(set) var contentHiddenAt: Int?
    public private(set) var isIntro = false
    /// 角色身體靜止（動畫程度「簡單」「關閉」）：不播反應、提醒、工作與睡覺的動作，只換狀態點的顏色
    public private(set) var isStill = false
    /// 目前的腳本是快速展開（展開途中換模式時重排用）
    private var quickOpening = false
    /// 畫面看到的模式（依事件更新；`machine.mode` 是處理到目前時間的結果）
    public private(set) var mode = MascotMode.none
    private var statusFrom = 0.0
    private var statusTo = 0.0
    private var statusStart = 0
    private var gazeFrom = (yaw: 0.0, pitch: 0.0)
    private var gazeTarget = (yaw: 0.0, pitch: 0.0)
    private var gazeStart = 0

    /// `statusLevel`：啟動時已知的額度狀態（不鼓一下、不播提醒）
    public init(config: MascotConfig, seed: UInt64 = 0x5EED, startTime: Int = 0, statusLevel: Int = 0) {
        self.config = config
        scripts = MascotScripts(config: config)
        self.seed = seed
        machine = MascotMachine(timing: config.timing, startTime: startTime, statusLevel: statusLevel)
        statusFrom = Double(statusLevel)
        statusTo = Double(statusLevel)
        statusStart = startTime - 1000
        script = MascotScript(start: startTime, base: scripts.collapsedPose)
    }

    // MARK: - 事件（時間一律是毫秒、單調遞增）

    public mutating func open(at time: Int, intro: Bool) { apply { $0.open(at: time, intro: intro) } }
    public mutating func close(at time: Int) { apply { $0.close(at: time) } }
    public mutating func advance(to time: Int) { apply { $0.advance(to: time) } }
    public mutating func request(_ request: MascotRequest, at time: Int) { apply { $0.request(request, at: time) } }
    public mutating func gesture(_ gesture: MascotGesture, at time: Int) { apply { $0.gesture(gesture, at: time) } }
    public mutating func click(at time: Int, choice: MascotRequest) { apply { $0.click(at: time, choice: choice) } }
    public mutating func press(at time: Int) { apply { $0.press(at: time) } }
    public mutating func release(at time: Int) { apply { $0.release(at: time) } }
    public mutating func setWorking(_ working: Bool, at time: Int) { apply { $0.setWorking(working, at: time) } }
    public mutating func setStatus(_ level: Int, at time: Int) { apply { $0.setStatus(level, at: time) } }

    /// 滑鼠在面板裡移動：叫醒、並讓臉朝滑鼠轉（`dx`、`dy` 是滑鼠相對角色中心的距離，px）
    public mutating func move(at time: Int, dx: Double, dy: Double) {
        apply { $0.move(at: time) }
        let f = config.hero.follow
        let current = gaze(at: time)
        gazeFrom = current
        gazeTarget = (min(max(dx / f.yawSpanPx, -1), 1) * f.yawMax, min(max(-dy / f.pitchSpanPx, -1), 1) * f.pitchMax)
        gazeStart = time
    }

    /// 下一個需要叫 `advance` 的時間（動畫結束、排隊開始、按住成立、過場結束、睡著）；沒有為 nil
    public var nextDeadline: Int? { machine.nextDeadline }

    private mutating func apply(_ body: (inout MascotMachine) -> Void) {
        body(&machine)
        for entry in machine.log { handle(entry) }
        // 紀錄只用來接畫面；處理完就清掉，長時間執行也不會變長
        machine.trimLog()
    }

    private mutating func handle(_ entry: MascotLogEntry) {
        let t = entry.time
        let pose = script.pose(at: t)
        // 快速展開之後換了別的腳本，就不再是「滑到卡片途中」
        switch entry.event {
        case .start, .release, .pose, .bump, .introEnd: quickOpening = false
        default: break
        }
        if isStill {
            switch entry.event {
            case .start, .release, .pose, .bump, .introEnd, .mode(.sleep):
                // 靜止時不換腳本；模式照記，姿勢維持平常的樣子
                if case .mode(let newMode) = entry.event { mode = newMode }
                return
            case .mode(let newMode):
                mode = newMode
                return
            default: break
            }
        }
        switch entry.event {
        case .open(let intro):
            spring = spring.retarget(1, at: t, stiffness: config.panel.openSpring.stiffness,
                                     dampingRatio: config.panel.openSpring.dampingRatio)
            contentHiddenAt = nil
            if intro {
                isIntro = true
                use(scripts.intro(start: t))
                ripple = MascotRipple(config: config.ripple, introStart: t, ringsAt: config.intro.ringsAt,
                                      confettiAt: config.intro.confettiAt, seed: seed &+ UInt64(truncatingIfNeeded: t))
                contentShownAt = t + config.intro.contentAt
            } else {
                use(scripts.quickOpen(start: t, from: pose, mode: isStill ? .none : mode))
                quickOpening = true
                contentShownAt = t + 220
            }
        case .close:
            quickOpening = false
            // 內容先在 .12 秒內淡出，面板才收回
            let at = t + config.panel.contentFadeOutMs
            spring = spring.retarget(0, at: at, stiffness: config.panel.closeSpring.stiffness,
                                     dampingRatio: config.panel.closeSpring.dampingRatio)
            isIntro = false
            ripple = nil
            effects = []
            contentShownAt = nil
            contentHiddenAt = t
            use(scripts.close(start: t, from: pose))
        case .introEnd:
            isIntro = false
            if mode == .work { use(scripts.rest(start: t, from: pose, mode: .work)) }
        case .start(let animation):
            use(scripts.animation(animation, start: t, from: pose, level: machine.statusLevel))
        case .release:
            use(scripts.squeezeRelease(start: t, from: pose))
        case .pose(let poseMode):
            use(scripts.rest(start: t, from: pose, mode: poseMode))
        case .mode(let newMode):
            mode = newMode
            // 動畫播放中：不打斷，播完時的 pose 事件會接到新模式的姿勢（ADR-0016 第 2 節的動畫鎖）
            guard machine.isOpen, !isIntro, machine.playing == nil else { break }
            if quickOpening, script.settledAt > t {
                // 還在滑到角色卡：從現在的姿勢重新滑過去，終點換成新模式的姿勢（位置與大小照樣到卡片）
                use(scripts.quickOpen(start: t, from: pose, mode: newMode))
            } else {
                use(scripts.rest(start: t, from: pose, mode: newMode))
            }
        case .status(let level):
            statusFrom = statusColor(at: t)
            statusTo = Double(level)
            statusStart = t
        case .bump:
            bumpStart = t
            use(scripts.collapsedAlert(start: t, from: pose, level: machine.statusLevel))
        case .interrupt, .end, .queue, .drop, .ignore:
            break
        }
    }

    /// 改成靜止或恢復（動畫程度改變時）：改成靜止時，正在播的反應與特效立刻停，回到平常的姿勢
    public mutating func setStill(_ still: Bool, at time: Int) {
        guard still != isStill else { return }
        isStill = still
        if still {
            effects = []
            ripple = nil
        }
        guard machine.isOpen else { return }
        let pose = script.pose(at: time)
        if still, isIntro {
            // 過場途中改成靜止：直接收尾，角色滑到卡片、內容出現（Codex 第二輪 C-01）
            isIntro = false
            if contentShownAt.map({ $0 > time }) ?? true { contentShownAt = time }
        }
        // 從現在的姿勢滑到卡片：靜止時是平常的姿勢；恢復時接回狀態機目前的模式（工作、睡覺；第二輪 C-01、C-02）
        use(scripts.settle(start: time, from: pose, mode: still ? .none : machine.mode))
        quickOpening = true
    }

    private mutating func use(_ next: MascotScript) {
        script = next
        effects.removeAll { $0.start + $0.duration <= next.start }
        effects += next.effects
    }

    // MARK: - 畫面（純函式）

    public func pose(at time: Int) -> MascotPose { script.pose(at: time) }
    public func eyes(at time: Int) -> MascotEyes { script.eyes(at: time) }

    /// 狀態點顏色（0 正常 → 1 偏高 → 2 用完），換色 .4 秒
    public func statusColor(at time: Int) -> Double {
        statusFrom + (statusTo - statusFrom) * MascotEase.inOut(Double(time - statusStart) / 400)
    }

    /// 看滑鼠：指數平滑（demo 每格乘 .12，換成與影格率無關的時間常數）
    public func gaze(at time: Int) -> (yaw: Double, pitch: Double) {
        let perFrame = config.hero.follow.smoothingPerFrame
        let tau = -1 / (60 * log(1 - perFrame))   // 秒
        let k = exp(-Double(max(time - gazeStart, 0)) / 1000 / tau)
        return (gazeTarget.yaw + (gazeFrom.yaw - gazeTarget.yaw) * k, gazeTarget.pitch + (gazeFrom.pitch - gazeTarget.pitch) * k)
    }

    /// 眨眼：每 3.3～4.8 秒一次，只在平常狀態（沒有動畫、不是過場、沒睡覺、眼睛是膠囊）
    public func blink(at time: Int) -> Double {
        guard machine.isOpen, !isIntro, isStill || (machine.playing == nil && mode != .sleep), eyes(at: time) == .pill,
              pose(at: time)[.dash] < 0.1 else { return 0 }
        let b = config.hero.blink
        let period = (b.minGapMs + b.maxGapMs) / 2
        let bucket = Int((Double(time) / Double(period)).rounded(.down))
        for index in [bucket - 1, bucket] {
            let local = time - blinkStart(index)
            guard local >= 0, local < b.closeMs + b.holdMs + b.openMs else { continue }
            if local < b.closeMs { return MascotEase.inCubic(Double(local) / Double(b.closeMs)) }
            if local < b.closeMs + b.holdMs { return 1 }
            return 1 - MascotEase.out(Double(local - b.closeMs - b.holdMs) / Double(b.openMs))
        }
        return 0
    }

    /// 第 `index` 次眨眼的開始時間（每段 `period` 裡依種子偏移）
    private func blinkStart(_ index: Int) -> Int {
        let b = config.hero.blink
        let period = (b.minGapMs + b.maxGapMs) / 2
        let jitter = Double(b.maxGapMs - b.minGapMs) / 2
        return index * period + Int((MascotRandom.unit(seed: seed, index: UInt64(bitPattern: Int64(index))) - 0.5) * jitter)
    }

    /// `time` 之後下一次眨眼開始的時間（展開待著、畫面不動時，排這個時間再開始重畫）
    public func nextBlink(after time: Int) -> Int {
        let b = config.hero.blink
        let period = (b.minGapMs + b.maxGapMs) / 2
        let bucket = Int((Double(time) / Double(period)).rounded(.down))
        return (bucket - 1...bucket + 2).map(blinkStart).filter { $0 > time }.min() ?? time + period
    }

    /// 展開待著時這一刻畫面會不會變：眨眼中、視線還在追滑鼠、睡覺（呼吸）或工作中（敲鍵盤）。
    /// 都沒有時畫面靜止，可以停止重畫到下一次眨眼（ADR-0016 第 6 節）。
    public func isIdleMoving(at time: Int) -> Bool {
        guard machine.isOpen else { return false }
        if !isStill, mode == .sleep || mode == .work { return true }
        if blink(at: time) > 0 { return true }
        let now = gaze(at: time)
        return abs(now.yaw - gazeTarget.yaw) > 0.002 || abs(now.pitch - gazeTarget.pitch) > 0.002
    }

    public func panelShape(at time: Int) -> MascotPanelShape {
        MascotPanelShape(progress: spring.state(at: time).position, bump: MascotBump.value(at: time, start: bumpStart, panel: config.panel),
                         panel: config.panel)
    }

    /// 額度卡的透明度與上移（浮現 .35 秒、上移 .45 秒；收合時 .12 秒淡出）
    public func content(at time: Int) -> (opacity: Double, offset: Double) {
        let p = config.panel
        if let hidden = contentHiddenAt {
            let u = Double(time - hidden) / Double(p.contentFadeOutMs)
            return (max(0, 1 - u), -p.contentRisePx * min(max(u, 0), 1))
        }
        guard let shown = contentShownAt, time >= shown else { return (0, -p.contentRisePx) }
        let fade = min(Double(time - shown) / Double(p.contentFadeInMs), 1)
        let rise = MascotEase.out(Double(time - shown) / Double(p.contentRiseMs))
        return (fade, -p.contentRisePx * (1 - rise))
    }

    /// 這一刻是否還有東西在動（決定每秒 60 次、30 次或停止重畫）
    public func isAnimating(at time: Int) -> Bool {
        if !spring.isSettled(at: time) { return true }
        if script.settledAt > time { return true }
        if let ripple, time < ripple.endTime { return true }
        if MascotBump.isActive(at: time, start: bumpStart, panel: config.panel) { return true }
        if effects.contains(where: { time < $0.start + $0.duration }) { return true }
        if time < statusStart + 400 { return true }
        if let shown = contentShownAt, time < shown + config.panel.contentRiseMs { return true }
        if let hidden = contentHiddenAt, time < hidden + config.panel.contentFadeOutMs { return true }
        return !isStill && machine.playing != nil
    }

    /// 畫面需要持續重畫（眨眼、看滑鼠、晃動、呼吸）：面板展開時
    public var isLive: Bool { machine.isOpen }
}
