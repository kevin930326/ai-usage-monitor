import AppKit
import SwiftUI
import UsageKit

/// 看滑鼠時的角色（icons 第 4 部分，ADR-0016 第 6 節）：只有視線在轉時，角色改由這個小畫面用 CoreGraphics 畫，
/// 每一格只重畫角色周圍一小塊，不經過 SwiftUI。SwiftUI 每一格的排版與送出約 0.25% CPU，跟著螢幕更新率會超過
/// 展開 2%、收合 1% 的目標；瀏海的畫布這段期間只留停住的光暈（`NotchCanvas.heroOnLayer`）。
/// 身體只會平移時（`MascotPainter.bodyIsRigid`）再拆成兩層：身體畫成一張固定的圖、每格只搬位置；臉（眼睛、眉毛、腮紅）
/// 每格在一小塊裡重畫。格子、線框這類身體跟著視線變的外觀整個角色每格重畫。
/// 疊在瀏海畫布上、不接收滑鼠，畫的範圍照瀏海的形狀裁切（收合時提醒光環不會畫到瀏海外面）。
final class MascotHeroLayerView: NSView {
    /// 在畫布上的範圍（角色停住那一刻的位置，含特效）
    private(set) var box = CGRect.zero
    private var link: CADisplayLink?
    /// display link 會留住它的 target：用這個只弱參照 view 的小物件，view 才放得掉（Codex C-01）
    private let linkTarget = LinkTarget()
    private var lastDraw = Int.min
    #if DEBUG
    /// 量測用：約每秒記一次這段時間平均每秒畫了幾格（`DebugTools.perfFrames`）；since 是這段的開始、last 是上一格
    private var frames = (count: 0, drawn: 0, since: 0, last: 0)
    #endif
    /// 每一格畫在這個圖層自己的 backing store 上（`setNeedsDisplay` → `draw(in:)`）：不經過 NSView 的 draw
    /// （AppKit 會先錄成 display list 再重播），也不必每格把新的圖片送給 render server
    private let heroLayer = CALayer()
    /// 拆成兩層時的身體（固定的圖，每格只改位置）
    private let bodyLayer = CALayer()
    private let painter = Painter()
    /// 瀏海的形狀（畫布座標）：畫的範圍照它裁切
    private var clip: CGPath?
    /// 這一格要畫的（`prepare` 算好，`draw(in:)` 畫）
    private var current: MascotFrame?
    /// 每格重畫的那一塊在 `box` 裡的位置（y 往下）
    private var drawn = CGRect.zero
    /// 身體那張圖是依什麼畫的、畫的時候角色在哪裡；nil 是沒拆（整個角色每格重畫）
    private var body: (key: BodyKey, at: CGPoint)?
    /// 上次重畫的臉（拆成兩層時）：視線只差不到 1/4 個像素、其他都一樣時這一格不重畫、不送出
    private var face: (key: BodyKey, blink: Double, yaw: Double, pitch: Double, at: CGPoint)?
    /// 上一次送出時角色的位置（畫布座標）
    private var placedAt = CGPoint(x: -1e9, y: -1e9)
    /// 視線差多少（裝置像素）以內算畫出來一樣：眼睛移動的距離約是半徑 × 角度差
    static let invisibleShift = 0.25

    /// 身體的圖依這些畫：任何一個變了就重畫一張
    private struct BodyKey: Equatable {
        var pose: [Double]
        var eyes: MascotEyes
        var mood: MascotMood
        var look: String?
        var character: MascotCharacter
        var thinkingDots: Int?
        var remoteBadge: Bool
        var remoteBadgeAbove: Bool
        var dozing: Bool
        var dozeRise: Double?
        var sleeping: Bool
        var statusColor: Double

        init(_ f: MascotFrame) {
            pose = f.pose.values
            eyes = f.eyes
            mood = f.mood
            look = f.look?.id
            character = f.character
            thinkingDots = f.thinkingDots
            remoteBadge = f.remoteBadge
            remoteBadgeAbove = f.remoteBadgeAbove
            dozing = f.dozing
            dozeRise = f.dozeRise
            sleeping = f.sleeping
            statusColor = f.statusColor
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        isHidden = true
        heroLayer.delegate = painter
        bodyLayer.delegate = painter
        // 8 位元就夠（預設會跟著螢幕用 16 位元，漸層要多花一倍的工）
        heroLayer.contentsFormat = .RGBA8Uint
        layer?.addSublayer(bodyLayer)
        layer?.addSublayer(heroLayer)
        painter.view = self
        linkTarget.view = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 每秒幾格（`start` 算好；每格都問螢幕的更新率很貴，CI 取樣）
    private var fps = 30
    /// 這一側最快的格數（展開跟著螢幕、最多 120；收合 30）：量測報表看有沒有降幀
    private var topRate = 30
    /// 超標自動降幀（`MascotFrameGovernor`，ADR-0016 第 6 節）：依「展開／收合、螢幕更新率」各記一份，換螢幕不會沿用別的階梯
    /// （Fable F-08）。收合時外觀的特效在動則固定照特效最多 12 格（ADR-0021），不降幀（nil）
    private static var governors: [String: MascotFrameGovernor] = [:]
    private var governorKey: String?

    /// 看滑鼠時 App 的 CPU 目標（TASK icons 第 4 部分：展開 ≤ 2%、收合 ≤ 1%）
    static func budget(open: Bool) -> Double { open ? 2 : 1 }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private func applyRate() {
        let f = Float(fps)
        let wanted = CAFrameRateRange(minimum: f / 2, maximum: f, preferred: f)
        if link?.preferredFrameRateRange != wanted { link?.preferredFrameRateRange = wanted }
    }

    /// 這一側要用的格數：最快的一級，超標時由 `MascotFrameGovernor` 往下降（展開最少 30、收合最少 15）
    private func chooseRate(open: Bool, effectsLive: Bool) {
        let screen = window?.screen?.maximumFramesPerSecond ?? 60
        if !open, effectsLive {
            governorKey = nil
            fps = Int((1 / MascotRenderRate.effect.interval).rounded())
            topRate = fps
            return
        }
        let cap = Int((1 / (open ? MascotRenderRate.gazeOpen : .gaze).interval).rounded())
        let rates = MascotFrameGovernor.rates(screen: screen, cap: cap, floor: open ? 30 : 15)
        let key = "\(open ? "open" : "collapsed")-\(screen)"
        if Self.governors[key]?.rates != rates {
            Self.governors[key] = MascotFrameGovernor(rates: rates, budget: Self.budget(open: open))
        }
        governorKey = key
        fps = Self.governors[key]?.fps ?? rates[0]
        topRate = rates[0]
    }

    /// 每一格交給降幀的判斷；換了一級就改 display link 的頻率
    private func govern(at t: Int, open: Bool) {
        guard let key = governorKey, var governor = Self.governors[key] else { return }
        let change = governor.observe(at: t, cpu: Self.processCPU)
        Self.governors[key] = governor
        // 很久沒看滑鼠後 governor 自己重來（沒有 Change）：也要照它的格數（Codex C-01）
        if fps != governor.fps {
            fps = governor.fps
            applyRate()
        }
        #if DEBUG
        if let change {
            DebugTools.perfMark(String(format: "gaze-rate %@ %d %d %.2f", open ? "open" : "collapsed", change.from, change.to, change.cpu))
        }
        #endif
    }

    func start() {
        let controller = MascotController.shared
        guard let director = controller.director else { return }
        let pose = director.pose(at: controller.stoppedAt)
        let r = pose[.r] * pose[.sc]
        // 提醒光環最大到 3 倍半徑；呼吸、晃動只移動一兩點
        let half = (r * 3.1 + 6).rounded(.up)
        box = CGRect(x: pose[.x] - half, y: pose[.y] - half, width: half * 2, height: half * 2)
        let shape = director.panelShape(at: controller.stoppedAt)
        clip = NotchShape(width: shape.width, height: shape.height, corner: shape.corner)
            .path(in: CGRect(x: 0, y: 0, width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)).cgPath
        let scale = window?.backingScaleFactor ?? 2
        heroLayer.contentsScale = scale
        bodyLayer.contentsScale = scale
        body = nil
        face = nil
        placedAt = CGPoint(x: -1e9, y: -1e9)
        bodyLayer.contents = nil
        if link == nil {
            let link = displayLink(target: linkTarget, selector: #selector(LinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        chooseRate(open: director.machine.isOpen, effectsLive: controller.effectsLive)
        applyRate()
        // 馬上畫第一格：和瀏海畫布藏起角色在同一次更新裡送出，不會空一格
        lastDraw = controller.time()
        #if DEBUG
        // 眨眼那一下（約 0.3 秒）由 SwiftUI 畫、圖層停掉又開始：短暫的停頓接著算，紀錄才不會斷掉（Codex 第三輪 C-01）
        if lastDraw - frames.last > 1500 { frames = (0, 0, lastDraw, lastDraw) }
        #endif
        // 位置由瀏海的視窗（`layoutCanvas`）放；大小先定好，第一格的圖層才放得對
        setFrameSize(box.size)
        prepare()
        isHidden = false
    }

    func stop() {
        link?.invalidate()
        link = nil
        MascotController.shared.heroLinkStopped()
        isHidden = true
        bodyLayer.contents = nil
        body = nil
        face = nil
        current = nil
    }

    fileprivate func tick() {
        // `preferredFrameRateRange` 只是建議：多的自己跳過（留 3 毫秒的誤差）
        let t = MascotController.shared.time()
        let controller = MascotController.shared
        govern(at: t, open: controller.director?.machine.isOpen == true)
        guard t - lastDraw >= 1000 / fps - 3 else { return }
        lastDraw = t
        // 同一個 display link 也讀游標（不另開一個，icons 第 4 部分第三版）：先更新視線再畫
        controller.heroLinkTick(covers: controller.director?.machine.isOpen == true || !controller.effectsLive)
        // 讀游標時停下來了（視線轉到位、游標停住）：圖層已經停掉
        guard link != nil else { return }
        prepare()
    }

    /// 算這一格：身體能拆開時畫（或沿用）身體的圖、搬到這一格的位置，臉那一小塊等一下重畫；不能拆時整個角色重畫
    private func prepare() {
        let controller = MascotController.shared
        guard let director = controller.director else { return }
        let settings = PanelSettings.shared
        let canvas = NotchCanvas(director: director, time: controller.stoppedAt, layout: controller.layout, snapshot: nil,
                                 now: Date(), character: settings.mascotCharacter,
                                 extras: NotchExtras(staticRemote: !controller.motion.animatesBody
                                                         && controller.activity?.thinksRemotely == true),
                                 look: controller.look, effectsLive: controller.effectsLive,
                                 effectClock: { controller.effectTime(at: $0) }, motion: controller.motion,
                                 liveGaze: { controller.liveGaze(at: $0) }, heldPose: controller.heldPose)
        let frame = canvas.heroFrame(at: controller.time())
        let mascot = MascotPainter(config: director.config)
        let rigid = MascotPainter.bodyIsRigid(frame)
        let key = BodyKey(frame)
        let at = mascot.heroCenter(frame)
        // 畫出來和上一格看不出差別（差不到 1/4 個裝置像素）的就不重畫：每一格的 CPU 大多花在重畫與送出上（CI 取樣，
        // icons 第 4 部分第三版）。視線沒變、只有上下浮動的位置變了：兩層一起搬，不重畫；位置也幾乎沒變：連送出都省掉
        let scale = heroLayer.contentsScale, r = frame.pose[.r] * frame.pose[.sc] * scale
        // 只搬不畫最多累積 1 個裝置像素：內容裡烘進去的瀏海裁切也跟著搬，搬多了邊會偏（Fable F-05）
        let sameFace = rigid && face.map {
            $0.key == key && $0.blink == frame.blink
                && abs(frame.gazeYaw - $0.yaw) * r < Self.invisibleShift && abs(frame.gazePitch - $0.pitch) * r < Self.invisibleShift
                && hypot(at.x - $0.at.x, at.y - $0.at.y) * scale < 1
        } == true
        let samePlace = sameFace && hypot(at.x - placedAt.x, at.y - placedAt.y) * scale < Self.invisibleShift
        #if DEBUG
        frames.count += 1
        if !sameFace { frames.drawn += 1 }
        frames.last = frame.time
        if frame.time - frames.since >= 1000 {
            let span = frame.time - frames.since
            DebugTools.perfFrames(frames.count * 1000 / span, drawn: frames.drawn * 1000 / span, target: fps, top: topRate, open: director.machine.isOpen)
            frames = (0, 0, frame.time, frame.time)
        }
        #endif
        if samePlace { return }
        placedAt = at
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if sameFace, let body, let face {
            place(bodyLayer, at: bounds.offsetBy(dx: at.x - body.at.x, dy: at.y - body.at.y))
            // `drawn`（重畫時的範圍）不動：Core Animation 自己要重畫時照原本的位置畫 `current`，再一起被搬過去
            place(heroLayer, at: Self.faceBox(frame, at: body.at).offsetBy(dx: -box.minX + at.x - face.at.x, dy: -box.minY + at.y - face.at.y)
                .intersection(bounds), records: false)
            return
        }
        current = frame
        guard rigid else {
            face = nil
            if body != nil {
                body = nil
                bodyLayer.contents = nil
            }
            place(heroLayer, at: bounds)
            heroLayer.setNeedsDisplay()
            return
        }
        face = (key, frame.blink, frame.gazeYaw, frame.gazePitch, at)
        if body?.key != key {
            bodyLayer.contents = Self.image(frame, parts: .body, painter: mascot, box: box, clip: clip, scale: bodyLayer.contentsScale)
            body = (key, at)
        }
        guard let body else { return }
        place(bodyLayer, at: bounds.offsetBy(dx: at.x - body.at.x, dy: at.y - body.at.y))
        place(heroLayer, at: Self.faceBox(frame, at: body.at).offsetBy(dx: -box.minX, dy: -box.minY).intersection(bounds))
        heroLayer.setNeedsDisplay()
    }

    /// 每格重畫的臉那一塊（畫布座標）：眼睛的發光、腮紅都不超過 1.2 倍半徑（`DebugHeroParity` 也照這塊裁）
    static func faceBox(_ frame: MascotFrame, at center: CGPoint) -> CGRect {
        let r = frame.pose[.r] * frame.pose[.sc]
        let half = (r * 1.2 + 6).rounded(.up)
        return CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2)
    }

    /// 圖層放在 `rect`（y 往下）；這個 view 的 backing layer 沒有翻轉時（y 往上）換算
    private func place(_ sublayer: CALayer, at rect: CGRect, records: Bool = true) {
        if sublayer === heroLayer, records { drawn = rect }
        let frame = layer?.isGeometryFlipped == true ? rect
            : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        if sublayer.frame != frame { sublayer.frame = frame }
    }

    fileprivate func render(_ layer: CALayer, in cg: CGContext) {
        guard layer === heroLayer, !isHidden, let current, let director = MascotController.shared.director else { return }
        if !layer.contentsAreFlipped() {
            cg.translateBy(x: 0, y: layer.bounds.height)
            cg.scaleBy(x: 1, y: -1)
        }
        // 這個圖層在畫布上的範圍
        let area = drawn.offsetBy(dx: box.minX, dy: box.minY)
        Self.paint(current, parts: body == nil ? [.body, .face] : .face, painter: MascotPainter(config: director.config),
                   box: area, clip: clip, in: cg)
    }

    /// 座標已是 y 往下、原點在範圍左上角的 context 上畫這一格（`DebugHeroParity` 也用這份比對）
    static func paint(_ frame: MascotFrame, parts: MascotPainter.Parts, painter: MascotPainter, box: CGRect, clip: CGPath?,
                      in cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: -box.minX, y: -box.minY)
        if let clip {
            cg.addPath(clip)
            cg.clip()
        }
        painter.drawCharacter(frame, parts: parts, in: cg)
        cg.restoreGState()
    }

    /// 範圍 `box`（畫布座標）畫成透明背景的圖
    static func image(_ frame: MascotFrame, parts: MascotPainter.Parts, painter: MascotPainter, box: CGRect, clip: CGPath?,
                      scale: Double) -> CGImage? {
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: scale, y: -scale)
        paint(frame, parts: parts, painter: painter, box: box, clip: clip, in: cg)
        return cg.makeImage()
    }

    private final class LinkTarget: NSObject {
        weak var view: MascotHeroLayerView?

        @MainActor @objc func tick(_ link: CADisplayLink) {
            view?.tick()
        }
    }

    /// 圖層的 delegate（NSView 自己是它的 backing layer 的 delegate，另外的圖層用這個）
    @MainActor
    private final class Painter: NSObject, @preconcurrency CALayerDelegate {
        weak var view: MascotHeroLayerView?

        func draw(_ layer: CALayer, in ctx: CGContext) {
            view?.render(layer, in: ctx)
        }

        /// 換內容、搬位置都不要隱含動畫
        func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
    }
}
