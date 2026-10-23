import SwiftUI
import UsageKit
import UsageKitUI

// 面板第二階段的區塊（FR-39～FR-42、FR-46，ADR-0008 第 2 節）：建議接下來用、接下來的重置、
// 本週額度走勢、額度消耗。計算都在 UsageKit（QuotaHistory.swift），這裡只負責畫。
// 文字一律 primary／secondary，顏色只用在服務圖示、曲線、熱力圖與提示文字（設計 skill 第 1 節）。

private struct QuotaHistoryKey: EnvironmentKey {
    static let defaultValue = QuotaHistory.empty
}

extension EnvironmentValues {
    /// 面板開啟時讀到的額度歷史；用量節奏的「約 N 分鐘後用完」改用近期速度（ADR-0008 第 4 節）
    var quotaHistory: QuotaHistory {
        get { self[QuotaHistoryKey.self] }
        set { self[QuotaHistoryKey.self] = newValue }
    }
}

// MARK: - 選擇額度

/// 走勢與額度消耗可切換的額度：沒有錯誤的服務中，長度已知的可見額度。
struct HistoryWindowOption: Identifiable, Equatable {
    var provider: String
    var window: UsageWindow
    var id: String { "\(provider)/\(window.id)" }

    var item: ProviderWindow { ProviderWindow(provider: provider, window: window) }

    /// 標籤上的短名稱（圖示已表示服務）：「每週」「5h」
    var shortLabel: String { window.id == "five_hour" ? "5h" : window.label }

    static func options(_ snapshot: UsageSnapshot) -> [HistoryWindowOption] {
        snapshot.orderedProviderKeys.flatMap { key -> [HistoryWindowOption] in
            guard let p = snapshot.providers[key], p.error == nil else { return [] }
            return p.visibleWindows.filter { $0.duration != nil }.map { HistoryWindowOption(provider: key, window: $0) }
        }
    }

    /// 儲存的選擇還在就用它，否則用第一個服務的每週額度（都沒有時用第一個）。
    static func resolve(_ stored: String?, in options: [HistoryWindowOption]) -> HistoryWindowOption? {
        if let stored, let match = options.first(where: { $0.id == stored }) { return match }
        return options.first { $0.window.id == "weekly" } ?? options.first
    }
}

struct HistoryWindowChips: View {
    let options: [HistoryWindowOption]
    let selected: HistoryWindowOption
    let stale: Bool
    let select: (HistoryWindowOption) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button { select(option) } label: {
                    HStack(spacing: 3) {
                        ProviderIcon(option.provider)
                            .foregroundStyle(stale ? AnyShapeStyle(UsageColors.stale) : AnyShapeStyle(UsageColors.provider(option.provider)))
                            .frame(width: 10, height: 10)
                        Text(option.shortLabel)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(option == selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.item.displayName)
                .accessibilityAddTraits(option == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 建議接下來用（FR-39）

/// 一行提示，不收合（只有一行，收合後沒有內容可以藏）；都充足時整個不顯示、不占空間。
struct SuggestBanner: View {
    let suggestion: NextProviderSuggestion

    @Environment(\.panelMotion) private var motion

    var body: some View {
        HStack(spacing: 6) {
            Text("建議接下來用")
                .font(.callout)
            ProviderIcon(suggestion.provider)
                .foregroundStyle(UsageColors.provider(suggestion.provider))
                .frame(width: 15, height: 15)
                .id(suggestion.provider)
                .transition(.opacity)
            Text(ProviderInfo.displayName(suggestion.provider))
                .font(.callout.weight(.semibold))
                .id("name-\(suggestion.provider)")
                .transition(.opacity)
            Spacer(minLength: 4)
            Text("\(suggestion.window.label)還剩 \(Int(suggestion.remainingPct.rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(UsageColors.provider(suggestion.provider).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UsageColors.provider(suggestion.provider).opacity(0.25)))
        // 從上方滑入（ADR-0010：0.3 秒）
        .offset(y: -10 * (1 - motion.suggest))
        .opacity(motion.suggest)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("建議接下來用 \(ProviderInfo.displayName(suggestion.provider))，\(suggestion.window.label)還剩 \(Int(suggestion.remainingPct.rounded()))%，\(ProviderInfo.displayName(suggestion.exhaustedProvider))快用完了")
    }
}

// MARK: - 接下來的重置（FR-40）

struct ResetsCardHeader: View {
    var body: some View {
        HStack {
            PanelCardTitle(text: PanelSection.resets.title)
            Spacer(minLength: 4)
            Text("未來 8 小時").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ResetsCardContent: View {
    let snapshot: UsageSnapshot
    let history: QuotaHistory
    let stale: Bool
    let now: Date

    @Environment(\.panelMotion) private var motion

    var body: some View {
        let resets = UpcomingReset.list(snapshot: snapshot, now: now)
        let waiting = UpcomingReset.awaitingStart(snapshot: snapshot)
        let forecasts = WeeklyForecast.list(snapshot: snapshot, history: history, now: now)
        VStack(alignment: .leading, spacing: 12) {
            ResetTimeline(resets: resets, stale: stale, progress: motion.timeline)
            if !waiting.isEmpty {
                // 服務回報沒有重置時間：已重置，新一輪要等下次使用才開始計時
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(waiting, id: \.key) { item in
                        Text("\(ResetTimeline.name(provider: item.provider, window: item.window))：已重置，下次使用時開始計時")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !forecasts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(forecasts, id: \.provider) { forecast in
                        ForecastLine(forecast: forecast, now: now)
                    }
                }
            }
        }
    }
}

/// 時間軸：左端是「現在」，右端是 8 小時後；每個會重置的額度一個圓點，下方標名稱與時間。
/// `Animatable`：圓點依序出發需要逐格的進度（只改終點的話 SwiftUI 只會把位置線性補間，沒有先後）。
struct ResetTimeline: View, Animatable {
    let resets: [UpcomingReset]
    let stale: Bool
    /// 圓點滑到位置的進度（0→1）
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    @Environment(\.panelMotion) private var motion

    private static let labelWidth: CGFloat = 72

    var body: some View {
        if resets.isEmpty && motion.departing.isEmpty {
            HStack(spacing: 6) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 3)
            }
            .overlay(alignment: .leading) {
                Text("未來 8 小時沒有額度重置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
                    .offset(y: 14)
            }
            .frame(height: 30, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("未來 8 小時沒有額度重置")
        } else {
            let rows = labelRows()
            GeometryReader { geo in
                let width = geo.size.width - 8
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: geo.size.width, height: 3).offset(y: 6)
                    // 有「剛重置」時它的標籤就在現在的位置，不另外寫「現在」
                    if !showsJustReset {
                        Text("現在").font(.caption2).foregroundStyle(.secondary).offset(y: 18)
                    }
                    ForEach(Array(resets.enumerated()), id: \.offset) { index, reset in
                        let x: CGFloat = 4 + width * CGFloat(reset.position * stagger(index))
                        dot(reset.provider)
                            .position(x: x, y: 7.5)
                        VStack(spacing: 0) {
                            Text(Self.name(reset))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Group {
                                if reset.justReset {
                                    // 重置時間已過、收集器還沒拿到新的重置時間
                                    Text("剛重置")
                                } else {
                                    Text(reset.resetsAt, format: .dateTime.hour().minute())
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        }
                        .lineLimit(1)
                        .frame(width: Self.labelWidth)
                        .position(x: Self.labelX(x, width: geo.size.width), y: 34 + CGFloat(rows[index]) * 30)
                        .opacity(stagger(index))
                    }
                    // 額度重置：該圓點在「現在」的位置放大淡出（服務圖示同時閃光芒）
                    ForEach(motion.departing.keys.sorted(), id: \.self) { key in
                        let progress = motion.departing[key] ?? 1
                        dot(String(key.split(separator: "/").first ?? ""))
                            .scaleEffect(1 + 1.2 * progress)
                            .opacity(1 - progress)
                            .position(x: 4, y: 7.5)
                    }
                }
            }
            .frame(height: 54 + CGFloat(rows.max() ?? 0) * 30)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var showsJustReset: Bool { resets.contains(where: \.justReset) }

    /// 「Claude 5h」「Codex 每週」
    static func name(_ reset: UpcomingReset) -> String {
        name(provider: reset.provider, window: reset.window)
    }

    static func name(provider: String, window: UsageWindow) -> String {
        window.id == "five_hour" ? "\(ProviderInfo.displayName(provider)) 5h"
            : ProviderWindow(provider: provider, window: window).displayName
    }

    /// 標籤置中在圓點下方，但不超出時間軸兩端
    static func labelX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x, labelWidth / 2), width - labelWidth / 2)
    }

    private func dot(_ provider: String) -> some View {
        Circle()
            .fill(stale ? AnyShapeStyle(UsageColors.stale) : AnyShapeStyle(UsageColors.provider(provider)))
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
    }

    /// 圓點依序滑到位置：第 i 個晚 0.08 開始。
    private func stagger(_ index: Int) -> Double {
        let delay = 0.08 * Double(index)
        let span = max(1 - 0.08 * Double(max(resets.count - 1, 0)), 0.4)
        let t = min(max((progress - delay) / span, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    /// 標籤太近時換到下一行（依時間軸寬約 300pt 估計；標籤寬 72pt）。
    private func labelRows() -> [Int] {
        var rows: [Int] = []
        // 第一行最左邊有「現在」（約 28pt）：標籤中心要在 68pt 以後才不會蓋到，否則換行
        var lastX: [Int: Double] = showsJustReset ? [:] : [0: 68 - Double(Self.labelWidth)]
        for reset in resets {
            let x = reset.position * 300
            let row = (0..<4).first { r in lastX[r].map { x - $0 >= Double(Self.labelWidth) } ?? true } ?? 0
            rows.append(row)
            lastX[row] = x
        }
        return rows
    }

    private var accessibilityText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let items = resets.map { reset in
            let name = ProviderWindow(provider: reset.provider, window: reset.window).displayName
            return reset.justReset ? "\(name) 剛重置" : "\(name) \(formatter.string(from: reset.resetsAt)) 重置"
        }
        return "未來 8 小時：" + items.joined(separator: "，")
    }
}

/// 「✶ 每週額度照目前速度可撐到 週五晚上 · 週日 23:00 重置」
struct ForecastLine: View {
    let forecast: WeeklyForecast
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            ProviderIcon(forecast.provider)
                .foregroundStyle(UsageColors.provider(forecast.provider))
                .frame(width: 11, height: 11)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Group {
                switch forecast.outcome {
                case let .runsOut(at):
                    Text("每週額度照目前速度可撐到 ") + Text(WeeklyForecast.dayPart(at)).fontWeight(.semibold).foregroundColor(UsageColors.notice)
                case .lastsUntilReset:
                    Text("每週額度照目前速度撐得到重置")
                }
            }
            Text("· \(Self.resetText(forecast.resetsAt))").foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .help(forecast.usesRecentRate ? "依最近 24 小時的速度估計" : "歷史資料還不夠，依本週開始至今的平均速度估計")
        .accessibilityElement(children: .combine)
    }

    static func resetText(_ date: Date) -> String {
        let weekday = WeeklyForecast.dayPart(date).prefix(2)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(weekday) \(formatter.string(from: date)) 重置"
    }
}

// MARK: - 骨架畫面（FR-46）

/// 歷史不足時的骨架：灰色的佔位形狀＋說明；打開面板時一道光由左往右掃過（最多 3 次）。
struct HistorySkeleton: View {
    let status: HistoryStore.Status
    var height: CGFloat = 96

    @Environment(\.panelMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05))
                SkeletonCurve()
                    .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(12)
            }
            .frame(height: height)
            .overlay { ShimmerOverlay(progress: motion.shimmer) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    private var message: String {
        switch status {
        case .olderSchema: "收集器的版本較舊，請重新執行 collector/scripts/install-launchd.sh"
        case .failed: "無法讀取額度歷史（history.sqlite3）"
        default: "正在收集，幾小時後開始會有資料"
        }
    }

}

/// 骨架的掃光：進度 0→3 掃三次（整數時光在畫面外）。`Animatable` 讓每一格都拿到中間的進度，
/// 否則 0 和 3 的小數部分都是 0，掃光不會出現。
private struct ShimmerOverlay: View, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let phase = progress - floor(progress)
        if phase > 0 {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, Color.primary.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: (phase * 1.4 - 0.4) * geo.size.width)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct SkeletonCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.55),
                   control1: CGPoint(x: rect.width * 0.35, y: rect.minY + rect.height * 0.15),
                   control2: CGPoint(x: rect.width * 0.65, y: rect.minY + rect.height * 0.6))
        return p
    }
}

/// 斜線（沒有紀錄的時段）
private func drawHatch(_ context: inout GraphicsContext, in rect: CGRect, color: Color, spacing: CGFloat = 5) {
    guard rect.width > 0, rect.height > 0 else { return }
    var path = Path()
    var x = rect.minX - rect.height
    while x < rect.maxX {
        path.move(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
        x += spacing
    }
    var clipped = context
    clipped.clip(to: Path(rect))
    clipped.stroke(path, with: .color(color), lineWidth: 1)
}

// MARK: - 本週額度走勢（FR-41）

struct TrendCardContent: View {
    let options: [HistoryWindowOption]
    let selected: HistoryWindowOption
    let history: QuotaHistory
    let status: HistoryStore.Status
    let stale: Bool
    let now: Date
    let select: (HistoryWindowOption) -> Void

    @Environment(\.panelAnimates) private var animates

    var body: some View {
        let trend = QuotaTrend(provider: selected.provider, window: selected.window, history: history, now: now)
        VStack(alignment: .leading, spacing: 8) {
            if options.count > 1 {
                HistoryWindowChips(options: options, selected: selected, stale: stale, select: select)
            }
            Group {
                if status.canRead && trend.hasEnoughData {
                    TrendChartBlock(option: selected, trend: trend, stale: stale, now: now)
                        .id(selected.id)
                        .transition(.opacity)
                } else {
                    HistorySkeleton(status: status)
                        .transition(.opacity)
                }
            }
            .animation(animates ? PanelTiming.crossfade : nil, value: selected.id)
            .animation(animates ? PanelTiming.crossfade : nil, value: trend.hasEnoughData)
        }
    }
}

private struct TrendChartBlock: View {
    let option: HistoryWindowOption
    let trend: QuotaTrend
    let stale: Bool
    let now: Date

    @Environment(\.panelMotion) private var motion

    private var current: Double { trend.points.last?.remainingPct ?? 100 }

    var body: some View {
        let tint = stale ? UsageColors.stale : UsageColors.provider(option.provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if option.window.isReset(at: now) {
                    // 重置時間已過、收集器還沒寫入新一輪：曲線是上一輪的，不把它的最後一點當成目前剩餘（FR-26）
                    Text("已重置")
                    Text("· 等待新一輪的資料").foregroundStyle(.secondary)
                } else {
                    Text("目前剩 \(Int(current.rounded()))%")
                    if option.window.resetsAt != nil {
                        Text("· 照時間應剩 \(Int(trend.expectedRemaining(at: now).rounded()))%").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            TrendChart(trend: trend, tint: tint, progress: motion.trend)
                .frame(height: 96)
            HStack {
                Text(Self.edgeText(trend.span.start, long: trend.span.duration > 86400))
                Spacer()
                Text(option.window.resetsAt == nil ? "現在" : "重置 \(Self.edgeText(trend.span.end, long: trend.span.duration > 86400))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            TrendLegend(tint: tint, hasGaps: !trend.gaps.isEmpty)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    static func edgeText(_ date: Date, long: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if long { return "\(WeeklyForecast.dayPart(date).prefix(2)) \(formatter.string(from: date))" }
        return formatter.string(from: date)
    }

    private var accessibilityText: String {
        var text: String
        if option.window.isReset(at: now) {
            text = "\(option.item.displayName)走勢：已重置，等待新一輪的資料"
        } else {
            text = "\(option.item.displayName)走勢：目前剩 \(Int(current.rounded()))%"
            if option.window.resetsAt != nil { text += "，照時間應剩 \(Int(trend.expectedRemaining(at: now).rounded()))%" }
        }
        if !trend.gaps.isEmpty { text += "，有 \(trend.gaps.count) 段時間沒有紀錄" }
        return text
    }
}

/// 剩餘 % 曲線＋漸層、照時間的預期（虛線）、沒有紀錄的時段（斜線，中間以點線連接）。
/// 曲線依 `progress` 由左往右描繪，最後的圓點在描繪完時輕彈一下。
struct TrendChart: View, Animatable {
    let trend: QuotaTrend
    let tint: Color
    var progress: Double

    // Canvas 的繪圖不會被補間：讓 SwiftUI 逐格更新 progress，曲線才會由左往右描繪
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 5
            let plot = CGRect(x: 0, y: inset, width: size.width - inset, height: size.height - 2 * inset)
            let span = max(trend.span.duration, 1)
            func x(_ date: Date) -> CGFloat { plot.minX + plot.width * CGFloat(date.timeIntervalSince(trend.span.start) / span) }
            func y(_ pct: Double) -> CGFloat { plot.minY + plot.height * CGFloat(1 - pct / 100) }

            // 沒有紀錄的時段：淡入
            let gapOpacity = min(max(progress * 2, 0), 1)
            for gap in trend.gaps {
                let rect = CGRect(x: x(gap.start), y: 0, width: max(x(gap.end) - x(gap.start), 1), height: size.height)
                context.fill(Path(rect), with: .color(Color.primary.opacity(0.04 * gapOpacity)))
                drawHatch(&context, in: rect, color: Color.secondary.opacity(0.35 * gapOpacity))
            }
            // 基準線
            context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y(0))); p.addLine(to: CGPoint(x: plot.maxX, y: y(0))) },
                           with: .color(Color.primary.opacity(0.08)), lineWidth: 1)
            // 照時間的預期
            context.stroke(Path { p in p.move(to: CGPoint(x: x(trend.span.start), y: y(100))); p.addLine(to: CGPoint(x: x(trend.span.end), y: y(0))) },
                           with: .color(Color.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))

            guard let first = trend.points.first, let last = trend.points.last else { return }
            // 描繪進度：只畫到 progress 的位置
            let reveal = x(first.ts) + (x(last.ts) - x(first.ts)) * CGFloat(min(max(progress, 0), 1))
            var drawing = context
            drawing.clip(to: Path(CGRect(x: 0, y: 0, width: reveal + 1, height: size.height)))

            var solid = Path(), dotted = Path(), area = Path()
            var segmentStart: CGPoint?
            for (a, b) in zip(trend.points, trend.points.dropFirst()) {
                let pa = CGPoint(x: x(a.ts), y: y(a.remainingPct)), pb = CGPoint(x: x(b.ts), y: y(b.remainingPct))
                if b.ts.timeIntervalSince(a.ts) > QuotaHistory.gapThreshold {
                    dotted.move(to: pa); dotted.addLine(to: pb)
                    if let s = segmentStart { area.addLine(to: CGPoint(x: pa.x, y: y(0))); area.addLine(to: CGPoint(x: s.x, y: y(0))); area.closeSubpath() }
                    segmentStart = nil
                } else {
                    if segmentStart == nil { segmentStart = pa; solid.move(to: pa); area.move(to: pa) }
                    solid.addLine(to: pb); area.addLine(to: pb)
                }
            }
            if let s = segmentStart, let end = trend.points.last {
                area.addLine(to: CGPoint(x: x(end.ts), y: y(0))); area.addLine(to: CGPoint(x: s.x, y: y(0))); area.closeSubpath()
            }
            drawing.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0.02)]),
                                                     startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            drawing.stroke(solid, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            drawing.stroke(dotted, with: .color(tint.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.5, 3]))

            // 最後的圓點：描繪到終點時出現並輕彈一下
            if progress >= 0.85 {
                let bounce = min(max((progress - 0.85) / 0.15, 0), 1)
                let r: CGFloat = 3.5 * (1 + 0.5 * CGFloat(sin(.pi * bounce)))
                let p = CGPoint(x: x(last.ts), y: y(last.remainingPct))
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(tint))
            }
        }
    }
}

private struct TrendLegend: View {
    let tint: Color
    let hasGaps: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 8, height: 8)
                Text("實際剩餘")
            }
            HStack(spacing: 4) {
                Canvas { context, size in
                    context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                                   with: .color(.secondary), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                }
                .frame(width: 12, height: 8)
                Text("照時間的預期")
            }
            if hasGaps { HatchSwatch(label: "沒有紀錄") }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct HatchSwatch: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Canvas { context, size in
                drawHatch(&context, in: CGRect(origin: .zero, size: size), color: .secondary, spacing: 3)
            }
            .frame(width: 9, height: 9)
            Text(label)
        }
    }
}

// MARK: - 額度消耗（FR-42）

struct ConsumptionCardHeader: View {
    var body: some View {
        HStack {
            PanelCardTitle(text: PanelSection.consumption.title)
            Spacer(minLength: 4)
            Text("整個帳號")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .help("額度是整個帳號共用的：包含手機 App、網頁、其他電腦與雲端的使用")
                .accessibilityLabel("範圍：整個帳號，包含手機、網頁與所有電腦")
        }
    }
}

struct ConsumptionCardContent: View {
    let options: [HistoryWindowOption]
    let selected: HistoryWindowOption
    let history: QuotaHistory
    let status: HistoryStore.Status
    let stale: Bool
    let now: Date
    let select: (HistoryWindowOption) -> Void

    @Environment(\.panelAnimates) private var animates

    var body: some View {
        let consumption = QuotaConsumption(provider: selected.provider, windowID: selected.window.id, history: history, now: now)
        VStack(alignment: .leading, spacing: 8) {
            if options.count > 1 {
                HistoryWindowChips(options: options, selected: selected, stale: stale, select: select)
            }
            Group {
                if status.canRead && consumption.hasEnoughData {
                    ConsumptionBlock(option: selected, consumption: consumption, stale: stale, now: now)
                        .id(selected.id)
                        .transition(.opacity)
                } else {
                    HistorySkeleton(status: status, height: 80)
                        .transition(.opacity)
                }
            }
            .animation(animates ? PanelTiming.crossfade : nil, value: selected.id)
            .animation(animates ? PanelTiming.crossfade : nil, value: consumption.hasEnoughData)
        }
    }
}

private struct ConsumptionBlock: View {
    let option: HistoryWindowOption
    let consumption: QuotaConsumption
    let stale: Bool
    let now: Date

    @State private var hovered: Int?

    // 卡片內容寬 300pt（面板 360 − 兩側內距 16 − 卡片內距 14）：26 + 4 + 24 × 11 = 294
    private static let labelWidth: CGFloat = 26
    private static let cell: CGFloat = 9.5
    private static let gap: CGFloat = 1.5

    var body: some View {
        let tint = stale ? UsageColors.stale : UsageColors.provider(option.provider)
        let peak = max(consumption.hours.compactMap(\.consumed).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .trailing, spacing: Self.gap) {
                    ForEach(0..<consumption.days, id: \.self) { day in
                        Text(Self.dayLabel(consumption.hours[day * 24].start))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: Self.labelWidth, height: Self.cell, alignment: .trailing)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Canvas { context, _ in
                        for (i, hour) in consumption.hours.enumerated() {
                            let rect = CGRect(x: CGFloat(i % 24) * (Self.cell + Self.gap), y: CGFloat(i / 24) * (Self.cell + Self.gap),
                                              width: Self.cell, height: Self.cell)
                            let shape = Path(roundedRect: rect, cornerRadius: 2)
                            if let consumed = hour.consumed {
                                let color = consumed > 0 ? tint.opacity(0.18 + 0.82 * min(consumed / peak, 1)) : Color.primary.opacity(0.07)
                                context.fill(shape, with: .color(color))
                                if hour.estimated { drawHatch(&context, in: rect, color: Color.primary.opacity(0.35), spacing: 3) }
                            } else if hour.start < now {
                                context.fill(shape, with: .color(Color.primary.opacity(0.03)))
                                drawHatch(&context, in: rect, color: Color.secondary.opacity(0.3), spacing: 3)
                            }
                            if i == hovered {
                                context.stroke(shape, with: .color(.primary), lineWidth: 1)
                            }
                        }
                    }
                    .frame(width: 24 * (Self.cell + Self.gap), height: CGFloat(consumption.days) * (Self.cell + Self.gap))
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point):
                            let col = Int(point.x / (Self.cell + Self.gap)), row = Int(point.y / (Self.cell + Self.gap))
                            hovered = (0..<24).contains(col) && (0..<consumption.days).contains(row) ? row * 24 + col : nil
                        case .ended:
                            hovered = nil
                        }
                    }
                    ZStack(alignment: .leading) {
                        ForEach([0, 6, 12, 18], id: \.self) { h in
                            Text("\(h)").font(.system(size: 9)).foregroundStyle(.secondary)
                                .offset(x: CGFloat(h) * (Self.cell + Self.gap))
                        }
                    }
                    .frame(height: 11, alignment: .leading)
                }
            }
            Text(hoverText ?? "每格一小時，顏色越深用越多")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            DailyTotals(consumption: consumption, tint: tint)
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    Text("少")
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level == 0 ? Color.primary.opacity(0.07) : tint.opacity(0.18 + 0.82 * level))
                            .frame(width: 9, height: 9)
                    }
                    Text("多")
                }
                HatchSwatch(label: "沒有紀錄；色塊上的斜線＝平均分配的估計")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var hoverText: String? {
        guard let hovered, consumption.hours.indices.contains(hovered) else { return nil }
        let hour = consumption.hours[hovered]
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let h = Calendar.current.component(.hour, from: hour.start)
        let when = "\(formatter.string(from: hour.start)) \(WeeklyForecast.dayPart(hour.start).prefix(2)) \(h):00–\(h + 1):00"
        guard let consumed = hour.consumed else { return "\(when)：沒有紀錄" }
        return "\(when)：用了 \(Self.pct(consumed))\(hour.estimated ? "（估計）" : "")"
    }

    static func pct(_ value: Double) -> String {
        value >= 10 || value == value.rounded() ? "\(Int(value.rounded()))%" : String(format: "%.1f%%", value)
    }

    static func dayLabel(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "今天" : String(WeeklyForecast.dayPart(date).prefix(2))
    }

    private var accessibilityText: String {
        let totals = consumption.dailyTotals.map { day in
            "\(Self.dayLabel(day.start)) \(day.consumed.map(Self.pct) ?? "沒有紀錄")"
        }
        return "\(option.item.displayName)每天消耗（整個帳號）：" + totals.joined(separator: "，")
    }
}

/// 每天的合計（走勢）：7 根小長條，下方標星期與百分比。
private struct DailyTotals: View {
    let consumption: QuotaConsumption
    let tint: Color

    var body: some View {
        let totals = consumption.dailyTotals
        let peak = max(totals.compactMap(\.consumed).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(totals.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.05))
                        if let consumed = day.consumed {
                            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(day.estimated ? 0.55 : 1))
                                .frame(height: max(26 * consumed / peak, consumed > 0 ? 2 : 0))
                        }
                    }
                    .frame(height: 26)
                    Text(day.consumed.map(ConsumptionBlock.pct) ?? "–")
                        .font(.system(size: 9).monospacedDigit())
                    Text(ConsumptionBlock.dayLabel(day.start))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
