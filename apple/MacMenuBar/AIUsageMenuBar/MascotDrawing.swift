import SwiftUI
import UsageKit

/// 角色的服務色（MASCOT-SPEC 第 2 節的色票）
enum MascotCharacter: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var provider: String { rawValue }

    func tint(_ palette: MascotConfig.Palette) -> MascotConfig.Tint {
        self == .claude ? palette.claude : palette.codex
    }
}

/// 某一刻要畫的全部內容。`MascotDirector` 依狀態機產生，截圖工具也可以直接組出來（固定時間與種子）。
struct MascotFrame {
    var time: Int
    var pose: MascotPose
    var eyes: MascotEyes
    /// 眨眼（0…1，疊加在 dash 上）
    var blink: Double
    /// 看滑鼠的偏航、俯仰（已平滑）
    var gazeYaw: Double
    var gazePitch: Double
    /// 提醒光環的顏色（0 正常 → 1 偏高 → 2 用完，可以是中間值）；額度本身改用表情表示，沒有狀態點
    var statusColor: Double
    /// 平常的表情（眼睛是膠囊、沒在閉眼時換成表情的眼睛與眉毛）
    var mood: MascotMood = .normal
    var sleeping: Bool
    /// 收著時睡著：迷你角色旁的小 z
    var dozing = false
    /// 收著睡著時小 z 飄起的進度（0…1，ADR-0021 收合時的動態）；nil 時 z 靜止
    var dozeRise: Double?
    /// 收合時 AI 工作中的思考泡泡（ADR-0021 第 4 節）：右上方三個小點中亮了幾顆（0…3）；nil 時不畫
    var thinkingDots: Int?
    var effects: [MascotEffect]
    var ripple: MascotRipple?
    var character: MascotCharacter
    /// 角色外觀（ADR-0021）；nil 是跟著服務色
    var look: MascotLook?
    /// 特效的時間（毫秒）；nil 時特效畫靜態的一格（收合閒置、動畫簡單或關閉、減少動態效果）
    var effectTime: Int?
}

/// 角色的繪製（數值同 notch-demo.html 的 drawHero、drawWave、drawFX）。只依 `MascotFrame` 畫，不保存狀態。
struct MascotPainter {
    let config: MascotConfig
    /// 畫布寬（漣漪碰到邊緣的位置、粒子的淡出依它計算）
    var canvasWidth: Double = 580
    var panelHeight: Double = 180
    var center = CGPoint(x: 290, y: 95)

    private var hero: MascotConfig.Hero { config.hero }

    func draw(_ frame: MascotFrame, in context: inout GraphicsContext, particles: Bool) {
        if particles, let ripple = frame.ripple {
            drawRipple(ripple, frame: frame, in: &context)
        }
        let placed = drawHero(frame, in: &context)
        drawEffects(frame, placed: placed, in: &context)
    }

    // MARK: - 顏色

    private func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
        zip(a, b).map { $0 + ($1 - $0) * t }
    }

    private func color(_ c: [Double], _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, opacity: alpha)
    }

    private func cgColor(_ c: [Double], _ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: alpha)
    }

    private func glowColor(_ frame: MascotFrame) -> [Double] {
        mix(config.palette.white.glow, frame.look?.glow ?? frame.character.tint(config.palette).glow, frame.pose[.tint])
    }

    /// 身體三階漸層的目標色：服務色、外觀的三階或特效主色的三階；直線漸層、線框、霓虹沒有（過場時先畫白色）
    private func bodyTint(_ frame: MascotFrame) -> (light: [Double], mid: [Double], shade: [Double])? {
        guard let look = frame.look else {
            let tint = frame.character.tint(config.palette)
            return (tint.light, tint.mid, tint.shade)
        }
        if look.style.isGrid { return look.effectTint }
        return look.style == .solid ? (look.light ?? [], look.mid ?? [], look.shade ?? []) : nil
    }

    /// 思考泡泡亮起的顏色：服務色與單色外觀用淺色、直線漸層用最亮的一段、特效外觀用主色
    private func thinkingColor(_ frame: MascotFrame) -> [Double] {
        guard let look = frame.look else { return frame.character.tint(config.palette).light }
        switch look.style {
        case .solid: return look.light ?? config.palette.white.light
        case .linear: return look.stops?.max { $0.reduce(0, +) < $1.reduce(0, +) } ?? config.palette.white.light
        case .led, .pixel, .neon, .wire, .ascii: return look.color ?? config.palette.white.light
        }
    }

    private func statusColor(_ level: Double) -> [Double] {
        let s = config.palette.status
        return level < 1 ? mix(s.normal, s.high, max(level, 0)) : mix(s.high, s.out, min(level - 1, 1))
    }

    // MARK: - 漣漪

    private func drawRipple(_ ripple: MascotRipple, frame: MascotFrame, in context: inout GraphicsContext) {
        let now = frame.time
        let cx = center.x, cy = center.y
        let cfg = ripple.config
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            let tinted = color(glowColor(frame))
            for ring in ripple.rings {
                guard let state = ripple.ringState(ring, at: now) else { continue }
                for p in ring.particles {
                    let rr = state.radius + p.jitter + sin(p.angle * cfg.edgeWobbleLobes + ring.seed) * cfg.edgeWobblePx
                    let px = cx + rr * cos(p.angle), py = cy + rr * sin(p.angle) * cfg.verticalSquash
                    guard py >= 4, py <= panelHeight - 4 else { continue }
                    let edge = min(max((cx - cfg.edgeInsetPx - abs(px - cx)) / cfg.edgeFadePx, 0), 1)
                    guard edge > 0 else { continue }
                    let twinkle = 0.35 + 0.65 * abs(sin(p.phase + Double(now) / cfg.twinkleMs))
                    layer.opacity = state.fade * edge * twinkle
                    layer.fill(Path(CGRect(x: px, y: py, width: p.size, height: p.size)), with: .color(p.tinted ? tinted : .white))
                }
            }
            layer.opacity = 1
            // 碎片
            let confettiColors: [[Double]] = [[255, 120, 150], [255, 170, 80], [90, 210, 190], [150, 120, 255], [255, 220, 120]]
            let c = cfg.confetti
            if now >= ripple.confettiStart, now < ripple.confettiStart + c.ms {
                let u = Double(now - ripple.confettiStart) / Double(c.ms)
                for piece in ripple.confetti {
                    let d = 20 + MascotEase.out(u) * piece.speed
                    var g = layer
                    g.opacity = (1 - u) * 0.85
                    g.translateBy(x: cx + d * cos(piece.angle) * c.xStretch, y: cy + d * sin(piece.angle) * c.yStretch)
                    g.rotate(by: .radians(piece.rotation + piece.spin * u))
                    g.fill(Path(CGRect(x: -3.5, y: -0.9, width: 7, height: 1.8)), with: .color(color(confettiColors[piece.color])))
                }
            }
            // 邊緣弧光：只亮 0.32 秒
            let flash = ripple.edgeFlashAlpha(at: now, halfWidth: cx)
            if flash > 0 {
                var g = layer
                g.opacity = flash
                g.addFilter(.shadow(color: .white.opacity(0.9), radius: 5))
                for (edge, side) in [(12.0, 1.0), (canvasWidth - 12, -1.0)] {
                    var path = Path()
                    path.move(to: CGPoint(x: edge + side * 10, y: 8))
                    path.addQuadCurve(to: CGPoint(x: edge + side * 10, y: panelHeight - 6),
                                      control: CGPoint(x: edge - side * 3, y: panelHeight / 2))
                    g.stroke(path, with: .color(.white), lineWidth: 1.6)
                }
            }
        }
    }

    // MARK: - 角色

    private struct Hand { var x: Double; var y: Double; var z: Double; var s: Double }

    /// 畫角色；回傳實際畫的位置與半徑（特效依它放）
    @discardableResult
    func drawHero(_ frame: MascotFrame, in context: inout GraphicsContext) -> (x: Double, y: Double, r: Double) {
        let h = frame.pose, now = Double(frame.time)
        let R = h[.r] * h[.sc]
        guard R >= 0.5 else { return (h[.x], h[.y], 0) }
        let u = h[.r] / 40
        let swv = sin(now / 310) * h[.sway], br = sin(now / 700) * h[.breathe]
        let sx = h[.sx] * (1 - 0.02 * br), sy = h[.sy] * (1 + 0.035 * br), roll = h[.roll] + swv * 0.13
        let x = h[.x] + swv * 7 * u + sin(now / 17) * h[.shiver] * 1.8 * u
        let y = h[.y] + sin(now / 480) * 1.4 * u + h[.jump] * R + R * (1 - sy)
        let yaw = h[.yaw] + frame.gazeYaw * h[.follow] + 0.5 * h[.orbit] * cos(now / 150)
        let pitch = h[.pitch] + frame.gazePitch * h[.follow] + 0.32 * h[.orbit] * sin(now / 150)
        let white = config.palette.white
        let look = frame.look
        let target = bodyTint(frame)

        if h[.glow] > 0 {
            let gc = glowColor(frame)
            let alpha = min(0.6, hero.glow.alpha * h[.glow] * (look?.glowScale ?? 1))
            let g = Gradient(stops: [.init(color: color(gc, alpha), location: 0),
                                     .init(color: color(gc, 0), location: 1)])
            let rect = CGRect(x: x - R * 3.3, y: y - R * 3.3, width: R * 6.6, height: R * 6.6)
            context.fill(Path(rect), with: .radialGradient(g, center: CGPoint(x: x, y: y),
                                                           startRadius: R * hero.glow.inner, endRadius: R * hero.glow.outer))
        }

        func sphere(_ cx: Double, _ cy: Double, _ r: Double, alpha: Double = 1, in g: inout GraphicsContext) {
            guard r > 0.05 else { return }
            let t = target == nil ? 0 : h[.tint]
            let to = target ?? (white.light, white.mid, white.shade)
            let stops = [mix(white.light, to.light, t), mix(white.mid, to.mid, t), mix(white.shade, to.shade, t)]
            let b = hero
            g.withCGContext { cg in
                guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                colors: stops.map { cgColor($0, alpha) } as CFArray,
                                                locations: [0, 0.52, 1]) else { return }
                cg.saveGState()
                cg.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
                cg.clip()
                cg.drawRadialGradient(gradient,
                                      startCenter: CGPoint(x: cx + b.bodyHighlight.x * r, y: cy + b.bodyHighlight.y * r),
                                      startRadius: r * 0.04,
                                      endCenter: CGPoint(x: cx - 0.08 * r, y: cy - 0.08 * r), endRadius: r * 1.22,
                                      // 起點的小圓裡面也要塗（canvas 的 createRadialGradient 會塗）；不加的話高光中心會露出一個小洞
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                cg.restoreGState()
            }
        }

        // 手
        var hands: [Hand] = []
        if h[.hands] > 0.01 {
            var l = (x: h[.lx], y: h[.ly], z: h[.lz]), r = (x: h[.rx], y: h[.ry], z: h[.rz])
            if h[.type] > 0 {
                l.y += sin(now / 62) * 0.14 * h[.type]
                r.y += sin(now / 62 + .pi) * 0.14 * h[.type]
            }
            if h[.wave] > 0 {
                let w = hero.wave
                let a = w.angle + w.swing * sin(now * 2 * .pi / w.periodMs)
                let wx = w.pivot[0] + w.radius * cos(a), wy = w.pivot[1] + w.radius * sin(a)
                r.x += (wx - r.x) * h[.wave]
                r.y += (wy - r.y) * h[.wave]
                // 揮手時手不穿過身體：z 固定在前面
                r.z = max(r.z, 0.3)
            }
            if h[.shiver] > 0 {
                l.x += sin(now / 21) * 0.05 * h[.shiver]
                r.x += sin(now / 19 + 1) * 0.05 * h[.shiver]
            }
            let k = hero.hand.popFrom + (1 - hero.hand.popFrom) * min(1, h[.hands])
            for p in [l, r] {
                hands.append(Hand(x: p.x * k, y: p.y * k, z: p.z, s: 1 + p.z * hero.hand.depthScale))
            }
        }
        func drawHand(_ p: Hand, in g: inout GraphicsContext) {
            let cx = x + p.x * R * sx, cy = y + p.y * R * sy, r = R * hero.hand.radius * p.s * min(max(h[.hands] * 1.3, 0), 1)
            let alpha = min(max(h[.hands] * 2, 0), 1)
            var drawn = false
            if let look, look.style.isEffect || look.style == .linear, h[.tint] > 0.99, r > 0.05 {
                g.withCGContext { cg in
                    cg.setAlpha(alpha)
                    drawn = MascotLookRenderer.drawHand(look, center: CGPoint(x: cx, y: cy), radius: r, in: cg)
                }
            }
            if !drawn { sphere(cx, cy, r, alpha: alpha, in: &g) }
        }
        for p in hands where p.z < 0 { drawHand(p, in: &context) }

        // 身體（以底部為支點的壓扁已算在 y 裡）
        // 表情：動畫沒有指定眼睛（膠囊）、也沒在睡覺或閉眼時，眼睛與眉毛照平常的表情（額度：擔心的小圓點、用完的 ×、過期閉眼）
        let showsMood = frame.eyes == .pill && h[.dash] < 0.5
        let eyes = showsMood ? (frame.mood.eyes ?? .pill) : frame.eyes
        let dash = max(h[.dash], frame.blink, showsMood ? frame.mood.lid : 0)
        // 外觀的眼睛顏色；nil 表示身體已經畫了膠囊眼（LED、像素）
        // 從白色變成外觀的過場中，眼睛顏色跟著混，不會在最後一刻跳色（Fable F-09）
        let targetEyes = MascotLookRenderer.eyes(for: look, radius: R, pill: eyes == .pill)
        let lookEyes = h[.tint] > 0.99 ? targetEyes
            : MascotLookRenderer.Eyes(color: MascotLookRenderer.mix(MascotLookRenderer.ink, targetEyes?.color ?? MascotLookRenderer.ink,
                                                                    max(h[.tint], 0)), glow: false)
        let ink = color(lookEyes?.color ?? MascotLookRenderer.ink)

        var body = context
        body.translateBy(x: x, y: y)
        body.scaleBy(x: sx, y: sy)
        // 格子特效只畫格子（格子之間要看得到瀏海的黑色），過場中先畫漸變的球
        if look == nil || look?.style == .solid || h[.tint] < 0.99 { sphere(0, 0, R, in: &body) }
        if let look, look.style != .solid, h[.tint] > 0.01 {
            // 外觀的身體；過場時從白色漸變過去
            let face = MascotLookRenderer.Face(yaw: yaw, pitch: pitch, eye: hero.eye,
                                               pillOpen: eyes == .pill ? h[.open] * (1 - dash) : nil)
            let t = h[.tint]
            body.withCGContext { cg in
                if t < 0.99 {
                    cg.setAlpha(t)
                    cg.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                MascotLookRenderer.drawBody(look, radius: R, face: face, time: frame.effectTime, in: cg)
                if t < 0.99 { cg.endTransparencyLayer() }
            }
        }

        // 臉：依 yaw／pitch 投影到球面
        let cr = cos(roll), sr = sin(roll)
        func project(_ ye: Double, _ pe: Double) -> (x: Double, y: Double, a: Double, fx: Double, fy: Double)? {
            let cz = cos(ye) * cos(pe)
            guard cz > 0.05 else { return nil }
            let ex = sin(ye) * cos(pe) * R * sx, ey = -sin(pe) * R * sy
            return (x + ex * cr - ey * sr, y + ex * sr + ey * cr, min(max((cz - 0.05) / 0.25, 0), 1),
                    max(0.2, abs(cos(ye))), max(0.2, cos(pe)))
        }
        let blush = max(h[.blush], look?.blush == true ? 0.9 * h[.tint] : 0)
        if blush > 0.01 {
            for s in [-1.0, 1.0] {
                guard let p = project(yaw + s * 0.52, pitch - 0.32) else { continue }
                var g = context
                g.opacity = 0.55 * blush * p.a
                g.translateBy(x: p.x, y: p.y)
                g.rotate(by: .radians(roll))
                let rx = R * 0.17 * p.fx, ry = R * 0.09
                g.fill(Path(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry)), with: .color(Color(red: 1, green: 0.47, blue: 0.59)))
            }
        }
        if showsMood, frame.mood.brow != .none {
            let b = hero.brow
            let tilt = switch frame.mood.brow {
            case .worried: b.worriedTilt
            case .sad: b.sadTilt
            default: 0.0
            }
            let lift = frame.mood.brow == .raised ? 0.1 : 0
            for s in [-1.0, 1.0] {
                guard let p = project(yaw + s * b.yaw, pitch + hero.eye.pitch + b.pitch + lift) else { continue }
                var g = context
                g.opacity = p.a
                g.translateBy(x: p.x, y: p.y)
                g.rotate(by: .radians(roll + s * tilt))
                let w = R * b.width * p.fx
                var path = Path()
                path.move(to: CGPoint(x: -w / 2, y: 0))
                path.addLine(to: CGPoint(x: w / 2, y: 0))
                g.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: R * b.thickness, lineCap: .round))
            }
        }
        for s in [-1.0, 1.0] where lookEyes != nil {
            guard let p = project(yaw + s * hero.eye.yaw, pitch + hero.eye.pitch) else { continue }
            var g = context
            g.opacity = p.a
            // ASCII、線框、霓虹的眼睛會發光
            if lookEyes?.glow == true { g.addFilter(.shadow(color: ink, radius: R * 0.15)) }
            g.translateBy(x: p.x, y: p.y)
            g.rotate(by: .radians(roll))
            let round = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            switch eyes {
            case .pill:
                let w = R * hero.eye.width * p.fx * (1 + 0.55 * dash)
                let hh = (R * hero.eye.height * h[.open] * (1 - dash) + R * 0.13 * dash) * p.fy
                let height = max(hh, R * 0.1)
                g.translateBy(x: 0, y: dash * R * 0.1)
                g.fill(Path(roundedRect: CGRect(x: -w / 2, y: -height / 2, width: w, height: height),
                            cornerRadius: min(w, height) / 2), with: .color(ink))
            case .happy:
                let w = R * 0.16 * p.fx
                var path = Path()
                path.move(to: CGPoint(x: -w, y: R * 0.06))
                path.addQuadCurve(to: CGPoint(x: w, y: R * 0.06), control: CGPoint(x: 0, y: -R * 0.2))
                var style = round; style.lineWidth = R * 0.12
                g.stroke(path, with: .color(ink), style: style)
            case .dot:
                // 表情（擔心、驚訝）的小圓點比嚇到時大一點，迷你角色上也看得到
                let k = showsMood ? 0.13 : 0.1
                g.fill(Path(ellipseIn: CGRect(x: -R * k * p.fx, y: -R * k * p.fy, width: 2 * R * k * p.fx, height: 2 * R * k * p.fy)),
                       with: .color(ink))
            case .xx:
                let w = R * 0.12 * p.fx
                var path = Path()
                path.move(to: CGPoint(x: -s * w, y: -R * 0.13))
                path.addLine(to: CGPoint(x: s * w, y: 0))
                path.addLine(to: CGPoint(x: -s * w, y: R * 0.13))
                var style = round; style.lineWidth = R * 0.1
                g.stroke(path, with: .color(ink), style: style)
            case .cross:
                let w = R * 0.11 * p.fx, hh = R * 0.11 * p.fy
                var path = Path()
                path.move(to: CGPoint(x: -w, y: -hh))
                path.addLine(to: CGPoint(x: w, y: hh))
                path.move(to: CGPoint(x: -w, y: hh))
                path.addLine(to: CGPoint(x: w, y: -hh))
                var style = round; style.lineWidth = R * 0.085
                g.stroke(path, with: .color(ink), style: style)
            case .spiral:
                g.rotate(by: .radians(now / 110 * s))
                var path = Path()
                var t = 0.0
                while t < 9.4 {
                    let r = R * (0.015 + t * 0.021)
                    let point = CGPoint(x: r * cos(t) * p.fx, y: r * sin(t))
                    if t == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    t += 0.25
                }
                var style = round; style.lineWidth = R * 0.065
                g.stroke(path, with: .color(ink), style: style)
            }
        }

        // 工作中的鍵盤
        if h[.kb] > 0.01 {
            let kx = x, ky = y + R * 1.02 * sy, kw = R * 1.75, kh = R * 0.27
            var g = context
            g.opacity = h[.kb]
            g.fill(Path(roundedRect: CGRect(x: kx - kw / 2, y: ky - kh / 2, width: kw, height: kh), cornerRadius: kh / 2),
                   with: .color(Color(red: 0x2b / 255, green: 0x2b / 255, blue: 0x33 / 255)))
            let shine = CGRect(x: kx - kw * 0.45, y: ky - kh * 0.36 - kh * 0.06, width: kw * 0.9, height: kh * 0.12)
            g.fill(Path(roundedRect: shine, cornerRadius: kh * 0.06), with: .color(.white.opacity(0.16)))
            for i in 0..<7 {
                let on = sin(now / 62 + Double(i) * 1.7) > 0.75
                let rect = CGRect(x: kx - kw * 0.36 + Double(i) * kw * 0.12, y: ky - kh * 0.05, width: kw * 0.07, height: kh * 0.22)
                g.fill(Path(rect), with: .color(on ? color(look?.glow ?? frame.character.tint(config.palette).glow, 0.95) : .white.opacity(0.25)))
            }
        }

        for p in hands where p.z >= 0 { drawHand(p, in: &context) }

        // 生病：頭的右上方冒一滴冷汗（形狀，不只靠顏色）
        if showsMood, frame.mood.sweat, R > 4 {
            let cx = x + R * 0.8 * sx, cy = y - R * 0.42 * sy, s = R * 0.13
            var drop = Path()
            drop.move(to: CGPoint(x: cx, y: cy - s * 1.6))
            drop.addQuadCurve(to: CGPoint(x: cx + s, y: cy + s * 0.2), control: CGPoint(x: cx + s * 0.9, y: cy - s * 0.6))
            drop.addArc(center: CGPoint(x: cx, y: cy + s * 0.2), radius: s, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
            drop.addQuadCurve(to: CGPoint(x: cx, y: cy - s * 1.6), control: CGPoint(x: cx - s * 0.9, y: cy - s * 0.6))
            context.fill(drop, with: .color(Color(red: 0.62, green: 0.82, blue: 1)))
        }
        return (x, y, R)
    }

    // MARK: - 特效

    private func drawEffects(_ frame: MascotFrame, placed: (x: Double, y: Double, r: Double), in context: inout GraphicsContext) {
        let (x, y, R) = placed
        guard R >= 2 else { return }
        let now = Double(frame.time)
        if frame.eyes == .spiral, R > 5 {
            for i in 0..<3 {
                let a = now / 260 + Double(i) * 2.094
                drawStar(at: CGPoint(x: x + cos(a) * R * 0.95, y: y - R * 1.15 + sin(a) * R * 0.22), size: R * 0.15, in: &context)
            }
        }
        if let lit = frame.thinkingDots {
            // 思考泡泡：右上方三個小點依序亮起（參考頁的收合座標 R = 9 時間距 3.3、半徑 1.15）；
            // 亮的用角色的淺色（特效外觀用主色），暗的用半透明白
            let on = color(thinkingColor(frame))
            for i in 0..<3 {
                let r = R * 0.128
                let center = CGPoint(x: x + R * 0.95 + Double(i) * R * 0.367, y: y - R * 0.95)
                context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                             with: .color(i < lit ? on : Color.white.opacity(0.22)))
            }
        }
        // z 用三段線畫（每格排版文字太花 CPU，睡著時一直在重畫）
        let zColor = Color(red: 0.85, green: 0.85, blue: 0.89)
        if frame.dozing {
            var g = context
            let rise = frame.dozeRise ?? 0
            // 飄起時淡入淡出；靜止時停在原處
            g.opacity = frame.dozeRise.map { sin($0 * .pi) * 0.85 } ?? 0.85
            // 收合的瀏海很矮：只往右上飄一小段，不會跑出瀏海
            drawZ(at: CGPoint(x: x + R * (0.95 + rise * 0.4), y: y - R * (0.45 + rise * 0.4)), size: max(R * 0.55, 5), in: &g,
                  color: zColor)
        }
        if frame.sleeping {
            for i in 0..<3 {
                let u = (now / 1000 + Double(i) * 0.8).truncatingRemainder(dividingBy: 2.4) / 2.4
                var g = context
                g.opacity = sin(u * .pi) * 0.85
                drawZ(at: CGPoint(x: x + R * 0.75 + u * R * 0.5, y: y - R * 0.5 - u * R), size: R * (0.24 + Double(i) * 0.075),
                      in: &g, color: zColor)
            }
        }
        for effect in frame.effects {
            guard let u = effect.progress(at: frame.time) else { continue }
            switch effect.kind {
            case .ring(let level):
                let r = R * (1.1 + MascotEase.out(u) * 1.9)
                context.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                               with: .color(color(statusColor(Double(level)), (1 - u) * 0.9)), lineWidth: 2.4 * (1 - u) + 0.4)
            case .heart:
                drawHeart(at: CGPoint(x: x + R * 0.95, y: y - R * 0.7 - u * R), size: R * 0.22 * (0.6 + 0.4 * min(1, u * 4)),
                          alpha: 1 - u, in: &context)
            case .bang:
                var g = context
                g.opacity = u < 0.8 ? 1 : (1 - u) / 0.2
                let k = min(1, u * 6)
                let yellow = Color(red: 1, green: 0xD2 / 255, blue: 0x5E / 255)
                g.draw(Text("!").font(.system(size: R * 0.62, weight: .semibold)).foregroundColor(yellow),
                       at: CGPoint(x: x + R * 0.85, y: y - R * 0.7 - k * 4), anchor: .bottomLeading)
                g.draw(Text("!").font(.system(size: R * 0.45, weight: .semibold)).foregroundColor(yellow),
                       at: CGPoint(x: x + R * 1.15, y: y - R * 0.92 - k * 4), anchor: .bottomLeading)
            }
        }
    }

    /// 「z」：左下角在 `origin`，高 `size`
    private func drawZ(at origin: CGPoint, size s: Double, in context: inout GraphicsContext, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: origin.x, y: origin.y - s))
        path.addLine(to: CGPoint(x: origin.x + s * 0.8, y: origin.y - s))
        path.addLine(to: CGPoint(x: origin.x, y: origin.y))
        path.addLine(to: CGPoint(x: origin.x + s * 0.8, y: origin.y))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(s * 0.17, 0.9), lineCap: .round, lineJoin: .round))
    }

    private func drawStar(at c: CGPoint, size s: Double, in context: inout GraphicsContext) {
        var path = Path()
        for i in 0..<10 {
            let r = i % 2 == 1 ? s * 0.45 : s, a = Double(i) * .pi / 5 - .pi / 2
            let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        context.fill(path, with: .color(Color(red: 1, green: 0xD2 / 255, blue: 0x5E / 255)))
    }

    private func drawHeart(at c: CGPoint, size s: Double, alpha: Double, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y + s * 0.9))
        path.addCurve(to: CGPoint(x: c.x, y: c.y - s * 0.35), control1: CGPoint(x: c.x - s * 1.4, y: c.y),
                      control2: CGPoint(x: c.x - s * 0.9, y: c.y - s * 1.1))
        path.addCurve(to: CGPoint(x: c.x, y: c.y + s * 0.9), control1: CGPoint(x: c.x + s * 0.9, y: c.y - s * 1.1),
                      control2: CGPoint(x: c.x + s * 1.4, y: c.y))
        var g = context
        g.opacity = alpha
        g.fill(path, with: .color(Color(red: 1, green: 0x6b / 255, blue: 0x8a / 255)))
    }
}
