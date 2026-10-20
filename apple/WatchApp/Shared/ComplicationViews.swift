import SwiftUI
import UsageKit
import UsageKitUI
import WidgetKit

/// 錶面複雜功能（FR-28）：最吃緊額度的剩餘 % 與分級顏色。
/// 尺寸以參數傳入，App 也能用 ImageRenderer 輸出同一個畫面。
struct ComplicationView: View {
    let snapshot: UsageSnapshot?
    let family: WidgetFamily
    var now: Date = .now

    private var item: ProviderWindow? { snapshot?.tightestWindow(at: now) }
    private var stale: Bool { snapshot?.isStale(now: now) ?? true }
    private var pct: Double { item?.window.effectiveRemainingPct(at: now) ?? 0 }
    private var tint: Color { stale ? .gray : (item?.window.effectiveSeverity(at: now).color ?? .gray) }
    private var pctText: String { item.map { _ in "\(Int(pct.rounded()))" } ?? "--" }
    private var title: String {
        guard let item else { return "AI 用量" }
        return "\(ProviderInfo.displayName(item.provider)) \(item.window.label)"
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: pct, in: 0...100) {
                Text(item.map { String(ProviderInfo.displayName($0.provider).prefix(1)) } ?? "AI")
            } currentValueLabel: {
                Text(pctText).monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
        case .accessoryInline:
            Text(item == nil ? "AI 用量 --" : "\(title) \(pctText)%")
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .widgetAccentable()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(pctText)%")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint)
                    Text(stale && item != nil ? "已過期" : "剩餘")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Gauge(value: pct, in: 0...100) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
