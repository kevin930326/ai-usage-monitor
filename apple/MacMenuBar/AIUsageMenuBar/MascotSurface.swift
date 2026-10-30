import AppKit
import CoreText
import os
import SwiftUI

/// 角色畫在哪裡：SwiftUI 的 `GraphicsContext`（瀏海畫布、截圖、設定頁預覽），或直接用 CoreGraphics
/// （看滑鼠時的角色圖層 `MascotHeroLayerView`：每一格不經過 SwiftUI，icons 第 4 部分）。
/// 和 `GraphicsContext` 一樣是值：複製一份再改透明度、位移、旋轉，不影響原本那份
protocol MascotSurface {
    var opacity: Double { get set }
    mutating func translateBy(x: CGFloat, y: CGFloat)
    mutating func scaleBy(x: CGFloat, y: CGFloat)
    mutating func rotate(by angle: Angle)
    /// 之後畫的東西加上發光（同 `GraphicsContext` 的 `.shadow` 濾鏡，沒有位移）
    mutating func addShadow(color: Color, radius: CGFloat)
    /// `withCGContext` 裡自己設的發光（`setShadow`）要乘上的倍率：CoreGraphics 的模糊以像素計
    var glowScale: Double { get }
    func fill(_ path: Path, color: Color)
    func stroke(_ path: Path, color: Color, style: StrokeStyle)
    func fillRadial(_ path: Path, gradient: Gradient, center: CGPoint, startRadius: CGFloat, endRadius: CGFloat)
    /// 驚嘆號之類的單一字：左下角在 `point`
    func drawMark(_ text: String, size: CGFloat, color: Color, at point: CGPoint)
    func withCGContext(content: (CGContext) throws -> Void) rethrows
}

extension GraphicsContext: MascotSurface {
    /// SwiftUI 會照畫面的倍率換算
    var glowScale: Double { 1 }

    mutating func addShadow(color: Color, radius: CGFloat) {
        addFilter(.shadow(color: color, radius: radius))
    }

    func fill(_ path: Path, color: Color) {
        fill(path, with: .color(color))
    }

    func stroke(_ path: Path, color: Color, style: StrokeStyle) {
        stroke(path, with: .color(color), style: style)
    }

    func fillRadial(_ path: Path, gradient: Gradient, center: CGPoint, startRadius: CGFloat, endRadius: CGFloat) {
        fill(path, with: .radialGradient(gradient, center: center, startRadius: startRadius, endRadius: endRadius))
    }

    func drawMark(_ text: String, size: CGFloat, color: Color, at point: CGPoint) {
        draw(Text(text).font(.system(size: size, weight: .semibold)).foregroundColor(color), at: point, anchor: .bottomLeading)
    }
}

/// CoreGraphics 版：座標同畫布（左上為原點、y 往下）。每次畫都先套上目前的位移、透明度與發光，畫完還原
struct MascotCGSurface: MascotSurface {
    let cg: CGContext
    var opacity = 1.0
    private var transform = CGAffineTransform.identity
    private var shadow: (color: CGColor, blur: CGFloat)?
    /// 一個點是幾個像素（Retina 是 2）
    let glowScale: Double

    init(_ cg: CGContext) {
        self.cg = cg
        glowScale = hypot(cg.ctm.a, cg.ctm.b)
    }

    mutating func translateBy(x: CGFloat, y: CGFloat) { transform = transform.translatedBy(x: x, y: y) }
    mutating func scaleBy(x: CGFloat, y: CGFloat) { transform = transform.scaledBy(x: x, y: y) }
    mutating func rotate(by angle: Angle) { transform = transform.rotated(by: angle.radians) }

    /// CoreGraphics 的模糊以像素計、不跟著座標縮放；SwiftUI 的 shadow 半徑約是它的一半（逐像素比對，`DebugHeroParity`）
    mutating func addShadow(color: Color, radius: CGFloat) {
        shadow = (Self.cgColor(color), radius * 2 * glowScale)
    }

    private func perform(_ body: (CGContext) -> Void) {
        cg.saveGState()
        cg.concatenate(transform)
        cg.setAlpha(opacity)
        if let shadow { cg.setShadow(offset: .zero, blur: shadow.blur, color: shadow.color) }
        body(cg)
        cg.restoreGState()
    }

    func fill(_ path: Path, color: Color) {
        perform { cg in
            cg.addPath(path.cgPath)
            cg.setFillColor(Self.cgColor(color))
            cg.fillPath()
        }
    }

    func stroke(_ path: Path, color: Color, style: StrokeStyle) {
        perform { cg in
            cg.addPath(path.cgPath)
            cg.setStrokeColor(Self.cgColor(color))
            cg.setLineWidth(style.lineWidth)
            cg.setLineCap(style.lineCap)
            cg.setLineJoin(style.lineJoin)
            cg.strokePath()
        }
    }

    func fillRadial(_ path: Path, gradient: Gradient, center: CGPoint, startRadius: CGFloat, endRadius: CGFloat) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: gradient.stops.map { Self.cgColor($0.color) } as CFArray,
                                 locations: gradient.stops.map { CGFloat($0.location) }) else { return }
        perform { cg in
            cg.addPath(path.cgPath)
            cg.clip()
            cg.drawRadialGradient(g, startCenter: center, startRadius: startRadius, endCenter: center, endRadius: endRadius,
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    func drawMark(_ text: String, size: CGFloat, color: Color, at point: CGPoint) {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: Self.cgColor(color)) ?? .white,
        ]))
        perform { cg in
            // 畫布的 y 往下：字要再翻一次才不會倒過來；基線在左下角往上一個 descent
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            cg.textPosition = CGPoint(x: point.x, y: point.y + font.descender)
            CTLineDraw(line, cg)
        }
    }

    func withCGContext(content: (CGContext) throws -> Void) rethrows {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.concatenate(transform)
        cg.setAlpha(opacity)
        if let shadow { cg.setShadow(offset: .zero, blur: shadow.blur, color: shadow.color) }
        try content(cg)
    }

    /// `NSColor(Color)` 每次都要查色彩描述檔，看滑鼠時每格每一筆都轉一次很貴（CI 取樣，icons 第 4 部分第三版）：轉過的留著。
    /// 透明度會跟著動畫變，所以設上限、滿了整個清掉
    private static let colors = OSAllocatedUnfairLock(initialState: [Color: CGColor]())

    static func cgColor(_ color: Color) -> CGColor {
        if let cached = colors.withLock({ $0[color] }) { return cached }
        let converted = NSColor(color).cgColor
        colors.withLock {
            if $0.count >= 512 { $0.removeAll(keepingCapacity: true) }
            $0[color] = converted
        }
        return converted
    }
}
