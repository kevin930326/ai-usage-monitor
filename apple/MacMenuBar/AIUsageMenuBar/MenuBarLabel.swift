import AppKit
import SwiftUI
import UsageKit
import UsageKitUI

/// 選單列圖示（FR-33、ADR-0008 第 1 節）：預設雙圓環，另有橫條、只有 %、圓環＋%。
/// 四種狀態不只靠顏色：太快有提示色小點、剩 < 20% 外圈轉紅、過期整個轉灰且外圈改為虛線；
/// 「只有 %」樣式以符號區分（↑ 太快、! 剩 < 20%、– 過期）。
/// 沒有任何動畫；`store.now` 每分鐘更新一次，圖示只在內容改變時重畫（`MenuBarIcon.image` 有快取）。
struct MenuBarLabel: View {
    let store: UsageStore
    let settings: PanelSettings

    var body: some View {
        if let snapshot = store.snapshot, let item = snapshot.window(for: settings.iconWindow, at: store.now) {
            let content = MenuBarIconContent(item: item, stale: snapshot.isStale(now: store.now), now: store.now,
                                             isLeast: settings.iconWindow == .automatic)
            MenuBarIconView(content: content, style: settings.iconStyle)
        } else {
            Image(systemName: "gauge.with.dots.needle.0percent")
        }
    }
}

/// 畫圖示需要的值，四捨五入到看得出差別的精度，作為快取的鍵。
struct MenuBarIconContent: Hashable {
    var provider: String
    var remainingPct: Int
    /// 距離重置的剩餘時間比例，以 2% 為單位（nil＝額度長度不明，不畫內圈）
    var timeRemaining: Int?
    var state: MenuBarState
    var label: String
    /// 顯示的是「自動」挑出的剩餘最少的額度（VoiceOver 要說出來）
    var isLeast: Bool

    init(provider: String, remainingPct: Int, timeRemaining: Int?, state: MenuBarState, label: String, isLeast: Bool = true) {
        self.provider = provider
        self.remainingPct = remainingPct
        self.timeRemaining = timeRemaining
        self.state = state
        self.label = label
        self.isLeast = isLeast
    }

    init(item: ProviderWindow, stale: Bool, now: Date, isLeast: Bool) {
        self.isLeast = isLeast
        provider = item.provider
        remainingPct = Int(item.window.effectiveRemainingPct(at: now).rounded())
        timeRemaining = item.window.timeRemainingFraction(at: now).map { Int(($0 * 50).rounded()) * 2 }
        state = MenuBarState(window: item.window, stale: stale, now: now)
        label = item.displayName
    }

    var accessibilityText: String {
        // 「剩餘最少的額度：Claude 每週，剩 67%」；指定額度時不加前綴
        var text = "\(isLeast ? "剩餘最少的額度：" : "")\(label)，剩 \(remainingPct)%"
        switch state {
        case .tooFast: text += "，用得較快"
        case .critical: text += "，剩不到 20%"
        case .stale: text += "，資料已過期"
        case .normal: break
        }
        return text
    }
}

struct MenuBarIconView: View {
    let content: MenuBarIconContent
    let style: MenuBarIconStyle

    var body: some View {
        HStack(spacing: 3) {
            switch style {
            case .dualRing, .bar:
                Image(nsImage: MenuBarIcon.image(content, style: style))
            case .ringPercent:
                Image(nsImage: MenuBarIcon.image(content, style: style))
                Text("\(content.remainingPct)%").monospacedDigit()
            case .percent:
                Text("\(content.remainingPct)%").monospacedDigit()
                if content.state != .normal {
                    Image(nsImage: MenuBarIcon.image(content, style: style))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityText)
    }
}

/// 選單列會把 SF Symbol 與文字轉成單色，有顏色的部分只能用非範本（non-template）的點陣圖。
/// 顏色在繪製時才取（NSColor 會依選單列的深淺色解析），同樣的內容只畫一次。
@MainActor
enum MenuBarIcon {
    private static var cache: [Key: NSImage] = [:]

    private struct Key: Hashable {
        var content: MenuBarIconContent
        var style: MenuBarIconStyle
    }

    static func image(_ content: MenuBarIconContent, style: MenuBarIconStyle) -> NSImage {
        let key = Key(content: content, style: style)
        if let cached = cache[key] { return cached }
        if cache.count > 64 { cache.removeAll() }
        let image = draw(content, style: style)
        cache[key] = image
        return image
    }

    private static func draw(_ c: MenuBarIconContent, style: MenuBarIconStyle) -> NSImage {
        let size: NSSize = switch style {
        case .bar: NSSize(width: 22, height: 16)
        case .percent: NSSize(width: 8, height: 16)
        case .dualRing, .ringPercent: NSSize(width: 18, height: 16)
        }
        let notice = NSColor(UsageColors.notice)
        let main: NSColor = switch c.state {
        // 外圈與進度條同規則（FR-16）：過期灰、剩 < 20% 紅、其他為服務識別色
        case .stale: .systemGray
        case .critical: NSColor(UsageColors.critical)
        case .normal, .tooFast: NSColor(UsageColors.provider(c.provider))
        }
        let image = NSImage(size: size, flipped: false) { rect in
            switch style {
            case .dualRing, .ringPercent:
                let center = NSPoint(x: 8, y: rect.midY)
                ring(center: center, radius: 6.6, width: 2.4, fraction: Double(c.remainingPct) / 100, color: main,
                     dashed: c.state == .stale)
                if style == .dualRing, let time = c.timeRemaining {
                    ring(center: center, radius: 3.2, width: 1.8, fraction: Double(time) / 100,
                         color: c.state == .stale ? .tertiaryLabelColor : .secondaryLabelColor)
                }
                if c.state == .tooFast { dot(at: NSPoint(x: 15, y: rect.maxY - 3.5), color: notice) }
            case .bar:
                let track = NSRect(x: 1, y: rect.midY - 2.5, width: 18, height: 5)
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
                var fill = track
                fill.size.width = max(track.width * CGFloat(c.remainingPct) / 100, c.remainingPct > 0 ? 2 : 0)
                main.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
                if c.state == .stale {
                    // 過期：除了轉灰，再加虛線外框（不只靠顏色）
                    let outline = NSBezierPath(roundedRect: track.insetBy(dx: -1, dy: -1), xRadius: 3.5, yRadius: 3.5)
                    outline.lineWidth = 1
                    outline.setLineDash([1.6, 1.4], count: 2, phase: 0)
                    NSColor.systemGray.setStroke()
                    outline.stroke()
                }
                if c.state == .tooFast { dot(at: NSPoint(x: 19.5, y: rect.maxY - 3.5), color: notice) }
            case .percent:
                // 只有 % 時，非正常狀態在數字後加一個符號，形狀本身就能區分：↑ 太快、! 剩 < 20%、– 過期
                symbol(c.state, in: rect, color: c.state == .tooFast ? notice : main)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = c.accessibilityText
        return image
    }

    /// 從 12 點鐘方向順時針畫 `fraction` 的弧，底下是淡色軌道。`dashed`（資料過期）時軌道與弧都改為虛線。
    private static func ring(center: NSPoint, radius: CGFloat, width: CGFloat, fraction: Double, color: NSColor,
                             dashed: Bool = false) {
        // 周長約 41pt，1.8＋1.6 的虛線約 12 段，16pt 的圖示上也看得出斷開
        let dash: [CGFloat] = [1.8, 1.6]
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        if dashed { track.setLineDash(dash, count: dash.count, phase: 0) }
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        track.stroke()
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
        arc.lineWidth = width
        if dashed {
            arc.setLineDash(dash, count: dash.count, phase: 0)
            arc.lineCapStyle = .butt
        } else {
            arc.lineCapStyle = .round
        }
        color.setStroke()
        arc.stroke()
    }

    /// 「只有 %」樣式的狀態符號，置中畫在 `rect` 裡。正常狀態不會呼叫（`MenuBarIconView` 不加圖）。
    private static func symbol(_ state: MenuBarState, in rect: NSRect, color: NSColor) {
        let text: String = switch state {
        case .tooFast: "↑"
        case .critical: "!"
        case .stale: "–"
        case .normal: ""
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private static func dot(at point: NSPoint, color: NSColor, radius: CGFloat = 2.2) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
}
