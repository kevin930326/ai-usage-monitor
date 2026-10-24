import SwiftUI
import UsageKit
import UsageKitUI

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
