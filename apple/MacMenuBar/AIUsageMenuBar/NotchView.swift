import AppKit
import SwiftUI
import UsageKit
import UsageKitUI

/// 瀏海面板的畫面（MASCOT-SPEC 第 3 節）：固定 580×190 的畫布，以 `NotchShape` 遮罩顯示目前的大小。
/// 收合時是瀏海大小：左邊迷你角色、右邊服務色的迷你圓環與百分比；展開時上緣放分頁與更新時間，
/// 下方左邊是角色卡、右邊是 Claude 與 Codex 的額度卡。
struct NotchView: View {
    @Environment(MascotController.self) private var controller
    @Environment(UsageStore.self) private var store
    @Environment(PanelSettings.self) private var settings
    @Environment(AgentMonitor.self) private var monitor

    /// 截圖用：固定的時間（毫秒）；nil 表示依時鐘
    var fixedTime: Int?

    var body: some View {
        if let director = controller.director {
            if let fixedTime {
                NotchCanvas(director: director, time: fixedTime, layout: controller.layout, snapshot: store.snapshot,
                            now: store.now, character: settings.mascotCharacter, extras: extras, look: controller.look)
            } else {
                // 面板形狀與額度卡只在動畫中（展開、收合、提醒）逐格重畫；展開待著與睡著時只有角色的 Canvas
                // 自己的 TimelineView 在跑，不必每格重建文字與卡片
                let rate = controller.renderRate
                TimelineView(.animation(minimumInterval: rate.interval, paused: rate != .animating)) { context in
                    NotchCanvas(director: director,
                                time: rate == .animating ? controller.time(context.date) : controller.stoppedAt,
                                layout: controller.layout,
                                snapshot: store.snapshot, now: store.now, character: settings.mascotCharacter,
                                extras: extras,
                                look: controller.look,
                                effectsLive: controller.effectsLive,
                                effectClock: { controller.effectTime(at: $0) },
                                motion: controller.motion,
                                heroRate: rate == .idle || rate == .breathing || rate == .gaze || rate == .effect ? rate : nil,
                                heroClock: { controller.time($0) })
                }
                .overlay { NotchPulse(active: controller.pulsing, shape: collapsedShape) }
            }
        }
    }
}

extension NotchView {
    private var extras: NotchExtras {
        // 時間用 store.now（每分鐘更新），列表的「多久」跟著更新；狀態變了 AgentMonitor 會讓畫面重畫
        let now = Int64(store.now.timeIntervalSince1970 * 1000)
        let sessions = monitor.sessions
        let rows = sessions.ordered(at: now).map { s in
            NotchAgentRow(id: "\(s.ai.rawValue)/\(s.id)", ai: s.ai, folder: s.folder,
                          state: s.state(at: now, idleAfter: sessions.idleAfter), need: s.need,
                          minutes: Int(max(0, now - s.since) / 60_000))
        }
        return NotchExtras(pinned: controller.pinned,
                           quietUntil: settings.mascotQuietUntil.flatMap { $0 > store.now ? $0 : nil },
                           hint: controller.showsHint,
                           page: rows.isEmpty && store.remoteAgents.isEmpty ? .overview : controller.page,
                           agents: rows, remote: store.remoteAgents,
                           remoteNeedsYou: controller.activity?.needsYou == true && !rows.contains { $0.state == .needsYou },
                           staticRemote: !controller.motion.animatesBody && controller.activity?.thinksRemotely == true,
                           level: MascotLevelStore.shared.level)
    }

    /// 收合時瀏海的大小（脈動畫在這個外框上）
    private var collapsedShape: NotchShape {
        let size = controller.director?.config.panel.collapsed
        return NotchShape(width: size?.width ?? controller.layout.collapsedWidth,
                          height: size?.height ?? controller.layout.collapsedHeight, corner: size?.corner ?? 10)
    }
}

/// 上緣與角色卡的小標示：保持展開（圖釘，點了取消）、靜音或勿擾到幾點、第一次展開的提示；
/// 以及 AI 的工作階段（需要你時外框變琥珀色、多個時顯示數量、展開時可以列出來）
struct NotchExtras: Equatable {
    var pinned = false
    var quietUntil: Date?
    var hint = false
    var page = NotchPage.overview
    var agents: [NotchAgentRow] = []
    /// 其他電腦的 AI 狀態（ADR-0019 第 2 節）：只在「AI 工作階段」分頁列出，不改變收合時的外框與數量
    var remote: [RemoteAgent] = []
    /// 其他電腦需要你（ADR-0019「角色合併所有電腦」）：外框也變琥珀色；收合時的數量只算這台
    var remoteNeedsYou = false
    /// 動畫「簡單」「關閉」時只有其他電腦在工作：狀態機不進 think，小電腦照合併後的狀態靜態顯示（Fable G-11）
    var staticRemote = false
    /// 角色等級（ADR-0020）；沒有任何活躍日時 nil
    var level: MascotLevel?

    var needsYou: Bool { remoteNeedsYou || agents.contains { $0.state == .needsYou } }
    /// 有東西可以列在「AI 工作階段」分頁
    var hasAgentPage: Bool { !agents.isEmpty || !remote.isEmpty }
    /// 收合時顯示的數量：閒置以外的工作階段，兩個以上才顯示
    var activeCount: Int { agents.filter { $0.state != .idle }.count }
}

/// 展開時右邊那張卡
enum NotchPage: Equatable {
    case overview, agents
}

/// 工作階段列表的一列。資料夾名稱只在記憶體與畫面上（ADR-0017 隱私）
struct NotchAgentRow: Equatable, Identifiable {
    var id: String
    var ai: AgentKind
    var folder: String
    var state: AgentState
    var need: AgentNeed?
    var minutes: Int
}

/// 需要你的琥珀色（同提醒光環「偏高」那組）
let notchAmber = Color(red: 245 / 255, green: 190 / 255, blue: 60 / 255)

/// 等你下一個指令時收合瀏海的脈動：沿著外框的一圈淡光，每 7 秒亮起再淡掉（1.6 秒）。
/// 整個循環交給 Core Animation（繪圖伺服器跑重複動畫）：App 不用計時器、不重畫，收著時平均 CPU 要在 0.3% 以下
struct NotchPulse: View {
    let active: Bool
    var shape = NotchShape(width: 0, height: 0, corner: 0)

    var body: some View {
        if active {
            PulseLayer(shape: shape)
                .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 脈動的亮度（`phase` 0…1）：sin² 亮起再淡掉，最亮 0.3
    static func opacity(phase: Double) -> Double {
        let k = phase < 0 || phase > 1 ? 0 : sin(phase * .pi)
        return 0.3 * k * k
    }

    /// 脈動的某一刻（`phase` 0…1；截圖也用這個）
    static func glow(_ shape: NotchShape, phase: Double) -> some View {
        shape.stroke(Color.white.opacity(opacity(phase: phase)), lineWidth: 3)
            .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
    }
}

/// 脈動的外框：CAShapeLayer 加一個無限重複的透明度關鍵影格動畫（7 秒一輪：前 1.6 秒亮起再淡掉，其餘不亮）。
/// 不再脈動時整個視圖拿掉，動畫跟著消失
private struct PulseLayer: NSViewRepresentable {
    let shape: NotchShape

    final class View: NSView {
        let line = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            line.fillColor = nil
            line.strokeColor = NSColor.white.cgColor
            line.lineWidth = 3
            line.opacity = 0
            layer?.addSublayer(line)
            let steps = 16
            let lit = Double(MascotController.pulseMs) / Double(MascotController.pulseEveryMs)
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = (0...steps).map { NotchPulse.opacity(phase: Double($0) / Double(steps)) } + [0]
            animation.keyTimes = ((0...steps).map { Double($0) / Double(steps) * lit } + [1]).map { NSNumber(value: $0) }
            animation.duration = Double(MascotController.pulseEveryMs) / 1000
            animation.calculationMode = .linear
            animation.repeatCount = .infinity
            line.add(animation, forKey: "pulse")
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        let bounds = CGRect(x: 0, y: 0, width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
        // 圖層座標的原點在左下：翻成瀏海形狀用的左上原點
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        let path = shape.path(in: bounds).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.line.frame = bounds
        view.line.path = view.layer?.isGeometryFlipped == true ? path : path.copy(using: &flip)
        CATransaction.commit()
    }
}

/// 瀏海的形狀：上緣貼齊螢幕頂端、下方兩角圓角
struct NotchShape: Shape {
    var width: Double
    var height: Double
    var corner: Double

    func path(in rect: CGRect) -> Path {
        let x0 = rect.midX - width / 2, x1 = rect.midX + width / 2
        let r = min(corner, height / 2, width / 2)
        var path = Path()
        path.move(to: CGPoint(x: x0, y: 0))
        path.addLine(to: CGPoint(x: x1, y: 0))
        path.addLine(to: CGPoint(x: x1, y: height - r))
        path.addQuadCurve(to: CGPoint(x: x1 - r, y: height), control: CGPoint(x: x1, y: height))
        path.addLine(to: CGPoint(x: x0 + r, y: height))
        path.addQuadCurve(to: CGPoint(x: x0, y: height - r), control: CGPoint(x: x0, y: height))
        path.closeSubpath()
        return path
    }
}

/// 只有外觀的特效在動時的角色（ADR-0021）：疊在瀏海畫布上、大小相同的另一個畫面，只有角色那一小塊每秒重畫 12 次
struct NotchEffectHero: View {
    @Environment(MascotController.self) private var controller
    @Environment(PanelSettings.self) private var settings

    var body: some View {
        // 收合時由 Core Animation 循環播放預先畫好的一輪（`MascotEffectLoop`），這裡只畫展開時（或沒建好一輪時）
        if controller.renderRate == .effect, let director = controller.director,
           director.machine.isOpen || !controller.effectLoopPlaying {
            NotchCanvas(director: director, time: controller.stoppedAt, layout: controller.layout, snapshot: nil, now: Date(),
                        character: settings.mascotCharacter, look: controller.look, effectsLive: controller.effectsLive,
                        effectClock: { controller.effectTime(at: $0) }, motion: controller.motion, heroRate: .effect,
                        heroClock: { controller.time($0) })
                .effectHero
                .accessibilityHidden(true)
        }
    }
}

/// 收合時的動態（ADR-0021）：角色停在收合的位置，只有小範圍在動，所以預先畫好一輪、交給 Core Animation 循環播放。
/// App 自己每一格都不用重畫（SwiftUI 每秒更新 12 次光是排版與送出就要約 3% CPU）。
/// - AI 工作中：會動的特效照特效動；其他外觀是敲鍵盤（低頭、小手上下、身體輕晃、淺灰鍵盤的按鍵輪流亮）。所有外觀的右上方都有思考泡泡：
///   三個小點約每 250 毫秒多亮一顆，三顆全亮後清空重來（一輪的長度要能整除，所以每一步是一輪的 1/4n，約 225～250 毫秒）。每秒 12 格
/// - 睡著：慢慢的呼吸（約 4.4 秒一次）加一個飄起的小 z；特效停在那一格。每秒 4 格
@MainActor
enum MascotEffectLoop {
    struct Loop {
        var images: [CGImage]
        /// 一輪的秒數
        var duration: Double
        /// 從一輪的哪裡開始（秒），接著目前的時鐘
        var offset: Double
        /// 在畫布上的範圍
        var box: CGRect
    }

    /// 敲鍵盤：手 sin(t/62)、身體晃 sin(t/310)，一輪 2π·310 毫秒剛好是敲 5 下
    static let typingMs = 2 * Double.pi * 310
    /// 呼吸 sin(t/700)
    static let breathMs = 2 * Double.pi * 700

    /// 一輪怎麼畫：長度、每秒幾格、目前時鐘（決定從哪裡開始）、範圍，以及畫第 t 毫秒的那一格
    struct Plan {
        var length: Double
        var fps: Double
        var clock: Int
        var box: CGRect
        var draw: (Int) -> AnyView
    }

    /// `canvas` 的 `time` 是角色停住的那一刻；`effectTime` 換算特效的時鐘（App 裡停住時停在最後一格）。截圖也用這份
    static func plan(_ canvas: NotchCanvas, now: Int, effectTime: @escaping (Int) -> Int?) -> Plan? {
        let director = canvas.director
        let base = director.pose(at: canvas.time)
        switch director.mode {
        case .work:
            if let look = canvas.look, let effect = MascotLookRenderer.loopDuration(look, radius: base[.r] * base[.sc]) {
                return Plan(length: effect, fps: 12, clock: effectTime(now) ?? 0, box: canvas.effectBox) {
                    AnyView(canvas.effectFrame(effectTime: $0, thinkingDots: MascotThinking.dots(at: $0, loop: effect)))
                }
            }
            // 手放在身體前下方，前面一條淺灰鍵盤（同展開時敲鍵盤的位置；2026-10-29 改淺灰後縮小也看得出是鍵盤）
            let w = director.config.poses.work
            let pose = base.with([.hands: 1, .type: 1, .kb: 1, .sway: 0.5, .lx: w.left[0], .ly: w.left[1], .lz: w.left[2],
                                  .rx: w.right[0], .ry: w.right[1], .rz: w.right[2]])
            return Plan(length: typingMs, fps: 12, clock: now, box: canvas.effectBox) {
                AnyView(canvas.effectFrame(effectTime: nil, pose: pose, time: $0, thinkingDots: MascotThinking.dots(at: $0, loop: typingMs)))
            }
        case .sleep:
            let pose = base.with([.breathe: 1])
            let frozen = effectTime(now)
            return Plan(length: breathMs, fps: 4, clock: now, box: canvas.effectBox) { t in
                AnyView(canvas.effectFrame(effectTime: frozen, pose: pose, time: t,
                                           dozeRise: Double(t).truncatingRemainder(dividingBy: breathMs) / breathMs))
            }
        case .think:
            // 背景執行中（ADR-0017 第 7 節）：平常的姿勢慢慢呼吸，思考泡泡以一半的速度亮；特效停在那一格。每秒 8 格
            let pose = base.with([.breathe: 1])
            let frozen = effectTime(now)
            return Plan(length: breathMs, fps: 8, clock: now, box: canvas.effectBox) { t in
                AnyView(canvas.effectFrame(effectTime: frozen, pose: pose, time: t,
                                           thinkingDots: MascotThinking.dots(at: t, loop: breathMs, target: MascotThinking.slowStepMs)))
            }
        default:
            return nil
        }
    }

    static func make(scale: Double) -> Loop? {
        let controller = MascotController.shared
        guard let director = controller.director else { return nil }
        let canvas = NotchCanvas(director: director, time: controller.stoppedAt, layout: controller.layout, snapshot: nil,
                                 now: Date(), character: PanelSettings.shared.mascotCharacter, look: controller.look,
                                 effectsLive: true, motion: controller.motion)
        guard let plan = plan(canvas, now: controller.time(), effectTime: { controller.effectTime(at: $0) }) else { return nil }
        let count = max(1, Int((plan.length / 1000 * plan.fps).rounded()))
        var images: [CGImage] = []
        for k in 0..<count {
            let renderer = ImageRenderer(content: plan.draw(Int((Double(k) * plan.length / Double(count)).rounded())))
            renderer.scale = scale
            guard let image = renderer.cgImage else { return nil }
            images.append(image)
        }
        return Loop(images: images, duration: plan.length / 1000,
                    offset: Double(plan.clock).truncatingRemainder(dividingBy: plan.length) / 1000, box: plan.box)
    }
}

/// 某一刻的整個瀏海（純函式：director＋時間）
struct NotchCanvas: View {
    let director: MascotDirector
    let time: Int
    let layout: NotchLayout
    let snapshot: UsageSnapshot?
    let now: Date
    let character: MascotCharacter
    var extras = NotchExtras()
    /// 角色外觀（ADR-0021）；nil 是跟著服務色
    var look: MascotLook?
    /// 外觀的特效在動（否則畫靜態的一格）
    var effectsLive = false
    /// 特效的時鐘（App 裡由 MascotController 給，停住時停在最後一格）；截圖時 nil，用畫面的時間
    var effectClock: ((Int) -> Int?)?
    /// 截圖用：看滑鼠的方向固定為正面
    var gazeOverride: (yaw: Double, pitch: Double)?
    /// 動畫程度：簡單時不畫粒子；關閉時也不眨眼、不看滑鼠
    var motion = MascotMotionLevel.full
    /// 展開待著或睡著：只有角色以這個頻率重畫（時間由 `heroClock` 換算）；nil 時角色照 `time` 畫
    var heroRate: MascotRenderRate?
    var heroClock: ((Date) -> Int)?

    var body: some View {
        let shape = director.panelShape(at: time)
        let content = director.content(at: time)
        ZStack(alignment: .topLeading) {
            NotchShape(width: shape.width, height: shape.height, corner: shape.corner).fill(.black)
            NotchContent(snapshot: snapshot, now: now, extras: extras)
                .opacity(content.opacity)
                .offset(y: content.offset)
            miniRing
                .opacity(shape.miniOpacity)
            agentCount
                .opacity(shape.miniOpacity)
            if extras.needsYou {
                // 需要你：外框琥珀色（收合、展開都在；靜止，不重畫）。線畫在遮罩上，只看得到內側一半
                NotchShape(width: shape.width, height: shape.height, corner: shape.corner)
                    .stroke(notchAmber, lineWidth: 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            hero
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(heroDescription)
                .accessibilityAddTraits(.isImage)
        }
        .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
        .mask(NotchShape(width: shape.width, height: shape.height, corner: shape.corner))
        .accessibilityElement(children: .contain)
    }

    /// VoiceOver：角色、在做什麼、額度狀態（畫面上只靠姿勢與表情，Fable F-07）
    private var heroDescription: String {
        let mode = director.isStill ? .none : director.mode
        let activity = if director.machine.thinksRemotely || extras.staticRemote { "其他電腦的 AI 工作中" } else {
            switch mode {
            case .raise: "舉手，有 AI 需要你"
            case .work: "工作中"
            case .sleep: "睡著了"
            case .think: "AI 在背景執行"
            case .none: "待命"
            }
        }
        let status = switch director.mood {
        case .stale: "額度資料過期或讀取失敗"
        case .out: "額度用完"
        case .worried: "額度剩不到 20% 或照目前速度會在重置前用完"
        case .sick: "服務狀態頁有進行中的事故"
        default: "額度正常"
        }
        return "\(character.title) 角色，\(activity)，\(status)"
    }

    @ViewBuilder
    private var hero: some View {
        if let heroRate, let heroClock {
            // 收合時特效在動：連看滑鼠也最多每秒 12 次
            let interval = effectsLive && !director.machine.isOpen ? max(heroRate.interval, MascotRenderRate.effect.interval)
                : heroRate.interval
            if heroRate == .effect {
                // 只有特效在動：角色由視窗上另一個小的畫面（`NotchEffectHero`）畫，這張畫布整個不動
                Color.clear
            } else {
                TimelineView(.animation(minimumInterval: interval)) { context in
                    let now = heroClock(context.date)
                    heroCanvas(at: now, effectTime: effectTime(now))
                }
            }
        } else {
            heroCanvas(at: time, effectTime: effectTime(time))
        }
    }

    /// 只有特效在動（ADR-0021）：角色本身停在 `time` 那一刻，只重畫角色周圍一小塊（含光暈）。
    /// 放在獨立的 NSHostingView（`NotchEffectHero`），每一格只更新這一小塊，不會讓整個瀏海的畫面重新排版
    var effectHero: some View {
        let box = effectBox
        return TimelineView(.animation(minimumInterval: MascotRenderRate.effect.interval)) { context in
            effectFrame(effectTime: effectTime(heroClock?(context.date) ?? time))
        }
        .position(x: box.midX, y: box.midY)
    }

    /// 特效時角色那一小塊在畫布上的範圍（含光暈）
    var effectBox: CGRect {
        let pose = director.pose(at: time)
        let side = (pose[.r] * pose[.sc] * 7).rounded(.up) + 8
        return CGRect(x: pose[.x] - side / 2, y: pose[.y] - side / 2, width: side, height: side)
    }

    /// 角色停在 `time`、特效在 `effectTime` 的那一格（`effectBox` 大小）。收合時的動態另外給姿勢、畫的時間與 z 的進度
    func effectFrame(effectTime: Int?, pose: MascotPose? = nil, time drawTime: Int? = nil, dozeRise: Double? = nil,
                     thinkingDots: Int? = nil) -> some View {
        let box = effectBox
        var f = frame(at: time, effectTime: effectTime)
        if let pose { f.pose = pose }
        if let drawTime { f.time = drawTime }
        f.dozeRise = dozeRise
        f.thinkingDots = thinkingDots
        return Canvas(rendersAsynchronously: false) { [f] canvas, _ in
            canvas.translateBy(x: -box.minX, y: -box.minY)
            MascotPainter(config: director.config).draw(f, in: &canvas, particles: false)
        }
        .frame(width: box.width, height: box.height)
    }

    private func effectTime(_ t: Int) -> Int? {
        effectClock.map { $0(t) } ?? (effectsLive ? t : nil)
    }

    private func heroCanvas(at time: Int, effectTime: Int?) -> some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            MascotPainter(config: director.config).draw(frame(at: time, effectTime: effectTime), in: &context,
                                                        particles: motion.drawsParticles)
        }
    }

    private func frame(at time: Int, effectTime: Int? = nil) -> MascotFrame {
        let still = !motion.movesEyes
        let gaze = gazeOverride ?? (still ? (0, 0) : director.gaze(at: time))
        // 只有其他電腦在工作：泡泡旁畫小電腦；展開時、動畫「簡單」「關閉」時也看得出來（泡泡停在亮兩顆，不另外重畫；
        // 收合時的循環照時間亮，Fable G-11）
        let remote = director.machine.thinksRemotely || extras.staticRemote
        return MascotFrame(time: time, pose: director.pose(at: time), eyes: director.eyes(at: time),
                           blink: still ? 0 : director.blink(at: time),
                           gazeYaw: gaze.yaw, gazePitch: gaze.pitch, statusColor: director.statusColor(at: time),
                           mood: director.mood(at: time),
                           sleeping: director.showsSleep, dozing: director.showsDoze,
                           thinkingDots: remote ? 2 : nil, remoteBadge: remote, effects: director.effects,
                           ripple: director.ripple, character: character, look: look, effectTime: effectTime)
    }

    /// 收合時迷你角色旁的數量：兩個以上的工作階段在跑或等你時顯示；有需要你的時用琥珀色
    @ViewBuilder
    private var agentCount: some View {
        if extras.activeCount >= 2 {
            Text("\(extras.activeCount)")
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(extras.needsYou ? notchAmber : Color.white.opacity(0.6))
                .fixedSize()
                .position(x: layout.miniX + 18, y: layout.miniY + 1)
                .accessibilityLabel("\(extras.activeCount) 個 AI 工作階段\(extras.needsYou ? "，有需要你的" : "")")
        }
    }

    /// 收合時右邊：服務色的迷你圓環與剩餘百分比（角色所代表的服務中剩最少的額度）
    @ViewBuilder
    private var miniRing: some View {
        let item = snapshot.flatMap { NotchQuota.tightest(in: $0, provider: character.provider, now: now) }
        let remaining = item.map { Int($0.effectiveRemainingPct(at: now).rounded()) }
        let stale = snapshot?.isStale(now: now) ?? false
        HStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 2.2, dash: stale ? [1.8, 1.6] : []))
                Circle()
                    .trim(from: 0, to: Double(remaining ?? 0) / 100)
                    .stroke(ringColor(item), style: StrokeStyle(lineWidth: 2.2, lineCap: stale ? .butt : .round, dash: stale ? [1.8, 1.6] : []))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text(remaining.map { "\($0)%" } ?? "–")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .frame(width: 44, alignment: .leading)
        .position(x: layout.ringX - 6.5 + 22, y: layout.miniY)
        .accessibilityLabel("\(character.title) 剩 \(remaining.map(String.init) ?? "–")%\(stale ? "，資料已過期" : "")")
    }

    /// 迷你圓環的顏色：同選單列圖示（過期灰、剩不到 20% 紅、其他服務色）；過期時另改成虛線，不只靠顏色
    private func ringColor(_ item: UsageWindow?) -> Color {
        guard let item, let snapshot else { return UsageColors.provider(character.provider) }
        return UsageColors.bar(item, provider: character.provider, stale: snapshot.isStale(now: now), now: now)
    }
}

/// 額度的挑選（瀏海面板用）
enum NotchQuota {
    /// 某服務剩最少的額度；服務出錯或沒有資料為 nil
    static func tightest(in snapshot: UsageSnapshot, provider: String, now: Date) -> UsageWindow? {
        guard let usage = snapshot.providers[provider], usage.error == nil else { return nil }
        return usage.visibleWindows.min { $0.effectiveRemainingPct(at: now) < $1.effectiveRemainingPct(at: now) }
    }


    /// 會在重置前用完、而且最早用完的可見額度的預測與名稱（快照裡收集器算好的，瀏海不讀資料庫）
    static func forecast(in snapshot: UsageSnapshot?, provider: String, now: Date) -> (QuotaForecast, String)? {
        guard let snapshot, let usage = snapshot.providers[provider], usage.error == nil else { return nil }
        let stale = snapshot.isStale(now: now)
        return usage.visibleWindows.compactMap { w in
            QuotaForecast.current(window: w, provider: provider, history: nil, stale: stale, now: now).map { ($0, w.id == "five_hour" ? "5h" : w.label) }
        }.min { $0.0.exhaustsAt < $1.0.exhaustsAt }
    }

    /// 第一個有影響的事故（同角色生病的規則）
    static func incident(in snapshot: UsageSnapshot?, provider: String) -> ServiceIncident? {
        snapshot?.providers[provider]?.incidents?.first(where: \.isDisruption)
    }

    /// 額度的等級：出錯或用完 2、剩不到 20% 1、其他 0（同通知「剩不到 20%」的門檻）
    static func statusLevel(in snapshot: UsageSnapshot?, provider: String, now: Date) -> Int {
        guard let snapshot, let usage = snapshot.providers[provider] else { return 0 }
        if usage.error != nil { return 2 }
        guard let window = tightest(in: snapshot, provider: provider, now: now) else { return 0 }
        let remaining = window.effectiveRemainingPct(at: now)
        if remaining <= 0 { return 2 }
        return remaining < UsageSeverity.criticalBelow ? 1 : 0
    }
}

/// 展開後的內容：上緣分頁與更新時間、角色卡（角色由畫布畫在上面）、額度卡
struct NotchContent: View {
    let snapshot: UsageSnapshot?
    let now: Date
    var extras = NotchExtras()

    private static let card = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x16 / 255)
    private static let secondary = Color(red: 0x9a / 255, green: 0x9a / 255, blue: 0xa8 / 255)
    /// 瀏海永遠是深色底：用提示色與紅色的深色外觀版本
    private static let notice = Color(UsagePalette.notice.dark)
    private static let urgent = Color(UsagePalette.critical.dark)

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: NotchTab.spacing) {
                NotchTab(symbol: NotchTab.faceSymbol, custom: true, label: "總覽", selected: extras.page == .overview) {
                    MascotController.shared.setPage(.overview)
                }
                if extras.hasAgentPage {
                    NotchTab(symbol: "terminal", label: "AI 工作階段", selected: extras.page == .agents,
                             tint: extras.needsYou ? notchAmber : nil) {
                        MascotController.shared.setPage(.agents)
                    }
                }
                NotchTab(symbol: FullPanelController.symbol, label: FullPanelController.openHelp) { FullPanelController.shared.open() }
                NotchTab(symbol: AppActions.statsSymbol, label: "歷史") { AppActions.openStats?(); NSApplication.shared.activate() }
                NotchTab(symbol: "gearshape", label: "設定") { AppActions.openSettings?(); NSApplication.shared.activate() }
            }
            .frame(height: 20)
            .fixedSize()
            .frame(width: tabsWidth, alignment: .leading)
            .position(x: 20 + tabsWidth / 2, y: 17)
            marks
                .frame(height: 20)
                .position(x: 20 + tabsWidth + 8 + 30, y: 17)
            updated
                .frame(height: 20)
                .position(x: NotchLayout.canvasWidth - 20 - 50, y: 17)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 18).fill(Self.card)
                    .frame(width: 140)
                    .accessibilityHidden(true)
                if extras.page == .agents, extras.hasAgentPage {
                    agentsCard
                } else {
                    quotaCard
                }
            }
            .padding(EdgeInsets(top: 34, leading: 16, bottom: 14 + 10, trailing: 16))
            .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)
            // 畫在卡片之後（之前的提示被角色卡的底色蓋住）
            if let level = extras.level, !extras.hint {
                levelBadge(level)
                    .frame(width: 124)
                    .position(x: 16 + 70, y: 151)
            }
            if extras.hint {
                Text("右鍵點我有更多動作")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0xd6 / 255, green: 0xd6 / 255, blue: 0xe0 / 255))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x2e / 255)))
                    .fixedSize()
                    .position(x: 16 + 70, y: 152)
            }
        }
        .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight, alignment: .topLeading)
    }

    /// 角色卡下方的等級、進度與連續天數（所有電腦合併）。等級是文字，不只靠進度條
    private func levelBadge(_ level: MascotLevel) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(level.title)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(red: 0xe8 / 255, green: 0xe8 / 255, blue: 0xf0 / 255))
                    .fixedSize()
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(red: 0x2a / 255, green: 0x2a / 255, blue: 0x32 / 255))
                        Capsule().fill(Color(red: 0xe8 / 255, green: 0xe8 / 255, blue: 0xf0 / 255).opacity(0.85))
                            .frame(width: max(3, proxy.size.width * min(max(level.progress, 0), 1)))
                    }
                }
                .frame(height: 3)
            }
            Text("連續 \(level.currentStreak) 天・最長 \(level.longestStreak) 天")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.accessibilityText)
        .help(level.accessibilityText)
    }

    /// 上緣分頁列的寬度：總覽、完整面板、歷史、設定，有 AI 工作階段時多一個
    private var tabsWidth: Double {
        let count = extras.hasAgentPage ? 5.0 : 4.0
        return count * NotchTab.width + (count - 1) * NotchTab.spacing
    }

    /// 保持展開的圖釘（點了取消並在滑鼠不在面板上時收合）、靜音／勿擾到幾點
    private var marks: some View {
        HStack(spacing: 6) {
            if extras.pinned {
                // 點圖釘：取消保持展開並收起（同 Esc；游標還在面板上也收，Codex 第二輪 C-03）
                Button {
                    MascotController.shared.setPinned(false)
                    MascotController.shared.closeNow()
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 20, height: 20)
                        .foregroundStyle(Color(red: 0xe8 / 255, green: 0xe8 / 255, blue: 0xf0 / 255))
                }
                .buttonStyle(.plain)
                .help("保持展開中：點一下或按 Esc 收起")
                .accessibilityLabel("保持展開中，點一下取消")
            }
            if let until = extras.quietUntil {
                HStack(spacing: 3) {
                    Image(systemName: "bell.slash.fill").font(.system(size: 9))
                    Text(until.formatted(date: .omitted, time: .shortened)).font(.system(size: 10).monospacedDigit())
                }
                .foregroundStyle(Color(red: 0x8d / 255, green: 0x8d / 255, blue: 0x9a / 255))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("靜音到\(until.formatted(date: .omitted, time: .shortened))")
            }
        }
        .frame(width: 60, alignment: .leading)
    }

    private var updated: some View {
        HStack(spacing: 6) {
            if let snapshot {
                Text(ResetCountdown.updatedText(since: snapshot.updatedAt, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0x8d / 255, green: 0x8d / 255, blue: 0x9a / 255))
                Circle()
                    .fill(snapshot.isStale(now: now) ? Color.gray : Color(red: 63 / 255, green: 208 / 255, blue: 122 / 255))
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(snapshot.isStale(now: now) ? "資料過期" : "連線正常")
            }
        }
        .fixedSize()
    }

    private var quotaCard: some View {
        HStack(alignment: .top, spacing: 18) {
            column("claude")
            column("codex")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Self.card))
    }

    /// AI 工作階段：AI、資料夾名稱、狀態、多久（需要你的排最前面）。狀態用文字，不只靠顏色。
    /// 其他電腦的接在這台之後：電腦圖示＋裝置名稱、狀態、工作階段數（沒有資料夾名稱）。最多 4 列
    private var agentsCard: some View {
        let shown = extras.agents.prefix(4)
        let remote = extras.remote.prefix(4 - shown.count)
        let hidden = extras.agents.count + extras.remote.count - shown.count - remote.count
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(shown) { row in
                HStack(spacing: 8) {
                    Text(row.ai == .claude ? "Claude" : "Codex")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UsageColors.provider(row.ai.rawValue))
                        .frame(width: 44, alignment: .leading)
                    Text(row.folder.isEmpty ? "（沒有名稱）" : row.folder)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0xd6 / 255, green: 0xd6 / 255, blue: 0xe0 / 255))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Self.stateText(row))
                        .font(.system(size: 11, weight: row.state == .needsYou ? .semibold : .regular))
                        .foregroundStyle(Self.stateColor(row.state))
                    Text(Self.duration(row.minutes))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color(red: 0x6f / 255, green: 0x6f / 255, blue: 0x7d / 255))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(remote, id: \.id) { row in
                HStack(spacing: 8) {
                    Text(row.ai == .claude ? "Claude" : "Codex")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UsageColors.provider(row.ai.rawValue))
                        .frame(width: 44, alignment: .leading)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 9))
                        .foregroundStyle(Self.secondary)
                        .accessibilityHidden(true)
                    Text(row.device)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0xd6 / 255, green: 0xd6 / 255, blue: 0xe0 / 255))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Self.remoteStateText(row.state))
                        .font(.system(size: 11, weight: row.state == .needsYou ? .semibold : .regular))
                        .foregroundStyle(Self.stateColor(row.state))
                    Text(row.sessions > 1 ? "\(row.sessions) 個" : "")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color(red: 0x6f / 255, green: 0x6f / 255, blue: 0x7d / 255))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.text + (row.sessions > 1 ? "，\(row.sessions) 個工作階段" : ""))
            }
            if hidden > 0 {
                Text("還有 \(hidden) 個")
                    .font(.system(size: 10))
                    .foregroundStyle(Self.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Self.card))
    }

    static func stateText(_ row: NotchAgentRow) -> String {
        switch row.state {
        case .needsYou:
            switch row.need {
            case .permission: "等你允許"
            case .question: "有問題問你"
            case .plan: "等你確認計畫"
            default: "需要你"
            }
        case .error: "出錯了"
        case .working: "工作中"
        case .background: "背景執行中"
        case .done: "完成（未看）"
        case .waiting: "等你下指令"
        case .idle: "閒置"
        }
    }

    /// 其他電腦的狀態（沒有「等你什麼」的細節）
    static func remoteStateText(_ state: AgentState) -> String {
        switch state {
        case .needsYou: "需要你"
        case .done: "完成了"
        default: stateText(NotchAgentRow(id: "", ai: .claude, folder: "", state: state, need: nil, minutes: 0))
        }
    }

    static func stateColor(_ state: AgentState) -> Color {
        switch state {
        case .needsYou: notchAmber
        case .error: Color(red: 240 / 255, green: 80 / 255, blue: 80 / 255)
        case .done: Color(red: 63 / 255, green: 208 / 255, blue: 122 / 255)
        // 背景執行中和工作中同色：都是 AI 還在跑（ADR-0017 第 7 節）
        case .working, .background: Color(red: 0xe6 / 255, green: 0xe6 / 255, blue: 0xee / 255)
        case .waiting, .idle: secondary
        }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 1 { return "剛剛" }
        if minutes < 60 { return "\(minutes) 分" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小時" : "\(minutes / 60) 小時 \(minutes % 60) 分"
    }

    @ViewBuilder
    private func column(_ provider: String) -> some View {
        let usage = snapshot?.providers[provider]
        let tint = UsageColors.provider(provider)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(ProviderInfo.displayName(provider))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0xe6 / 255, green: 0xe6 / 255, blue: 0xee / 255))
            }
            .padding(.bottom, 2)
            if let usage, usage.error == nil {
                let windows = usage.visibleWindows
                let stale = snapshot?.isStale(now: now) ?? false
                ForEach(Array(windows.prefix(2).enumerated()), id: \.element.id) { index, window in
                    // 同面板的進度條規則（FR-16）：過期灰、剩不到 20% 紅、其他服務色
                    row(window, tint: UsageColors.bar(window, provider: provider, stale: stale, now: now), primary: index == 0)
                }
                // 最後一行（ADR-0018 第 3 節）：服務事故 > 會在重置前用完的預測 > 重置倒數
                if let incident = NotchQuota.incident(in: snapshot, provider: provider) {
                    incidentLine(incident)
                } else if let (forecast, label) = NotchQuota.forecast(in: snapshot, provider: provider, now: now) {
                    HStack(spacing: 3) {
                        Image(systemName: forecast.urgent ? "exclamationmark.circle.fill" : "speedometer")
                            .font(.system(size: 9))
                            .accessibilityHidden(true)
                        Text(windows.count > 1 ? "\(label) \(forecast.shortLine(now: now))" : forecast.shortLine(now: now))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(forecast.urgent ? Self.urgent : Self.notice)
                    .padding(.top, 7)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(forecast.spokenLine(now: now))
                } else if let reset = windows.first?.resetsAt, let text = ResetCountdown.text(until: reset, now: now) {
                    Text("\(text)後重置")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0x6f / 255, green: 0x6f / 255, blue: 0x7d / 255))
                        .padding(.top, 7)
                }
            } else {
                Text(usage == nil ? "沒有啟用" : "讀取失敗")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.secondary)
                    .padding(.top, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 服務事故：名稱（點了用瀏覽器打開事故頁；連結只接受官方狀態頁）
    @ViewBuilder
    private func incidentLine(_ incident: ServiceIncident) -> some View {
        let label = HStack(spacing: 3) {
            Image(systemName: "cross.case.fill").font(.system(size: 9)).accessibilityHidden(true)
            Text(incident.name).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Self.notice)
        .padding(.top, 7)
        if let link = incident.link {
            Button { NSWorkspace.shared.open(link) } label: { label }
                .buttonStyle(.plain)
                .help("服務異常：\(incident.name)（點一下打開狀態頁）")
                .accessibilityLabel("服務異常：\(incident.name)，點一下打開狀態頁")
        } else {
            label
                .help("服務異常：\(incident.name)")
                .accessibilityLabel("服務異常：\(incident.name)")
        }
    }

    private func row(_ window: UsageWindow, tint: Color, primary: Bool) -> some View {
        let remaining = window.effectiveRemainingPct(at: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).foregroundStyle(Self.secondary)
                Spacer()
                Text("剩 \(Int(remaining.rounded()))%")
                    .fontWeight(.medium)
                    .foregroundStyle(Color(red: 0xd6 / 255, green: 0xd6 / 255, blue: 0xe0 / 255))
            }
            .font(.system(size: 11).monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(red: 0x2a / 255, green: 0x2a / 255, blue: 0x32 / 255))
                    Capsule().fill(tint.opacity(primary ? 1 : 0.6))
                        .frame(width: geo.size.width * remaining / 100)
                }
            }
            .frame(height: 4)
        }
        .padding(.top, 7)
    }
}

/// 上緣的分頁按鈕（總覽在瀏海裡；歷史、設定打開現有的視窗）
struct NotchTab: View {
    static let width = 22.0
    static let spacing = 4.0

    /// 「總覽」：角色的臉（Assets.xcassets 的自訂 symbol，由 scripts/make-face-symbol.py 產生）
    static let faceSymbol = "notch.face"

    let symbol: String
    /// `symbol` 是 Asset Catalog 的自訂 symbol（不是 SF Symbols）
    var custom = false
    let label: String
    var selected = false
    /// 需要你時 AI 工作階段的分頁用琥珀色
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            (custom ? Image(symbol) : Image(systemName: symbol))
                .font(.system(size: 11, weight: .medium))
                .frame(width: Self.width, height: 20)
                .background(Capsule().fill(selected ? Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x2e / 255) : .clear))
                .foregroundStyle(tint ?? (selected ? Color(red: 0xe8 / 255, green: 0xe8 / 255, blue: 0xf0 / 255)
                                                   : Color(red: 0x77 / 255, green: 0x77 / 255, blue: 0x8a / 255)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
