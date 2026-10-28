import CoreGraphics
import CoreText
import Foundation
import UsageKit

/// 角色外觀的身體畫法（ADR-0021；數值同配色挑選頁的 body、fxGrid、fxWire、fxNeon）。
/// 用 CoreGraphics 畫，瀏海的 Canvas（`withCGContext`）、設定頁預覽與選單列圖示共用。
/// 座標：身體中心在原點、y 往下（呼叫端負責平移與縮放）。
enum MascotLookRenderer {
    /// 臉的位置（身體自己的座標，不含翻滾）：格子特效要知道眼睛落在哪些格子
    struct Face {
        var yaw: Double
        var pitch: Double
        var eye: MascotConfig.Hero.Eye
        /// 膠囊眼睛張開的程度（0…1，已扣掉眨眼）；表情不是膠囊時 nil（眼睛另外畫在上面）
        var pillOpen: Double?
    }

    /// 畫完身體後，呼叫端還要畫的眼睛（表情、眉毛也用這個顏色）
    struct Eyes: Equatable {
        var color: [Double]
        /// 發光（ASCII、線框、霓虹）
        var glow: Bool
    }

    static let ink: [Double] = [0x12, 0x12, 0x12]

    /// 迷你角色（收合時 R≈9）用格子少的畫法
    static func isMini(_ radius: Double) -> Bool { radius < 12 }

    /// 這個外觀要另外畫的眼睛；nil 表示身體已經畫了（LED 的膠囊眼是不亮的燈、像素的膠囊眼對齊格子）
    static func eyes(for look: MascotLook?, radius: Double, pill: Bool) -> Eyes? {
        guard let look else { return Eyes(color: ink, glow: false) }
        switch look.style {
        case .solid, .linear: return Eyes(color: look.eye ?? ink, glow: false)
        case .ascii: return Eyes(color: mix(look.color ?? ink, [255, 255, 255], 0.55), glow: true)
        case .wire: return Eyes(color: [0xEA, 0xFD, 0xFF], glow: true)
        case .neon: return Eyes(color: look.color ?? ink, glow: true)
        // 大的 LED 眼睛是不亮的燈；迷你時格子太粗，另外畫暗色眼睛。表情（小圓點、×、眉毛）落在格子之間的黑縫，
        // 用暗琥珀才看得到（Fable F-07）
        case .led:
            if pill { return isMini(radius) ? Eyes(color: [0x16, 0x0C, 0x02], glow: false) : nil }
            return Eyes(color: mix([20, 10, 0], look.color ?? ink, 0.35), glow: false)
        case .pixel: return pill ? nil : Eyes(color: [0x11, 0x11, 0x14], glow: false)
        }
    }

    /// 特效重複一輪的長度（毫秒）：收合時預先畫好一輪、交給 Core Animation 循環播放（`MascotEffectLoop`）。
    /// 長度取特效本身週期的整數倍、約 3 秒，接回開頭時看不出斷點。不會動的外觀是 nil
    static func loopDuration(_ look: MascotLook, radius R: Double) -> Double? {
        switch look.style {
        case .solid, .linear, .pixel: return nil
        // 掃描光每 2.6R／(1/14) 毫秒掃過一次
        case .led:
            let scan = 2.6 * R * 14
            return scan * max(1, (3000 / scan).rounded())
        // 呼吸 sin(t/480)
        case .neon: return 2 * .pi * 480
        // 經線每轉 π／經線數就回到同樣的樣子
        case .wire: return 2600 * .pi / Double(isMini(R) ? 3 : 6)
        // 每 110 毫秒換一次跳字，取 27 次
        case .ascii: return 110 * 27
        }
    }

    /// 身體（不含光暈、手與另外畫的眼睛）。`time` 是特效的時間（毫秒）；nil 時畫靜態的一格（收合閒置、動畫簡單或關閉）。
    /// `solid` 由呼叫端用三階漸層畫（和服務色同一套，過場時從白色漸變）。
    static func drawBody(_ look: MascotLook, radius R: Double, face: Face, time: Int?, in cg: CGContext) {
        switch look.style {
        case .solid: break
        case .linear: drawLinear(look, radius: R, in: cg)
        case .led, .pixel, .ascii: drawGrid(look, radius: R, face: face, time: time, in: cg)
        case .wire: drawWire(look, radius: R, face: face, time: time, in: cg)
        case .neon: drawNeon(look, radius: R, time: time, in: cg)
        }
    }

    /// 手（半徑 `r`，中心 `center`）：線框、霓虹是發光的圓圈；直線漸層照身體；其他特效用主色的三階
    static func drawHand(_ look: MascotLook, center: CGPoint, radius r: Double, in cg: CGContext) -> Bool {
        switch look.style {
        case .neon, .wire:
            let color = cgColor(look.color ?? ink)
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: r * 0.9, color: color)
            cg.setStrokeColor(color)
            cg.setLineWidth(max(1, r * 0.2))
            cg.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            cg.restoreGState()
            return true
        case .linear:
            cg.saveGState()
            cg.translateBy(x: center.x, y: center.y)
            drawLinear(look, radius: r, in: cg)
            cg.restoreGState()
            return true
        default:
            return false
        }
    }

    // MARK: - 直線漸層

    private static func drawLinear(_ look: MascotLook, radius R: Double, in cg: CGContext) {
        guard let stops = look.stops, stops.count >= 2 else { return }
        cg.saveGState()
        cg.addEllipse(in: CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R))
        cg.clip()
        let a = (look.angle ?? 135) * .pi / 180
        let dx = cos(a) * R, dy = sin(a) * R
        let locations = stops.indices.map { CGFloat($0) / CGFloat(stops.count - 1) }
        if let g = gradient(stops.map { cgColor($0) }, locations) {
            cg.drawLinearGradient(g, start: CGPoint(x: -dx, y: -dy), end: CGPoint(x: dx, y: dy),
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        shadeOver(radius: R, strength: 1, highlight: 0.55, in: cg)
        cg.restoreGState()
    }

    /// 球面的高光與陰影（疊在平塗或漸層上）
    private static func shadeOver(radius R: Double, strength k: Double, highlight: Double, in cg: CGContext) {
        let hc = CGPoint(x: -0.38 * R, y: -0.46 * R)
        if let g = gradient([CGColor(srgbRed: 1, green: 1, blue: 1, alpha: highlight * k), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)], [0, 1]) {
            cg.drawRadialGradient(g, startCenter: hc, startRadius: R * 0.04, endCenter: hc, endRadius: R * 0.95,
                                  options: [.drawsBeforeStartLocation])
        }
        let sc = CGPoint(x: -0.08 * R, y: -0.08 * R)
        if let g = gradient([CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4 * k)], [0, 1]) {
            cg.drawRadialGradient(g, startCenter: sc, startRadius: R * 0.5, endCenter: sc, endRadius: R * 1.22,
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: - 格子特效（LED、像素、ASCII）

    private static let glyphs = Array(".:-=+*#%@")
    private static let miniGlyphs = Array(".:+*")

    private static func drawGrid(_ look: MascotLook, radius R: Double, face: Face, time: Int?, in cg: CGContext) {
        guard look.color != nil else { return }
        let mini = isMini(R)
        let cell: Double = switch (look.style, mini) {
        case (.ascii, true): 2 * R / 5.6
        case (.led, true): 2 * R / 7
        case (_, true): 2 * R / 9
        case (.ascii, false): max(4, R / 6.5)
        default: max(3, R / 8.5)
        }
        let n = Int((2.1 * R / cell).rounded(.up)) | 1
        let cx = Double(n) / 2
        let frame = time.map { $0 / 110 }
        let font = look.style == .ascii ? GlyphFont.shared(size: mini ? cell * 1.35 : cell * 1.3) : nil
        let set = mini ? miniGlyphs : glyphs

        // 每格的亮度與顏色只和外觀、大小、視線、眼睛有關：快取起來，每一格特效只重畫（Fable F-06，收合工作中的 CPU）
        for c in GridCells.cells(look: look, radius: R, cell: cell, n: n, face: face, glyphCount: set.count) {
            switch look.style {
            case .ascii:
                guard let font else { continue }
                var index = c.index
                if let frame {
                    let h = hash(Double(c.i), Double(c.j), Double(frame))
                    if h < 0.07 { index += h < 0.035 ? 1 : -1 }
                }
                index = min(max(index, 0), set.count - 1)
                cg.setFillColor(c.color)
                font.fill(set[index], at: CGPoint(x: c.x, y: c.y), in: cg)
            case .led:
                cg.setFillColor(c.color)
                let d = cell * (mini ? 0.4 : 0.38)
                cg.fillEllipse(in: CGRect(x: c.x - d, y: c.y - d, width: 2 * d, height: 2 * d))
            default:
                cg.setFillColor(c.color)
                cg.fill(CGRect(x: c.x - cell / 2, y: c.y - cell / 2, width: cell + 0.6, height: cell + 0.6))
            }
        }

        if look.style == .pixel, let open = face.pillOpen {
            // 像素的眼睛對齊格子、實心
            cg.setFillColor(cgColor([0x11, 0x11, 0x14]))
            for s in [-1.0, 1.0] {
                guard let q = project(face.yaw + s * face.eye.yaw, face.pitch + face.eye.pitch, R) else { continue }
                let gi = (q.x / cell + cx - 0.5).rounded(), gj = (q.y / cell + cx - 0.5).rounded()
                let eh = open > 0.5 ? (mini ? 2 : max(2, (R * face.eye.height / cell).rounded())) : 1
                let ew = mini ? 1 : max(1, (R * face.eye.width / cell).rounded())
                cg.fill(CGRect(x: (gi - cx) * cell - (ew - 1) * cell / 2, y: (gj - cx - (eh - 1) / 2) * cell,
                               width: ew * cell + 0.6, height: eh * cell + 0.6))
            }
        }

        if look.style == .led, let time {
            // 一道往下掃的光
            let by = -R + (Double(time) / 14).truncatingRemainder(dividingBy: 2.6 * R)
            cg.saveGState()
            cg.addEllipse(in: CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R))
            cg.clip()
            if let g = gradient([CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)], [0, 1]) {
                cg.clip(to: CGRect(x: -R, y: by - R * 0.2, width: 2 * R, height: R * 0.2))
                cg.drawLinearGradient(g, start: CGPoint(x: 0, y: by - R * 0.2), end: CGPoint(x: 0, y: by), options: [])
            }
            cg.restoreGState()
        }
    }

    /// 膠囊眼睛在身體座標中的範圍（同規格頁的 eyes()：寬 0.27R、高 0.52R × 張開，至少 0.08R）
    fileprivate struct Pill {
        var x: Double, y: Double, w: Double, h: Double
        func contains(x px: Double, y py: Double) -> Bool {
            let r = min(w, h) / 2
            let dx = max(abs(px - x) - (w / 2 - r), 0), dy = max(abs(py - y) - (h / 2 - r), 0)
            return dx * dx + dy * dy <= r * r
        }
    }

    fileprivate static func pillRects(face: Face, radius R: Double, open: Double) -> [Pill] {
        [-1.0, 1.0].compactMap { s in
            project(face.yaw + s * face.eye.yaw, face.pitch + face.eye.pitch, R).map { q in
                Pill(x: q.x, y: q.y, w: R * face.eye.width * q.fx, h: max(R * face.eye.height * q.fy * open, R * 0.08))
            }
        }
    }

    private static func project(_ yaw: Double, _ pitch: Double, _ R: Double) -> (x: Double, y: Double, fx: Double, fy: Double)? {
        let cz = cos(yaw) * cos(pitch)
        guard cz > 0.05 else { return nil }
        return (sin(yaw) * cos(pitch) * R, -sin(pitch) * R, max(0.2, abs(cos(yaw))), max(0.2, cos(pitch)))
    }

    /// 白→#C4C4C4→#505050 球面漸層在 (x, y) 的亮度（同規格頁畫在暫存畫布再取樣的 solidSphere；這裡直接解兩圓的錐形漸層）
    static func sphereLuminance(x: Double, y: Double, radius r: Double) -> Double {
        let c0x = -0.38 * r, c0y = -0.46 * r, r0 = 0.04 * r
        let dcx = 0.30 * r, dcy = 0.38 * r, dr = 1.18 * r
        let qx = x - c0x, qy = y - c0y
        // |q − t·dc|² = (r0 + t·dr)²
        let a = dcx * dcx + dcy * dcy - dr * dr
        let b = qx * dcx + qy * dcy + r0 * dr
        let c = qx * qx + qy * qy - r0 * r0
        let disc = b * b - a * c
        guard disc >= 0, a != 0 else { return 1 }
        let s = disc.squareRoot()
        let t = [(b + s) / a, (b - s) / a].filter { r0 + $0 * dr >= 0 }.max() ?? 0
        let u = min(max(t, 0), 1)
        let l0 = 1.0, l1 = 196.0 / 255, l2 = 80.0 / 255
        return u < 0.52 ? l0 + (l1 - l0) * u / 0.52 : l1 + (l2 - l1) * (u - 0.52) / 0.48
    }

    /// 規格頁的 hash（字元跳動用）
    static func hash(_ i: Double, _ j: Double, _ k: Double) -> Double {
        let s = sin(i * 12.9898 + j * 78.233 + k * 37.719) * 43758.5453
        return s - s.rounded(.down)
    }

    /// 格子特效每格算好的位置、亮度、顏色與字元（`drawGrid` 用）
    fileprivate struct GridCell {
        var i: Int, j: Int
        var x: Double, y: Double
        var color: CGColor
        /// ASCII 的字元（跳字前）
        var index: Int
    }

    fileprivate static func gridCell(_ look: MascotLook, i: Int, j: Int, x: Double, y: Double, lum: Double,
                                     glyphCount: Int) -> GridCell? {
        guard let color = look.color else { return nil }
        switch look.style {
        case .ascii:
            guard lum >= 0.18 else { return nil }
            let index = Int(((lum - 0.3) / 0.7 * Double(glyphCount - 1)).rounded())
            return GridCell(i: i, j: j, x: x, y: y, color: cgColor(color, 0.3 + 0.7 * lum), index: index)
        case .led:
            let c = lum < 0.18 ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07) : cgColor(mix([20, 10, 0], color, min(1, lum * 1.1)))
            return GridCell(i: i, j: j, x: x, y: y, color: c, index: 0)
        default:
            guard let tint = look.effectTint else { return nil }
            let c = lum < 0.18 ? tint.mid : lum > 0.82 ? tint.light : lum > 0.58 ? tint.mid : tint.shade
            return GridCell(i: i, j: j, x: x, y: y, color: cgColor(c), index: 0)
        }
    }

    // MARK: - 線框球、霓虹

    private static func drawWire(_ look: MascotLook, radius R: Double, face: Face, time: Int?, in cg: CGContext) {
        guard let color = look.color else { return }
        let mini = isMini(R)
        let full = CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R)
        cg.saveGState()
        cg.setFillColor(CGColor(srgbRed: 4 / 255, green: 14 / 255, blue: 30 / 255, alpha: 0.88))
        cg.fillEllipse(in: full)
        cg.setShadow(offset: .zero, blur: mini ? R * 0.5 : R * 0.12, color: cgColor(color))
        // 所有線條畫在同一層，發光只算一次（每條線各算一次陰影很花 CPU）
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.setLineWidth(max(1, R * 0.022))
        // 經線：慢慢轉，看滑鼠時跟著轉向
        let rot = Double(time ?? 0) / 2600 + face.yaw * 1.4
        let meridians = mini ? 3 : 6
        for k in 0..<meridians {
            let ph = rot + Double(k) * .pi / Double(meridians)
            let rx = max(0.5, abs(cos(ph)) * R)
            cg.setStrokeColor(cgColor(color, 0.25 + 0.45 * abs(sin(ph + .pi / 2))))
            cg.strokeEllipse(in: CGRect(x: -rx, y: -R, width: 2 * rx, height: 2 * R))
        }
        for l in mini ? [0.0] : [-60.0, -30, 0, 30, 60] {
            let la = l * .pi / 180 + face.pitch * 0.5
            let yy = R * sin(la), rx = R * cos(la)
            guard rx > 0 else { continue }
            cg.setStrokeColor(cgColor(color, 0.5))
            cg.strokeEllipse(in: CGRect(x: -rx, y: yy - rx * 0.2, width: 2 * rx, height: rx * 0.4))
        }
        cg.setStrokeColor(cgColor(color))
        cg.setLineWidth(max(1, R * 0.035))
        cg.strokeEllipse(in: full)
        cg.endTransparencyLayer()
        cg.restoreGState()
    }

    private static func drawNeon(_ look: MascotLook, radius R: Double, time: Int?, in cg: CGContext) {
        guard let color = look.color else { return }
        // 呼吸：靜態時是最亮的一格
        let pulse = time.map { 0.75 + 0.25 * sin(Double($0) / 480) } ?? 1
        let ring = CGRect(x: -R * 0.96, y: -R * 0.96, width: R * 1.92, height: R * 1.92)
        cg.saveGState()
        cg.setFillColor(CGColor(srgbRed: 0x0B / 255, green: 0x07 / 255, blue: 0x10 / 255, alpha: 1))
        cg.fillEllipse(in: CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R))
        cg.setShadow(offset: .zero, blur: R * 0.45 * pulse, color: cgColor(color))
        cg.setStrokeColor(cgColor(color))
        cg.setLineWidth(max(1.3, R * 0.07))
        cg.strokeEllipse(in: ring)
        cg.setShadow(offset: .zero, blur: 0, color: nil)
        cg.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6 * pulse))
        cg.setLineWidth(max(1, R * 0.018))
        cg.strokeEllipse(in: ring)
        cg.restoreGState()
    }

    // MARK: - 共用

    static func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
        zip(a, b).map { $0 + ($1 - $0) * t }
    }

    static func cgColor(_ c: [Double], _ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: alpha)
    }

    private static func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
    }
}

/// 格子特效的快取：同一個外觀、大小、視線與眼睛只算一次（瀏海收合時姿勢停住，特效每秒 12 格都是同一份）
private enum GridCells {
    private struct Key: Hashable {
        var look: String, radius: Double, cell: Double, yaw: Double, pitch: Double, open: Double?
    }

    nonisolated(unsafe) private static var cache: [Key: [MascotLookRenderer.GridCell]] = [:]
    private static let lock = NSLock()

    static func cells(look: MascotLook, radius R: Double, cell: Double, n: Int, face: MascotLookRenderer.Face,
                      glyphCount: Int) -> [MascotLookRenderer.GridCell] {
        let key = Key(look: look.id, radius: R, cell: cell, yaw: face.yaw, pitch: face.pitch, open: face.pillOpen)
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let r = R / cell, cx = Double(n) / 2
        let inside = r * r * (MascotLookRenderer.isMini(R) ? 0.9 : 0.97)
        let pill = face.pillOpen.map { MascotLookRenderer.pillRects(face: face, radius: R, open: $0) } ?? []
        var cells: [MascotLookRenderer.GridCell] = []
        for j in 0..<n {
            for i in 0..<n {
                let ddx = Double(i) + 0.5 - cx, ddy = Double(j) + 0.5 - cx
                guard ddx * ddx + ddy * ddy <= inside else { continue }
                let ox = ddx * cell, oy = ddy * cell
                let lum = pill.contains { $0.contains(x: ox, y: oy) } ? 0 : MascotLookRenderer.sphereLuminance(x: ox, y: oy, radius: R)
                if let c = MascotLookRenderer.gridCell(look, i: i, j: j, x: ox, y: oy, lum: lum, glyphCount: glyphCount) {
                    cells.append(c)
                }
            }
        }
        // 看滑鼠、眨眼時每格的鍵都不同：只留最近的一些
        if cache.count > 48 { cache.removeAll() }
        cache[key] = cells
        return cells
    }
}

/// ASCII 用的等寬粗體字形（CoreText 的字形外框，畫在 y 往下的座標；每個大小只建一次）
private final class GlyphFont: @unchecked Sendable {
    private let paths: [Character: (path: CGPath, advance: Double)]
    private let middle: Double

    private init(size: Double) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        var paths: [Character: (CGPath, Double)] = [:]
        for ch in ".:-=+*#%@" {
            var unichar = Array(String(ch).utf16)
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1) else { continue }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            paths[ch] = (CTFontCreatePathForGlyph(font, glyph, nil) ?? CGMutablePath(), advance.width)
        }
        self.paths = paths
        // textBaseline middle：基線放在中心往下約 x 高度的一半
        middle = CTFontGetXHeight(font) / 2 + 0.5
    }

    nonisolated(unsafe) private static var cache: [Int: GlyphFont] = [:]
    private static let lock = NSLock()

    /// 大小取到 0.1 pt
    static func shared(size: Double) -> GlyphFont {
        let key = Int((size * 10).rounded())
        lock.lock()
        defer { lock.unlock() }
        if let font = cache[key] { return font }
        let font = GlyphFont(size: Double(key) / 10)
        if cache.count > 32 { cache.removeAll() }
        cache[key] = font
        return font
    }

    func fill(_ ch: Character, at center: CGPoint, in cg: CGContext) {
        guard let glyph = paths[ch] else { return }
        cg.saveGState()
        cg.translateBy(x: center.x - glyph.advance / 2, y: center.y + middle)
        cg.scaleBy(x: 1, y: -1)
        cg.addPath(glyph.path)
        cg.fillPath()
        cg.restoreGState()
    }
}
