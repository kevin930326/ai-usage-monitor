import SwiftUI
import UsageKit
import UsageKitUI

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
