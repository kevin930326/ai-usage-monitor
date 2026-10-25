import SwiftUI
import UsageKit
import UsageKitUI

// 統計卡片與完整統計視窗共用的圖：Token 活動長條圖與活動熱力圖（FR-36、ADR-0009 第 6 節）。

/// Token 活動：30 天／12 週的疊加長條（Claude、Codex），或累計的面積圖。
/// 長條由下往上依序長出（每根延遲 15ms，ADR-0010）；滑鼠移上去放大並在下方顯示數值。
struct TokenActivityChart: View {
    let bars: [TokenBar]
    let scope: TokenScope
    let range: TokenActivityRange
    var measure = TokenMeasure.main
    var height: CGFloat = 56

    @Environment(\.panelMotion) private var motion
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TokenBarsCanvas(bars: bars, scope: scope, cumulative: range == .cumulative, hovered: hovered, progress: motion.statsBars)
                .frame(height: height)
                .overlay {
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case let .active(point):
                                    hovered = TokenBarsCanvas.index(at: point.x, count: bars.count, width: geo.size.width)
                                case .ended:
                                    hovered = nil
                                }
                            }
                    }
                }
            Text(hoverText ?? caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var caption: String {
        if bars.contains(where: { !$0.available }) { return "保留期間以前的日子沒有資料，不畫" }
        let cached = measure == .includingCacheRead
        return switch range {
        case .days30: "最近 30 天，每根一天（\(cached ? "含" : "不含")快取讀取）"
        case .weeks: cached ? "最近 12 週，每根一週（星期一起，含快取讀取）" : "最近 12 週，每根一週（星期一起）"
        // 收集器的累計只記主數字：含快取讀取時是已讀取的每日資料（最近一年）的合計
        case .cumulative: cached ? "累計 Token（含快取讀取，只算最近一年）" : "累計 Token（含保留期間以前）"
        }
    }

    private var hoverText: String? {
        guard let hovered, bars.indices.contains(hovered) else { return nil }
        let bar = bars[hovered]
        let day = TokenDateText.string(bar.start, "M/d")
        let when = range == .weeks ? "\(day) 那週" : day
        guard bar.available else { return "\(when)：超過保留期間，沒有資料" }
        if range == .cumulative { return "\(when)：累計 \(TokenFormat.short(bar.value))" }
        var text = "\(when)：\(TokenFormat.short(bar.value))"
        if scope == .all, bar.byProvider.count > 1 {
            text += "（" + ["claude", "codex"].compactMap { p in bar.byProvider[p].map { "\(ProviderInfo.displayName(p)) \(TokenFormat.short($0))" } }
                .joined(separator: "、") + "）"
        }
        if bar.counts.cacheRead > 0 {
            text += " · \(measure == .includingCacheRead ? "其中" : "")快取讀取 \(TokenFormat.short(bar.counts.cacheRead))"
        }
        return text
    }

    private var accessibilityText: String {
        let total = range == .cumulative ? (bars.last?.value ?? 0) : bars.reduce(0) { $0 + $1.value }
        return "Token 活動，\(caption)：合計 \(TokenFormat.short(total))"
    }
}

/// 長條本體：`Animatable`，每一格依進度重畫（依序長出需要逐格的進度）。
struct TokenBarsCanvas: View, Animatable {
    let bars: [TokenBar]
    let scope: TokenScope
    let cumulative: Bool
    let hovered: Int?
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static func index(at x: CGFloat, count: Int, width: CGFloat) -> Int? {
        guard count > 0, width > 0 else { return nil }
        let i = Int(x / (width / CGFloat(count)))
        return (0..<count).contains(i) ? i : nil
    }

    /// 第 i 根的長出進度：每根晚 15ms，各花 0.45 秒（總長 ≤ 0.9 秒）
    static func grow(_ progress: Double, index: Int, count: Int) -> Double {
        let total = 0.45 + 0.015 * Double(max(count - 1, 0))
        let t = min(max((progress * total - 0.015 * Double(index)) / 0.45, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    var body: some View {
        Canvas { context, size in
            let peak = Double(max(bars.map(\.value).max() ?? 0, 1))
            let slot = size.width / CGFloat(max(bars.count, 1))
            let barWidth = max(slot - (bars.count > 20 ? 2 : 4), 1)
            context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: size.height - 0.5)); p.addLine(to: CGPoint(x: size.width, y: size.height - 0.5)) },
                           with: .color(Color.primary.opacity(0.1)), lineWidth: 1)
            if cumulative {
                // 累計：面積圖，由左往右描繪
                // 只畫保留期間內（算得出當天累計）的日子
                guard let firstIndex = bars.firstIndex(where: \.available), bars.count - firstIndex > 1 else { return }
                let low = Double(bars[firstIndex].value) * 0.9
                func y(_ v: Int64) -> CGFloat { size.height - CGFloat((Double(v) - low) / max(peak - low, 1)) * (size.height - 4) }
                var line = Path(), area = Path()
                for (i, bar) in bars.enumerated() where i >= firstIndex {
                    let p = CGPoint(x: slot * (CGFloat(i) + 0.5), y: y(bar.value))
                    if i == firstIndex { line.move(to: p); area.move(to: CGPoint(x: p.x, y: size.height)); area.addLine(to: p) } else { line.addLine(to: p); area.addLine(to: p) }
                }
                area.addLine(to: CGPoint(x: slot * (CGFloat(bars.count) - 0.5), y: size.height))
                area.closeSubpath()
                var clipped = context
                clipped.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * CGFloat(min(max(progress, 0), 1)), height: size.height)))
                let tint = scope == .all ? Color.primary : UsageColors.provider(scope.rawValue)
                clipped.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.25), tint.opacity(0.03)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                clipped.stroke(line, with: .color(tint.opacity(scope == .all ? 0.7 : 1)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                return
            }
            for (i, bar) in bars.enumerated() where bar.available {
                let grow = Self.grow(progress, index: i, count: bars.count)
                let x = slot * CGFloat(i) + (slot - barWidth) / 2
                let scale: CGFloat = i == hovered ? 1.08 : 1
                var y = size.height
                for provider in ["claude", "codex"] where scope.includes(provider) {
                    guard let value = bar.byProvider[provider], value > 0 else { continue }
                    let h = max(CGFloat(Double(value) / peak) * size.height * CGFloat(grow) * scale, 1)
                    let rect = CGRect(x: x - (scale - 1) * barWidth / 2, y: y - h, width: barWidth * scale, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, barWidth / 2)),
                                 with: .color(UsageColors.provider(provider).opacity(hovered == nil || hovered == i ? 1 : 0.55)))
                    y -= h
                }
            }
        }
    }
}

/// 活動熱力圖：一欄一週（星期一在上），最右欄是本週。格子依可用寬度放大（最大 16pt），
/// 月份與星期標籤畫在同一個 Canvas 裡。第一次打開時由左到右以「欄」為單位淡入（ADR-0010）。
struct TokenHeatmapView: View {
    let map: TokenHeatmap
    let scope: TokenScope

    @Environment(\.panelMotion) private var motion
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HeatmapLayout(weeks: map.weeks) {
                HeatmapCanvas(map: map, tint: tint, hovered: hovered, progress: motion.heatmap)
                    .overlay {
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    if case let .active(point) = phase {
                                        hovered = HeatmapCanvas.cell(at: point, size: geo.size, map: map)
                                    } else {
                                        hovered = nil
                                    }
                                }
                        }
                    }
            }
            HStack(spacing: 2) {
                Text(hoverText ?? (map.truncated ? "每格一天 · 保留期間以前不顯示" : "每格一天"))
                Spacer(minLength: 6)
                Text("少")
                ForEach(0...UsagePalette.heatmapLevels, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(UsageColors.heatmap(level: level, tint: tint)).frame(width: 9, height: 9)
                }
                Text("多")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// 「全部」用藍色色階（不代表任何服務），各服務用識別色
    private var tint: Color? { scope == .all ? nil : UsageColors.provider(scope.rawValue) }

    static func weekday(_ row: Int) -> String {
        ["一", "二", "三", "四", "五", "六", "日"][row]
    }

    private var hoverText: String? {
        guard let hovered, let value = map.cells[hovered] else { return nil }
        let date = map.date(column: hovered / 7, row: hovered % 7)
        return "\(TokenDateText.string(date, "M/d")) 週\(Self.weekday(hovered % 7))：\(value > 0 ? TokenFormat.short(value) : "沒有使用")"
    }

    private var accessibilityText: String {
        let used = map.cells.compactMap { $0 }.filter { $0 > 0 }.count
        return "活動熱力圖：最近 \(map.weeks) 週中有 \(used) 天使用"
    }
}

/// 熱力圖的高度隨寬度變：上方月份 12pt＋7 列格子（格子邊長＝可用寬度 ÷ 週數，最大 16pt）
struct HeatmapLayout: Layout {
    let weeks: Int

    static let gutter: CGFloat = 16
    static let header: CGFloat = 12
    static let gap: CGFloat = 2
    static let maxStep: CGFloat = 16 + gap

    static func step(width: CGFloat, weeks: Int) -> CGFloat {
        min(max((width - gutter) / CGFloat(max(weeks, 1)), 4), maxStep)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (Self.gutter + CGFloat(weeks) * 12)
        return CGSize(width: width, height: Self.header + 7 * Self.step(width: width, weeks: weeks))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

struct HeatmapCanvas: View, Animatable {
    let map: TokenHeatmap
    let tint: Color?
    let hovered: Int?
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// 第 c 欄的不透明度：由左到右依序淡入（每欄 0.4 的淡入，起點錯開，總長 1.0）
    static func columnOpacity(_ progress: Double, column: Int, columns: Int) -> Double {
        let start = 0.6 * Double(column) / Double(max(columns - 1, 1))
        return min(max((progress - start) / 0.4, 0), 1)
    }

    /// 滑鼠位置對應的格子（今天以後的格子不算）
    static func cell(at point: CGPoint, size: CGSize, map: TokenHeatmap) -> Int? {
        let step = HeatmapLayout.step(width: size.width, weeks: map.weeks)
        let column = Int(floor((point.x - HeatmapLayout.gutter) / step)), row = Int(floor((point.y - HeatmapLayout.header) / step))
        guard (0..<map.weeks).contains(column), (0..<7).contains(row), map.cells[column * 7 + row] != nil else { return nil }
        return column * 7 + row
    }

    var body: some View {
        Canvas { context, size in
            let step = HeatmapLayout.step(width: size.width, weeks: map.weeks)
            let cell = step - HeatmapLayout.gap
            let x0 = HeatmapLayout.gutter, y0 = HeatmapLayout.header
            // 星期：一、三、五、日
            for row in [0, 2, 4, 6] {
                let label = context.resolve(Text(TokenHeatmapView.weekday(row)).font(.system(size: 8)).foregroundStyle(.secondary))
                context.draw(label, at: CGPoint(x: x0 - 4, y: y0 + CGFloat(row) * step + cell / 2), anchor: .trailing)
            }
            // 月份：每個月第一週所在的欄（與上一個標籤至少隔 3 欄）
            let calendar = TokenCalendar.make()
            var lastMonth: Int?, lastLabel = -10
            for column in 0..<map.weeks {
                let date = map.date(column: column, row: 0)
                let month = calendar.component(.month, from: date)
                defer { lastMonth = month }
                guard month != lastMonth, lastMonth != nil || calendar.component(.day, from: date) <= 7, column - lastLabel >= 3 else { continue }
                lastLabel = column
                let label = context.resolve(Text("\(month)月").font(.system(size: 8)).foregroundStyle(.secondary))
                context.draw(label, at: CGPoint(x: x0 + CGFloat(column) * step, y: 0), anchor: .topLeading)
            }
            for (i, value) in map.cells.enumerated() {
                guard let value else { continue }
                let column = i / 7, row = i % 7
                let opacity = Self.columnOpacity(progress, column: column, columns: map.weeks)
                guard opacity > 0 else { continue }
                let rect = CGRect(x: x0 + CGFloat(column) * step, y: y0 + CGFloat(row) * step, width: cell, height: cell)
                let shape = Path(roundedRect: rect, cornerRadius: min(2, cell / 4))
                var layer = context
                layer.opacity = opacity
                layer.fill(shape, with: .color(UsageColors.heatmap(level: map.level(value), tint: tint)))
                if i == hovered { layer.stroke(shape, with: .color(.primary), lineWidth: 1) }
            }
        }
    }
}
