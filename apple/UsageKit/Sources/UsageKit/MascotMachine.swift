import Foundation

// 角色（mascot）的動畫鎖與排隊（ADR-0016、MASCOT-SPEC 第 6 節）。純邏輯、不碰時鐘：時間由呼叫端以毫秒傳入，
// 同一串事件一定排出同樣的播放順序。Windows 的 UsageCore/MascotMachine.cs 是同一份規則，兩邊以
// fixtures/mascot 的 golden 比對；改規則時兩邊一起改。

/// 動畫（一次只播一個）
public enum MascotAnimation: String, Sendable, CaseIterable {
    case hop, wave, dizzy, shy, scared, squeeze, wake, alert
}

/// 按鈕或狀態觸發的動畫：播放中就排隊，只保留最後一個
public enum MascotRequest: String, Sendable, CaseIterable {
    case hop, wave, dizzy, shy, scared, sleep, alert
}

/// 手勢：播放中直接忽略
public enum MascotGesture: String, Sendable, CaseIterable {
    /// 繞圈兩圈 → 轉暈
    case circle
    /// 快速左右甩動 → 嚇到
    case shake
    /// 停在角色身上 → 害羞
    case hover

    var request: MascotRequest {
        switch self {
        case .circle: .dizzy
        case .shake: .scared
        case .hover: .shy
        }
    }
}

/// 模式和動畫是兩回事：動畫播完回到目前模式的姿勢
public enum MascotMode: String, Sendable {
    case none, sleep, work
}

/// 動畫的類型：短反應可以被連點 5 下打斷，長動畫中的點擊不計次
public enum MascotAnimationKind: String, Sendable {
    case tap, long, hold
}

/// 狀態機用到的時間（`shared/mascot-anim.json` 的 `machine`）
public struct MascotTiming: Decodable, Sendable, Equatable {
    public var restBeforeQueuedMs: Int
    public var clickWindowMs: Int
    public var clicksForDizzy: Int
    public var holdMs: Int
    public var sleepAfterIdleMs: Int
    public var introInteractiveMs: Int
    public var durationsMs: [String: Int]

    enum CodingKeys: String, CodingKey {
        case restBeforeQueuedMs = "rest_before_queued_ms"
        case clickWindowMs = "click_window_ms"
        case clicksForDizzy = "clicks_for_dizzy"
        case holdMs = "hold_ms"
        case sleepAfterIdleMs = "sleep_after_idle_ms"
        case introInteractiveMs = "intro_interactive_ms"
        case durationsMs = "durations_ms"
    }

    private struct File: Decodable { var machine: MascotTiming }

    /// 讀整份 `mascot-anim.json`，取出 `machine`
    public static func decode(fromConfig data: Data) throws -> MascotTiming {
        try JSONDecoder().decode(File.self, from: data).machine
    }

    /// 動畫長度；捏扁是放開後的長度
    public func duration(of animation: MascotAnimation) -> Int {
        let key = animation == .squeeze ? "squeeze_release" : animation.rawValue
        return durationsMs[key] ?? 1000
    }
}

/// 播放中的動畫
public struct MascotPlaying: Sendable, Equatable {
    public var animation: MascotAnimation
    public var kind: MascotAnimationKind
    public var start: Int
    /// 結束時間；按住捏扁時還不知道（放開後才有）
    public var end: Int?
}

/// 事件紀錄的一行：golden 比對與除錯用
/// 狀態機的事件（畫面依它換腳本；golden 比對它的文字）
public enum MascotEvent: Sendable, Equatable, CustomStringConvertible {
    case open(intro: Bool)
    case close
    case introEnd
    case start(MascotAnimation)
    case end(MascotAnimation)
    case interrupt(MascotAnimation)
    case release
    case pose(MascotMode)
    case mode(MascotMode)
    case queue(MascotRequest)
    case drop(MascotRequest)
    case ignore(String)
    case status(Int)
    case bump

    public var description: String {
        switch self {
        case .open(let intro): intro ? "open intro" : "open quick"
        case .close: "close"
        case .introEnd: "intro-end"
        case .start(let a): "start \(a.rawValue)"
        case .end(let a): "end \(a.rawValue)"
        case .interrupt(let a): "interrupt \(a.rawValue)"
        case .release: "release squeeze"
        case .pose(let m): "pose \(m.rawValue)"
        case .mode(let m): "mode \(m.rawValue)"
        case .queue(let r): "queue \(r.rawValue)"
        case .drop(let r): "drop \(r.rawValue)"
        case .ignore(let name): "ignore \(name)"
        case .status(let level): "status \(level)"
        case .bump: "bump"
        }
    }
}

/// 事件紀錄的一行：golden 比對與畫面換腳本用
public struct MascotLogEntry: Sendable, Equatable, CustomStringConvertible {
    public var time: Int
    public var event: MascotEvent
    public var description: String { "\(time) \(event)" }
}

public struct MascotMachine: Sendable {
    public let timing: MascotTiming

    /// 狀態機的目前時間（已處理到的最後一刻；只會往前）
    public private(set) var now = 0
    public private(set) var isOpen = false
    /// 過場結束（開始接受互動）的時間；不在過場中為 nil
    public private(set) var introUntil: Int?
    public private(set) var mode = MascotMode.none
    public private(set) var playing: MascotPlaying?
    /// 播完、回到原本姿勢後才播排隊的；這段期間仍算忙碌
    public private(set) var restUntil: Int?
    /// 回位等待中、已經從隊伍取出、接著要播的（demo 的 finish：播完那一刻就取出）
    public private(set) var pending: MascotRequest?
    /// 排隊中的（只留最後一個）
    public private(set) var queued: MascotRequest?
    public private(set) var isHolding = false
    public private(set) var statusLevel: Int
    /// 最近一次動畫結束、回到模式姿勢的時間（畫面用來做 .32 秒的回位）
    public private(set) var restedAt: Int?
    public private(set) var log: [MascotLogEntry] = []

    private var holdArmAt: Int?
    private var justReleased = false
    private var clicks: [Int] = []
    private var lastActivity = 0

    /// `statusLevel` 是啟動時已知的額度狀態（不會因此鼓一下或播提醒）
    public init(timing: MascotTiming, startTime: Int = 0, statusLevel: Int = 0) {
        self.timing = timing
        now = startTime
        lastActivity = startTime
        self.statusLevel = statusLevel
    }

    public var isIntro: Bool { introUntil != nil }
    public var isBusy: Bool { playing != nil || restUntil != nil }

    /// 目前動畫的類型；回位等待中是 nil（不是短反應）
    private var busyKind: MascotAnimationKind? { playing?.kind }
    private var isBusyWithLong: Bool { isBusy && busyKind != .tap }

    /// 下一個到期的時間（App 依它排一次計時器呼叫 `advance`，不輪詢）
    public var nextDeadline: Int? { nextDue(before: .max)?.0 }

    /// 只保留最後幾行紀錄（App 長時間執行時用；golden 不需要）
    public mutating func trimLog(keeping count: Int = 0) {
        log.removeFirst(max(log.count - count, 0))
    }

    // MARK: - 時間

    /// 處理到 `time` 之前到期的所有事（動畫結束、排隊開始、按住成立、過場結束、睡著）；時間不會倒退
    public mutating func advance(to time: Int) {
        while let (at, step) = nextDue(before: time) {
            now = max(now, at)
            switch step {
            case .end: endPlaying()
            case .queued: startPending()
            case .hold: armHold()
            case .intro: finishIntro()
            case .sleep: enterSleep()
            }
        }
        now = max(now, time)
    }

    /// 每個事件的入口：先處理到期的事，事件時間比狀態機的時間早（不同時鐘的小誤差）時以目前時間為準
    private mutating func begin(_ time: Int) -> Int {
        advance(to: time)
        return now
    }

    private enum Step: Int { case end, queued, hold, intro, sleep }

    private func nextDue(before time: Int) -> (Int, Step)? {
        var best: (Int, Step)?
        func consider(_ at: Int?, _ step: Step) {
            guard let at, at <= time else { return }
            if best == nil || at < best!.0 || (at == best!.0 && step.rawValue < best!.1.rawValue) { best = (at, step) }
        }
        consider(playing?.end, .end)
        consider(restUntil, .queued)
        consider(holdArmAt, .hold)
        consider(introUntil, .intro)
        consider(sleepDeadline, .sleep)
        return best
    }

    /// 10 秒沒有操作（移動、點擊、按住、放開）就睡著：只在面板展開、沒有動畫、沒有排隊、平常模式時
    private var sleepDeadline: Int? {
        guard isOpen, !isIntro, !isBusy, !isHolding, holdArmAt == nil, mode == .none, queued == nil else { return nil }
        return max(lastActivity + timing.sleepAfterIdleMs, now)
    }

    // MARK: - 事件

    public mutating func open(at time: Int, intro: Bool) {
        let time = begin(time)
        guard !isOpen else { return }
        isOpen = true
        clicks = []
        lastActivity = time
        if intro { introUntil = time + timing.introInteractiveMs }
        record(.open(intro: intro))
    }

    public mutating func close(at time: Int) {
        _ = begin(time)
        guard isOpen else { return }
        isOpen = false
        if let playing { record(.interrupt(playing.animation)) }
        playing = nil
        restUntil = nil
        introUntil = nil
        dropPending()
        dropQueued()
        isHolding = false
        holdArmAt = nil
        justReleased = false
        clicks = []
        if mode == .sleep { setMode(.none) }
        record(.close)
    }

    /// 按鈕或狀態觸發：忙碌（過場、播放中、回位中、按住）就排隊，只留最後一個；面板收著時丟掉
    public mutating func request(_ request: MascotRequest, at time: Int) {
        _ = begin(time)
        guard isOpen else {
            record(.drop(request))
            return
        }
        // 工作中不會睡著
        if request == .sleep, mode == .work {
            record(.ignore(request.rawValue))
            return
        }
        if isIntro || isBusy || isHolding {
            dropQueued()
            queued = request
            record(.queue(request))
        } else {
            run(request)
        }
    }

    /// 手勢：忙碌時直接忽略，不排隊
    public mutating func gesture(_ gesture: MascotGesture, at time: Int) {
        _ = begin(time)
        guard isOpen, !isIntro, !isBusy, !isHolding, mode != .sleep else {
            record(.ignore(gesture.rawValue))
            return
        }
        run(gesture.request)
    }

    /// 點角色：`choice` 是這次的隨機反應（呼叫端決定，golden 才能重現）
    public mutating func click(at time: Int, choice: MascotRequest) {
        let time = begin(time)
        guard isOpen, !isIntro else { return }
        lastActivity = time
        if justReleased {
            justReleased = false
            return
        }
        // 睡覺時點一下：先叫醒
        if mode == .sleep {
            wake()
            return
        }
        // 長動畫（含按住、回位中）裡的點擊不計次
        if isBusyWithLong {
            clicks = []
            return
        }
        clicks.removeAll { time - $0 > timing.clickWindowMs }
        clicks.append(time)
        if clicks.count >= timing.clicksForDizzy {
            // 唯一能插隊的例外：短反應中連點 5 下直接轉暈
            clicks = []
            dropQueued()
            run(.dizzy)
            return
        }
        if isBusy { return }
        run(choice)
    }

    public mutating func press(at time: Int) {
        let time = begin(time)
        guard isOpen, !isIntro, !isBusyWithLong else { return }
        lastActivity = time
        justReleased = false
        holdArmAt = time + timing.holdMs
    }

    public mutating func release(at time: Int) {
        let time = begin(time)
        lastActivity = time
        holdArmAt = nil
        guard isHolding else { return }
        isHolding = false
        justReleased = true
        if playing?.kind == .hold {
            playing?.end = time + timing.duration(of: .squeeze)
            record(.release)
        }
    }

    /// 滑鼠在面板裡移動：睡覺時叫醒（按住中不算）
    public mutating func move(at time: Int) {
        let time = begin(time)
        lastActivity = time
        guard mode == .sleep, isOpen, !isIntro, !isHolding else { return }
        wake()
    }

    /// 工作中：狀態立即生效（姿勢在沒有動畫時馬上換）
    public mutating func setWorking(_ working: Bool, at time: Int) {
        _ = begin(time)
        if working, mode != .work {
            setMode(.work)
        } else if !working, mode == .work {
            setMode(.none)
        }
    }

    /// 額度狀態（0 正常、1 偏高、2 用完或出錯）：狀態點立即換色，提醒動畫排隊；收著時改成瀏海鼓一下；
    /// 回到正常只換色，排隊中的提醒也丟掉
    public mutating func setStatus(_ level: Int, at time: Int) {
        let time = begin(time)
        guard level != statusLevel else { return }
        statusLevel = level
        record(.status(level))
        guard level > 0 else {
            if queued == .alert { dropQueued() }
            if pending == .alert { dropPending() }
            return
        }
        if isOpen {
            request(.alert, at: time)
        } else {
            record(.bump)
        }
    }

    // MARK: - 內部

    private mutating func run(_ request: MascotRequest) {
        if mode == .sleep, request != .sleep { setMode(.none) }
        restUntil = nil
        switch request {
        case .sleep:
            if let playing { record(.interrupt(playing.animation)) }
            playing = nil
            enterSleep()
        case .hop: start(.hop, kind: .tap)
        case .wave: start(.wave, kind: .tap)
        case .dizzy: start(.dizzy, kind: .long)
        case .shy: start(.shy, kind: .long)
        case .scared: start(.scared, kind: .long)
        case .alert: start(.alert, kind: .long)
        }
    }

    private mutating func wake() {
        restUntil = nil
        dropPending()
        setMode(.none)
        start(.wake, kind: .long)
    }

    /// 每個動畫開始前先歸零（畫面依 `playing.start` 從中性姿勢開始），被取代的記為 interrupt
    private mutating func start(_ animation: MascotAnimation, kind: MascotAnimationKind) {
        if let playing { record(.interrupt(playing.animation)) }
        let end = kind == .hold ? nil : now + timing.duration(of: animation)
        playing = MascotPlaying(animation: animation, kind: kind, start: now, end: end)
        record(.start(animation))
    }

    /// 播完：回到模式姿勢；有排隊的就在這一刻取出，回位 360 ms 後播（回位期間再來的要求另外排隊）
    private mutating func endPlaying() {
        guard let finished = playing else { return }
        playing = nil
        record(.end(finished.animation))
        restedAt = now
        record(.pose(mode))
        if let next = queued {
            queued = nil
            pending = next
            restUntil = now + timing.restBeforeQueuedMs
        }
    }

    private mutating func startPending() {
        restUntil = nil
        guard let next = pending else { return }
        pending = nil
        run(next)
    }

    private mutating func armHold() {
        holdArmAt = nil
        guard isOpen, !isIntro, !isBusyWithLong else { return }
        isHolding = true
        restUntil = nil
        dropPending()
        // 睡覺時被捏：先回到平常
        if mode == .sleep { setMode(.none) }
        start(.squeeze, kind: .hold)
    }

    private mutating func finishIntro() {
        introUntil = nil
        record(.introEnd)
        if let next = queued {
            queued = nil
            run(next)
        }
    }

    private mutating func enterSleep() {
        guard isOpen, !isIntro else { return }
        restUntil = nil
        setMode(.sleep)
    }

    private mutating func dropQueued() {
        if let queued { record(.drop(queued)) }
        queued = nil
    }

    private mutating func dropPending() {
        if let pending { record(.drop(pending)) }
        pending = nil
    }

    private mutating func setMode(_ newMode: MascotMode) {
        guard mode != newMode else { return }
        mode = newMode
        record(.mode(newMode))
    }

    private mutating func record(_ event: MascotEvent) {
        log.append(MascotLogEntry(time: now, event: event))
    }
}
