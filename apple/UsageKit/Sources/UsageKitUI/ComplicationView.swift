// SwiftUI 只有 Apple 平台有；Linux CI 只編譯、測試 UsageKit
#if canImport(SwiftUI) && canImport(WidgetKit)

import SwiftUI
import UsageKit
import WidgetKit

/// 錶面複雜功能（FR-28）與 iPhone 鎖定畫面小工具共用：剩餘最少的額度的百分比，
/// 進度條與服務標示用 FR-16 的顏色。尺寸以參數傳入，App 也能用 ImageRenderer 輸出同一個畫面。
/// 過期門檻依平台傳入：手錶 `UsageSnapshot.watchStaleAfter`、iPhone `UsageSnapshot.staleAfter`（FR-11）。
public struct ComplicationView: View {
    let snapshot: UsageSnapshot?
    let family: WidgetFamily
    var mode: UsageDisplayMode
    var staleAfter: TimeInterval
    var now: Date

    public init(snapshot: UsageSnapshot?, family: WidgetFamily, mode: UsageDisplayMode = .remaining,
                staleAfter: TimeInterval = UsageSnapshot.watchStaleAfter, now: Date = .now) {
        self.snapshot = snapshot
        self.family = family
        self.mode = mode
        self.staleAfter = staleAfter
        self.now = now
    }

    private var item: ProviderWindow? { snapshot?.tightestWindow(at: now) }
    private var stale: Bool { snapshot?.isStale(now: now, after: staleAfter) ?? true }
    private var pct: Double { item?.window.displayedPct(mode, at: now) ?? 0 }
    private var tint: Color {
        guard let item else { return UsageColors.stale }
        return UsageColors.bar(item.window, provider: item.provider, stale: stale, now: now)
    }
    private var pctText: String { item.map { _ in "\(Int(pct.rounded()))" } ?? "--" }
    private var noProviders: Bool { snapshot?.hasNoProviders ?? false }
    private var title: String {
        guard let item else { return noProviders ? ProviderInfo.noProvidersTitle : "AI 用量" }
        return "\(ProviderInfo.displayName(item.provider)) \(item.window.label)"
    }

    public var body: some View {
        if let item {
            // 畫面上只有圖示＋名稱＋百分比，VoiceOver 說完整的「剩餘最少的額度：Claude 每週，剩 67%」
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.leastRemainingAccessibilityLabel(mode: mode, at: now) + (stale ? "，資料已過期" : ""))
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: pct, in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                // accessoryCircularCapacity 只顯示 currentValueLabel：服務標示與百分比疊在圓圈內，
                // 和動態島一樣用原創圖示與識別色區分服務（不用官方 logo）；
                // 圖示是 template，單色／主題色錶面由系統換色
                VStack(spacing: 0) {
                    if let item {
                        ProviderIcon(item.provider)
                            .frame(width: 13, height: 13)
                            .foregroundStyle(stale ? Color.gray : UsageColors.providerMark(item.provider))
                            .widgetAccentable()
                    }
                    Text(pctText)
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.6)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
        case .accessoryInline:
            Text(item == nil ? "AI 用量 \(noProviders ? ProviderInfo.noProvidersTitle : "--")" : "\(title) \(pctText)%")
        default:
            if noProviders {
                // 沒有百分比可顯示，不畫空的進度條
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 用量")
                        .font(.headline)
                        .widgetAccentable()
                    Text(ProviderInfo.noProvidersTitle)
                        .font(.caption)
                    Text("請在 Mac 登入服務")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                rectangular
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .widgetAccentable()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(pctText)%")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(stale && item != nil ? "已過期" : mode.label)
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

#endif
