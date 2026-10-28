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

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        icon
            // 右鍵選單與快捷鍵在 SwiftUI 之外，借用這裡的 openWindow／openSettings（選單列標籤一直存在）
            .onAppear {
                AppActions.openStats = { [openWindow] in openWindow(id: StatsWindowView.windowID) }
                AppActions.openSettings = { [openSettings] in openSettings() }
                AppActions.openWizard = { [openWindow] in openWindow(id: SetupWizardView.windowID) }
                SetupWizardModel.openIfNeeded()
            }
    }

    @ViewBuilder
    private var icon: some View {
        if let snapshot = store.snapshot, let item = snapshot.window(for: settings.iconWindow, at: store.now) {
            let content = MenuBarIconContent(item: item, snapshot: snapshot, now: store.now, isLeast: settings.iconWindow == .automatic)
            MenuBarIconView(content: content, style: settings.iconStyle, character: settings.mascotCharacter)
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
    /// 這個服務的狀態頁有進行中的事故（角色生病，同瀏海；Codex C-03）
    var incident: Bool
    /// 這個服務有額度預測會在重置前用完（角色擔心，同瀏海）
    var runsOut: Bool

    init(provider: String, remainingPct: Int, timeRemaining: Int?, state: MenuBarState, label: String, isLeast: Bool = true,
         incident: Bool = false, runsOut: Bool = false) {
        self.provider = provider
        self.remainingPct = remainingPct
        self.timeRemaining = timeRemaining
        self.state = state
        self.label = label
        self.isLeast = isLeast
        self.incident = incident
        self.runsOut = runsOut
    }

    init(item: ProviderWindow, snapshot: UsageSnapshot, now: Date, isLeast: Bool) {
        self.isLeast = isLeast
        provider = item.provider
        remainingPct = Int(item.window.effectiveRemainingPct(at: now).rounded())
        timeRemaining = item.window.timeRemainingFraction(at: now).map { Int(($0 * 50).rounded()) * 2 }
        state = MenuBarState(window: item.window, stale: snapshot.isStale(now: now), now: now)
        label = item.displayName
        incident = MascotMood.hasIncident(snapshot, provider: item.provider)
        runsOut = MascotMood.runsOut(snapshot, provider: item.provider, now: now)
    }

    /// 角色樣式的表情：和瀏海同一套優先順序（過期 > 用完 > 事故 > 會用完或剩不到 20% > 正常）
    var mood: MascotMood {
        let level = state == .critical ? (remainingPct <= 0 ? 2 : 1) : 0
        return MascotMood.quota(level: level, unavailable: state == .stale, incident: incident, runsOut: runsOut)
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
        if state != .stale && incident { text += "，服務有事故" }
        if state != .stale && runsOut { text += "，照目前速度會在重置前用完" }
        return text
    }
}

struct MenuBarIconView: View {
    let content: MenuBarIconContent
    let style: MenuBarIconStyle
    var character: MascotCharacter = .claude

    var body: some View {
        HStack(spacing: 3) {
            switch style {
            case .dualRing, .bar:
                Image(nsImage: MenuBarIcon.image(content, style: style))
            case .ringPercent:
                Image(nsImage: MenuBarIcon.image(content, style: style))
                Text("\(content.remainingPct)%").monospacedDigit()
            case .character:
                Image(nsImage: MenuBarIcon.image(content, style: style, character: shownCharacter))
            case .characterPercent:
                Image(nsImage: MenuBarIcon.image(content, style: style, character: shownCharacter))
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

    /// 圖示上的角色跟著顯示的額度所屬的服務（Codex C-05）：選 Claude 但剩最少的是 Codex 時畫 Codex，
    /// 百分比、眼睛的表情與角色才是同一個服務；不是 Claude／Codex 時用設定選的角色
    private var shownCharacter: MascotCharacter {
        MascotCharacter(rawValue: content.provider) ?? character
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
        var character: MascotCharacter?
    }

    static func image(_ content: MenuBarIconContent, style: MenuBarIconStyle, character: MascotCharacter? = nil) -> NSImage {
        let key = Key(content: content, style: style, character: style.showsCharacter ? character ?? .claude : nil)
        if let cached = cache[key] { return cached }
        if cache.count > 64 { cache.removeAll() }
        let image = key.character.map { drawCharacter(content, character: $0) } ?? draw(content, style: style)
        cache[key] = image
        return image
    }

    private static func draw(_ c: MenuBarIconContent, style: MenuBarIconStyle) -> NSImage {
        let size: NSSize = switch style {
        case .bar: NSSize(width: 22, height: 16)
        case .percent: NSSize(width: 8, height: 16)
        case .dualRing, .ringPercent, .character, .characterPercent: NSSize(width: 18, height: 16)
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
            case .character, .characterPercent:
                break   // drawCharacter
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

    private enum CharacterIconEyes { case pill, dot, cross, closed, half }

    /// 角色樣式（ADR-0016）：靜止的迷你角色（不動、不眨眼），額度用眼睛的形狀表示（同瀏海面板，沒有狀態點）：
    /// 正常膠囊、剩不到 20% 或預測會用完小圓點、用完 ×、事故半閉眼加冷汗、過期閉眼並轉灰，不只靠顏色；
    /// 表情和瀏海用同一個 `MascotMood`。用得太快右上角加提示色小點。
    private static func drawCharacter(_ c: MenuBarIconContent, character: MascotCharacter) -> NSImage {
        let palette = MascotController.shared.baseConfig?.palette
        func color(_ rgb: [Double]?, _ fallback: NSColor) -> NSColor {
            guard let rgb, rgb.count == 3 else { return fallback }
            return NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1)
        }
        let stale = c.state == .stale
        let tint = palette.map { stale ? $0.white : character.tint($0) }
        let fallback = NSColor(UsageColors.provider(character.provider))
        let light = color(tint?.light, fallback), mid = color(tint?.mid, fallback), shade = color(tint?.shade, fallback)
        let mood = c.mood
        let eyes: CharacterIconEyes = switch mood {
        case .stale: .closed
        case .out: .cross
        case .worried, .surprised: .dot
        case .sick, .sad: .half
        case .normal, .happy: .pill
        }
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            let center = NSPoint(x: 9, y: rect.midY)
            let radius: CGFloat = 6.8
            let ball = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            NSGradient(colors: [light, mid, shade], atLocations: [0, 0.55, 1], colorSpace: .sRGB)?
                .draw(in: ball, relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
            // 兩眼：中心距約直徑 27%。正常是直立的膠囊；剩不到 20% 縮成小圓點、用完變成 ×、過期閉成線，
            // 灰階下也分得出四種狀態（ADR-0008 第 1 節）
            let ink = NSColor(white: 0.08, alpha: 1)
            ink.setFill()
            for side in [-1.0, 1.0] {
                let x = center.x + side * radius * 0.27
                switch eyes {
                case .closed:
                    NSBezierPath(roundedRect: NSRect(x: x - 1.1, y: center.y - 0.9, width: 2.2, height: 0.9), xRadius: 0.45, yRadius: 0.45).fill()
                case .dot:
                    NSBezierPath(ovalIn: NSRect(x: x - 0.9, y: center.y - 0.9, width: 1.8, height: 1.8)).fill()
                case .cross:
                    let cross = NSBezierPath()
                    cross.move(to: NSPoint(x: x - 1.05, y: center.y - 1.05)); cross.line(to: NSPoint(x: x + 1.05, y: center.y + 1.05))
                    cross.move(to: NSPoint(x: x - 1.05, y: center.y + 1.05)); cross.line(to: NSPoint(x: x + 1.05, y: center.y - 1.05))
                    cross.lineWidth = 0.9
                    cross.lineCapStyle = .round
                    ink.setStroke()
                    cross.stroke()
                case .pill:
                    NSBezierPath(roundedRect: NSRect(x: x - 0.75, y: center.y - 2.1, width: 1.5, height: 3.2), xRadius: 0.75, yRadius: 0.75).fill()
                case .half:
                    // 膠囊的下半（上半被眼皮蓋住）
                    NSBezierPath(roundedRect: NSRect(x: x - 0.75, y: center.y - 2.1, width: 1.5, height: 1.6), xRadius: 0.75, yRadius: 0.75).fill()
                }
            }
            if mood.sweat {
                NSColor(srgbRed: 0.55, green: 0.78, blue: 1, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x + radius * 0.55, y: center.y + radius * 0.2, width: 1.6, height: 2.2)).fill()
            }
            if c.state == .tooFast { dot(at: NSPoint(x: 16, y: rect.maxY - 3), color: NSColor(UsageColors.notice), radius: 1.8) }
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
