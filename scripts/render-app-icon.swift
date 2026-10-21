// 產生 iOS 與 Mac 的 App 圖示 PNG。由 scripts/render-app-icon.sh 編譯執行，不要直接跑。
// 八芒星與雲朵直接用 UsageKitUI 的 ClaudeIconShape、CodexIconShape，和 App 內的服務圖示一致。
// 規格見 .claude/skills/ai-usage-monitor-design/SKILL.md 第 2 節「App 圖示」。

import AppKit
import SwiftUI
import UsageKitUI

/// 一種外觀的配色。座標都在 100×100 的畫布上。
struct IconStyle {
    let background: Color
    /// 左上三角形的顏色；nil 表示整片都是 background
    let topLeft: Color?
    let divider: Color
    let star: Color
    let cloud: Color
    let shadow: Bool

    static let normal = IconStyle(
        background: UsageColors.providerMark("codex"), topLeft: UsageColors.providerMark("claude"),
        divider: .white, star: .white, cloud: .white, shadow: true
    )
    static let dark = IconStyle(
        background: .black, topLeft: nil, divider: Color(hex: 0x2A2A2C),
        star: UsageColors.providerMark("claude"), cloud: UsageColors.providerMark("codex"), shadow: false
    )
    static let tinted = IconStyle(
        background: .black, topLeft: nil, divider: Color(hex: 0x3A3A3A),
        star: Color(hex: 0xE6E6E6), cloud: Color(hex: 0xA8A8A8), shadow: false
    )
}

/// 不含圓角的正方形圖示，邊長 side。
struct AppIconView: View {
    let style: IconStyle
    let side: CGFloat

    /// 100 畫布單位換算成點
    private var unit: CGFloat { side / 100 }

    /// 把 24×24 的服務圖示平移 (tx, ty)、放大 scale 倍（SVG 的 translate(tx,ty) scale(scale)）
    private func place(_ shape: some Shape, tx: CGFloat, ty: CGFloat, scale: CGFloat) -> Path {
        shape.path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
            .applying(CGAffineTransform(a: scale * unit, b: 0, c: 0, d: scale * unit, tx: tx * unit, ty: ty * unit))
    }

    var body: some View {
        ZStack {
            style.background
            if let topLeft = style.topLeft {
                Path { p in
                    p.addLines([.zero, CGPoint(x: side, y: 0), CGPoint(x: 0, y: side)])
                    p.closeSubpath()
                }
                .fill(topLeft)
            }
            Path { p in
                p.move(to: CGPoint(x: side, y: 0))
                p.addLine(to: CGPoint(x: 0, y: side))
            }
            .stroke(style.divider, lineWidth: 2.5 * unit)
            Group {
                place(ClaudeIconShape(), tx: 8, ty: 8, scale: 1.95).fill(style.star)
                // 鏤空的 >_ 透出底下的背景
                place(CodexIconShape(), tx: 48, ty: 48, scale: 1.85).fill(style.cloud)
            }
            .shadow(color: .black.opacity(style.shadow ? 0.28 : 0), radius: 1.6 * unit, x: 0, y: 1.5 * unit)
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

/// macOS 圖示：1024 畫布中 824×824 的圓角矩形（連續圓角，半徑約 22.5%），四周留白放陰影。
struct MacIconView: View {
    var body: some View {
        AppIconView(style: .normal, side: 824)
            .clipShape(RoundedRectangle(cornerRadius: 824 * 0.225, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 10)
            .frame(width: 1024, height: 1024)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

@MainActor
func writePNG(_ view: some View, pixels: CGFloat, opaque: Bool, to url: URL) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = pixels / 1024
    renderer.isOpaque = opaque
    guard let image = renderer.cgImage else { throw RenderError.render(url.lastPathComponent) }
    // iOS 的 1024 圖示不能有 alpha 通道：重畫到不含 alpha 的點陣圖
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info
    ) else { throw RenderError.render(url.lastPathComponent) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let flattened = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:])
    else { throw RenderError.render(url.lastPathComponent) }
    try data.write(to: url)
    print("wrote \(url.path)")
}

enum RenderError: Error {
    case render(String)
}

@main
struct RenderAppIcon {
    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let ios = root.appendingPathComponent("apple/iOSApp/AIUsageMonitor/Assets.xcassets/AppIcon.appiconset")
        let styles: [(String, IconStyle)] = [("AppIcon", .normal), ("AppIcon-Dark", .dark), ("AppIcon-Tinted", .tinted)]
        for (name, style) in styles {
            try writePNG(AppIconView(style: style, side: 1024), pixels: 1024, opaque: true,
                         to: ios.appendingPathComponent("\(name).png"))
        }

        let mac = root.appendingPathComponent("apple/MacMenuBar/AIUsageMenuBar/Assets.xcassets/AppIcon.appiconset")
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            try writePNG(MacIconView(), pixels: CGFloat(pixels), opaque: false,
                         to: mac.appendingPathComponent("AppIcon-\(pixels).png"))
        }
    }
}
