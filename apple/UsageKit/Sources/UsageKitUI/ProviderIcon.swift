// SwiftUI 只有 Apple 平台有；Linux CI 只編譯、測試 UsageKit
#if canImport(SwiftUI)

import SwiftUI
import UsageKit

/// 服務圖示（原創，不是官方 logo）。都定義在 24×24 的座標系，依框架大小等比縮放。
/// 圖示是單一 `Shape`，以目前的 foregroundStyle 填色（template）：
/// 套上服務識別色即為全彩，錶面單色／主題色模式下由系統替換顏色，鏤空處透出背景。
public struct ProviderIcon: View {
    let provider: String

    public init(_ provider: String) {
        self.provider = provider
    }

    public var body: some View {
        Group {
            switch provider {
            case "claude": ClaudeIconShape()
            case "codex": CodexIconShape()
            case "gemini": GeminiIconShape()
            default: Circle()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // 只有圖示時，VoiceOver 念服務名稱
        .accessibilityElement()
        .accessibilityLabel(ProviderInfo.displayName(provider))
    }
}

/// Claude：長短交錯的八芒星，實心加 0.7 寬、圓角接合的同色描邊（讓尖角在小尺寸下不會太細）。
public struct ClaudeIconShape: Shape {
    static let points: [CGPoint] = [
        (12.00, 1.00), (13.65, 8.03), (17.80, 6.20), (15.97, 10.35),
        (23.00, 12.00), (15.97, 13.65), (17.80, 17.80), (13.65, 15.97),
        (12.00, 23.00), (10.35, 15.97), (6.20, 17.80), (8.03, 13.65),
        (1.00, 12.00), (8.03, 10.35), (6.20, 6.20), (10.35, 8.03),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    static let unitPath: Path = {
        var star = Path()
        star.addLines(points)
        star.closeSubpath()
        let outline = star.strokedPath(StrokeStyle(lineWidth: 0.7, lineJoin: .round))
        return star.union(outline)
    }()

    public init() {}

    public func path(in rect: CGRect) -> Path {
        Self.unitPath.fitted(in: rect)
    }
}

/// Codex：六瓣圓雲（中心圓與 6 個外圓的聯集），中間以 `>_` 筆劃鏤空。
public struct CodexIconShape: Shape {
    static let centers: [CGPoint] = [
        (12.00, 5.00), (18.06, 8.50), (18.06, 15.50),
        (12.00, 19.00), (5.94, 15.50), (5.94, 8.50),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    static let unitPath: Path = {
        func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        let cloud = centers.reduce(circle(CGPoint(x: 12, y: 12), 8)) { $0.union(circle($1, 4)) }
        // M8 9 l3 3 -3 3 M12.6 15.2 h3.8
        var prompt = Path()
        prompt.move(to: CGPoint(x: 8, y: 9))
        prompt.addLine(to: CGPoint(x: 11, y: 12))
        prompt.addLine(to: CGPoint(x: 8, y: 15))
        prompt.move(to: CGPoint(x: 12.6, y: 15.2))
        prompt.addLine(to: CGPoint(x: 16.4, y: 15.2))
        let cutout = prompt.strokedPath(StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
        return cloud.subtracting(cutout)
    }()

    public init() {}

    public func path(in rect: CGRect) -> Path {
        Self.unitPath.fitted(in: rect)
    }
}

/// Gemini：原創的四芒星。四個尖端在上下左右，四邊是向內凹的二次曲線；控制點不在中心而往外 2.2，
/// 腰身比較飽滿（不是 Google Gemini 標誌那種收到中心的細腰與漸層）。實心加 0.7 寬、圓角接合的同色描邊，
/// 尖端在小尺寸下不會太細（同 Claude 八芒星）。
public struct GeminiIconShape: Shape {
    static let tips: [CGPoint] = [(12, 1), (23, 12), (12, 23), (1, 12)].map { CGPoint(x: $0.0, y: $0.1) }
    static let controls: [CGPoint] = [(14.2, 9.8), (14.2, 14.2), (9.8, 14.2), (9.8, 9.8)].map { CGPoint(x: $0.0, y: $0.1) }

    static let unitPath: Path = {
        var star = Path()
        star.move(to: tips[0])
        for i in 0..<4 {
            star.addQuadCurve(to: tips[(i + 1) % 4], control: controls[i])
        }
        star.closeSubpath()
        let outline = star.strokedPath(StrokeStyle(lineWidth: 0.7, lineJoin: .round))
        return star.union(outline)
    }()

    public init() {}

    public func path(in rect: CGRect) -> Path {
        Self.unitPath.fitted(in: rect)
    }
}

private extension Path {
    /// 把 24×24 座標系的路徑等比縮放並置中到 rect
    func fitted(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let dx = rect.midX - 12 * scale
        let dy = rect.midY - 12 * scale
        return applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

#endif
