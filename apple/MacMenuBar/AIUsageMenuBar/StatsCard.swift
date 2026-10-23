import SwiftUI
import UsageKit
import UsageKitUI

// 面板第三階段：這台 Mac 的 Token 統計卡片（FR-43、FR-46，ADR-0008 第 2 節、ADR-0009 第 4、8 節、ADR-0011 第 4 節）。
// 計算都在 UsageKit（TokenStats.swift），這裡只負責畫。
// 文字一律 primary／secondary；顏色只用在服務圖示、長條與熱力圖（「全部」的熱力圖用灰階，不代表任何服務）。

private struct TokenStatsKey: EnvironmentKey {
    static let defaultValue = TokenStatsData.empty
}

extension EnvironmentValues {
    var tokenStats: TokenStatsData {
        get { self[TokenStatsKey.self] }
        set { self[TokenStatsKey.self] = newValue }
    }
}

/// 畫面上的日期：與資料庫的日期鍵一樣用西元曆（使用者選民國曆或佛曆時年份也一致）
enum TokenDateText {
    static func string(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.calendar = TokenCalendar.make()
        f.dateFormat = format
        return f.string(from: date)
    }
}

/// 範圍標籤「這台 Mac」：滑鼠移上去說明不包含的來源（ADR-0011 第 4 節）。
struct ThisMacBadge: View {
    static let help = "只包含這台 Mac 上 Claude Code 與 Codex CLI 的對話紀錄（含它們的桌面 App 與編輯器外掛）。不包含 claude.ai 網頁、手機 App、其他電腦與雲端 session。額度 % 是整個帳號的數字。"

    var body: some View {
        Text("這台 Mac")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help(Self.help)
            .accessibilityLabel("範圍：這台 Mac。不包含網頁、手機 App、其他電腦與雲端 session")
    }
}

struct StatsCardHeader: View {
    var body: some View {
        HStack {
            PanelCardTitle(text: PanelSection.stats.title)
            Spacer(minLength: 4)
            ThisMacBadge()
        }
    }
}

/// 全部／Claude／Codex
struct TokenScopeChips: View {
    let scopes: [TokenScope]
    let selected: TokenScope
    let select: (TokenScope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(scopes) { scope in
                Button { select(scope) } label: {
                    HStack(spacing: 3) {
                        if scope != .all {
                            ProviderIcon(scope.rawValue)
                                .foregroundStyle(UsageColors.provider(scope.rawValue))
                                .frame(width: 10, height: 10)
                        }
                        Text(scope.title)
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(scope == selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(scope.title)
                .accessibilityAddTraits(scope == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 有兩個服務的資料時才需要切換
    static func scopes(_ data: TokenStatsData) -> [TokenScope] {
        let providers = data.providers
        return providers.count > 1 ? [.all] + providers.compactMap { TokenScope(rawValue: $0) } : []
    }
}

/// 卡片內容：第一次使用的骨架、沒有紀錄的提示，或四個數字＋Token 活動＋活動熱力圖。
struct StatsCardContent: View {
    let data: TokenStatsData
    let status: HistoryStore.Status
    let scope: TokenScope
    let range: TokenActivityRange
    let now: Date
    let selectScope: (TokenScope) -> Void
    let selectRange: (TokenActivityRange) -> Void

    @Environment(\.panelAnimates) private var animates

    var body: some View {
        Group {
            if let message = placeholder {
                StatsSkeleton(message: message)
                    .transition(.opacity)
            } else if !data.hasData {
                Text("這台 Mac 還沒有 Claude Code 或 Codex CLI 的紀錄")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                StatsBody(data: data, scope: effectiveScope, range: range, now: now, selectScope: selectScope, selectRange: selectRange)
                    .transition(.opacity)
            }
        }
        .animation(animates ? PanelTiming.crossfade : nil, value: placeholder == nil)
    }

    /// 只有一個服務的資料時固定為「全部」
    private var effectiveScope: TokenScope {
        TokenScopeChips.scopes(data).contains(scope) ? scope : .all
    }

    /// 首次掃描還沒完成、版本或讀取問題時的說明；nil＝可以顯示統計
    private var placeholder: String? {
        switch status {
        case .olderSchema: return "收集器的版本較舊，請重新執行 collector/scripts/install-launchd.sh"
        case .failed: return "無法讀取 Token 統計（history.sqlite3）"
        case .missing: return "正在整理過去的紀錄"
        default: break
        }
        guard !data.firstScanDone else { return nil }
        return data.firstScanProgress.map { "正在整理過去的紀錄（\($0)%）" } ?? "正在整理過去的紀錄"
    }
}

/// 骨架：四格數字、長條與熱力圖的灰色佔位＋說明；打開面板時掃光三次（與額度歷史的骨架共用）。
struct StatsSkeleton: View {
    let message: String

    @Environment(\.panelMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)).frame(height: 44)
                    }
                }
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<30, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 8 + 30 * abs(sin(Double(i) * 0.7)))
                    }
                }
                .frame(height: 40, alignment: .bottom)
            }
            .padding(10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { ShimmerOverlay(progress: motion.shimmer) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

private struct StatsBody: View {
    let data: TokenStatsData
    let scope: TokenScope
    let range: TokenActivityRange
    let now: Date
    let selectScope: (TokenScope) -> Void
    let selectRange: (TokenActivityRange) -> Void

    @Environment(\.panelAnimates) private var animates

    var body: some View {
        let summary = TokenSummary(data: data, scope: scope, now: now)
        VStack(alignment: .leading, spacing: 12) {
            let scopes = TokenScopeChips.scopes(data)
            if !scopes.isEmpty {
                TokenScopeChips(scopes: scopes, selected: scope, select: selectScope)
            }
            StatNumbers(summary: summary, scope: scope)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Token 活動").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    TokenRangeChips(selected: range, select: selectRange)
                }
                TokenActivityChart(bars: TokenActivity.bars(data: data, scope: scope, range: range, now: now), scope: scope, range: range)
                    .id("\(scope.rawValue)-\(range.rawValue)")
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("活動熱力圖").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TokenHeatmapView(map: TokenHeatmap(data: data, scope: scope, now: now, weeks: 22), scope: scope)
                    .id(scope)
                    .transition(.opacity)
            }
            if data.skippedLines > 0 {
                Text("部分紀錄無法解析，已略過 \(data.skippedLines) 行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(animates ? PanelTiming.crossfade : nil, value: scope)
        .animation(animates ? PanelTiming.crossfade : nil, value: range)
    }
}

/// 四個數字：本週 Token（與上週同期比較）、單日最高、最長任務、連續天數。
private struct StatNumbers: View {
    let summary: TokenSummary
    let scope: TokenScope

    @Environment(\.panelMotion) private var motion
    @Environment(\.panelAnimates) private var animates

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile("本週 Token", help: weekHelp) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(TokenFormat.short(summary.thisWeek.main)).contentTransition(.numericText())
                        if let change = summary.changePct {
                            Text("\(change >= 0 ? "▲" : "▼")\(Int(abs(change).rounded()))%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .help("與上週同一段期間（星期一到上週的今天）相比")
                        }
                    }
                }
                tile("單日最高", detail: summary.bestDay?.day.map(Self.dayText)) {
                    Text(summary.bestDay.map { TokenFormat.short($0.value) } ?? "–").contentTransition(.numericText())
                }
            }
            GridRow {
                tile("最長任務", detail: summary.longestTaskSeconds?.day.map(Self.dayText)) {
                    Text(summary.longestTaskSeconds.map { TokenFormat.duration($0.value) } ?? "–").contentTransition(.numericText())
                }
                tile("連續天數", detail: summary.longestStreak.map { "最長 \($0.value) 天" }) {
                    HStack(spacing: 3) {
                        Text("\(summary.currentStreak) 天").contentTransition(.numericText())
                        if summary.streakIsRecord && summary.currentStreak > 1 {
                            Text("🔥")
                                .font(.callout)
                                .scaleEffect(1 + 0.5 * sin(.pi * motion.streakPop))
                                .accessibilityLabel("創新紀錄")
                        }
                    }
                }
            }
        }
        .animation(animates ? PanelTiming.statsNumbers : nil, value: summary)
    }

    private var weekHelp: String {
        let c = summary.thisWeek
        return """
        輸入 \(TokenFormat.full(c.input))
        快取寫入 \(TokenFormat.full(c.cacheWrite))
        輸出 \(TokenFormat.full(c.output))（含推理 \(TokenFormat.full(c.reasoning))）
        快取讀取 \(TokenFormat.full(c.cacheRead))（不計入上方數字）
        """
    }

    static func dayText(_ key: String) -> String {
        guard let date = TokenCalendar.date(key, calendar: .current) else { return key }
        return TokenDateText.string(date, "M/d")
    }

    private func tile(_ title: String, detail: String? = nil, help: String? = nil, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            value()
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

struct TokenRangeChips: View {
    let selected: TokenActivityRange
    let select: (TokenActivityRange) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TokenActivityRange.allCases) { range in
                Button { select(range) } label: {
                    Text(range.title)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(range == selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(range == selected ? .isSelected : [])
            }
        }
    }
}

/// Token 活動：30 天／12 週的疊加長條（Claude、Codex），或累計的面積圖。
/// 長條由下往上依序長出（每根延遲 15ms，ADR-0010）；滑鼠移上去放大並在下方顯示數值。
struct TokenActivityChart: View {
    let bars: [TokenBar]
    let scope: TokenScope
    let range: TokenActivityRange
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
        return switch range {
        case .days30: "最近 30 天，每根一天（不含快取讀取）"
        case .weeks: "最近 12 週，每根一週（星期一起）"
        case .cumulative: "累計 Token（含保留期間以前）"
        }
    }

    private var hoverText: String? {
        guard let hovered, bars.indices.contains(hovered) else { return nil }
        let bar = bars[hovered]
        let day = TokenDateText.string(bar.start, "M/d")
        let when = range == .weeks ? "\(day) 那週" : day
        guard bar.available else { return "\(when)：超過保留期間，沒有資料" }
        if range == .cumulative { return "\(when)：累計 \(TokenFormat.short(bar.main))" }
        var text = "\(when)：\(TokenFormat.short(bar.main))"
        if scope == .all, bar.byProvider.count > 1 {
            text += "（" + ["claude", "codex"].compactMap { p in bar.byProvider[p].map { "\(ProviderInfo.displayName(p)) \(TokenFormat.short($0))" } }
                .joined(separator: "、") + "）"
        }
        if bar.counts.cacheRead > 0 { text += " · 快取讀取 \(TokenFormat.short(bar.counts.cacheRead))" }
        return text
    }

    private var accessibilityText: String {
        let total = range == .cumulative ? (bars.last?.main ?? 0) : bars.reduce(0) { $0 + $1.main }
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
            let peak = Double(max(bars.map(\.main).max() ?? 0, 1))
            let slot = size.width / CGFloat(max(bars.count, 1))
            let barWidth = max(slot - (bars.count > 20 ? 2 : 4), 1)
            context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: size.height - 0.5)); p.addLine(to: CGPoint(x: size.width, y: size.height - 0.5)) },
                           with: .color(Color.primary.opacity(0.1)), lineWidth: 1)
            if cumulative {
                // 累計：面積圖，由左往右描繪
                // 只畫保留期間內（算得出當天累計）的日子
                guard let firstIndex = bars.firstIndex(where: \.available), bars.count - firstIndex > 1 else { return }
                let low = Double(bars[firstIndex].main) * 0.9
                func y(_ v: Int64) -> CGFloat { size.height - CGFloat((Double(v) - low) / max(peak - low, 1)) * (size.height - 4) }
                var line = Path(), area = Path()
                for (i, bar) in bars.enumerated() where i >= firstIndex {
                    let p = CGPoint(x: slot * (CGFloat(i) + 0.5), y: y(bar.main))
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
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(HeatmapCanvas.color(level: level, tint: tint)).frame(width: 9, height: 9)
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

    private var tint: Color { scope == .all ? Color.primary : UsageColors.provider(scope.rawValue) }

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
    let tint: Color
    let hovered: Int?
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static func color(level: Int, tint: Color) -> Color {
        level == 0 ? Color.primary.opacity(0.07) : tint.opacity([0, 0.28, 0.5, 0.72, 0.95][min(level, 4)])
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
                layer.fill(shape, with: .color(Self.color(level: map.level(value), tint: tint)))
                if i == hovered { layer.stroke(shape, with: .color(.primary), lineWidth: 1) }
            }
        }
    }
}
