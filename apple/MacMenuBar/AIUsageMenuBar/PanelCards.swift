import SwiftUI
import UsageKit
import UsageKitUI

// 面板的卡片（FR-34、FR-36、FR-38，ADR-0008 第 2～4 節）。
// 文字一律 primary／secondary，顏色只用在圓環、進度條、服務圖示與提示文字（設計 skill 第 1 節）。

/// 可收合的卡片：標題列＋內容。收合動畫結束後移除內容視圖，不再計算或播放動畫。
/// 標題列可以是文字（`title:`），或能用圖示＋名稱表達時直接放內容（`header:`，例如主圓環卡片）。
struct PanelCard<Header: View, Content: View>: View {
    let id: String
    /// VoiceOver 讀的標題
    let accessibilityTitle: String
    @Binding var collapsed: Bool
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    @Environment(\.panelAnimates) private var animates
    @Environment(\.panelMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 內容是否建立（收合動畫結束後才移除）
    @State private var contentAlive = true
    @State private var reveal: Double = 1

    /// Debug 截圖指定的進度優先，否則用卡片自己的狀態
    private var progress: Double { motion.reveal[id] ?? reveal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle()
            } label: {
                HStack(spacing: 6) {
                    header()
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(90 * progress))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(collapsed ? "已收合" : "已展開")
            .accessibilityHint("按一下收合或展開")

            if contentAlive || motion.reveal[id] != nil {
                VerticalReveal(progress: progress) {
                    content()
                        .padding(.top, 10)
                }
                .clipped()
                .opacity(reduceMotion ? (collapsed ? 0 : 1) : 1)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .modifier(HighlightEffect(progress: motion.highlight[id] ?? 0))
        .onAppear {
            contentAlive = !collapsed
            reveal = collapsed ? 0 : 1
        }
        .onChange(of: collapsed) { _, isCollapsed in
            apply(collapsed: isCollapsed)
        }
    }

    private func toggle() {
        collapsed.toggle()
    }

    private func apply(collapsed isCollapsed: Bool) {
        if !animates || reduceMotion {
            // 減少動態效果或面板未開啟：直接切換（只淡入淡出）
            withAnimation(reduceMotion && animates ? PanelTiming.reducedFade : nil) {
                reveal = isCollapsed ? 0 : 1
                contentAlive = !isCollapsed
            }
            return
        }
        if isCollapsed {
            withAnimation(PanelTiming.collapse) {
                reveal = 0
            } completion: {
                if collapsed { contentAlive = false }
            }
        } else {
            contentAlive = true
            withAnimation(PanelTiming.collapse) { reveal = 1 }
        }
    }
}

extension PanelCard where Header == PanelCardTitle {
    init(id: String, title: String, collapsed: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.init(id: id, accessibilityTitle: title, collapsed: collapsed, header: { PanelCardTitle(text: title) }, content: content)
    }
}

/// 一般卡片的文字標題（secondary）
struct PanelCardTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// 主圓環卡片的標題列：不加「剩餘最少」之類的標題文字，只放服務圖示＋服務名稱＋額度名稱（「Claude 每週」）。
/// 收合時也留著，看得出收起來的是哪一項。
struct RingCardHeader: View {
    let item: ProviderWindow
    let stale: Bool

    @Environment(\.panelMotion) private var motion

    var body: some View {
        HStack(spacing: 6) {
            ProviderIcon(item.provider)
                .foregroundStyle(stale ? AnyShapeStyle(UsageColors.stale) : AnyShapeStyle(UsageColors.provider(item.provider)))
                .frame(width: 15, height: 15)
                .modifier(GlowEffect(progress: motion.glow[item.provider] ?? 0, color: UsageColors.provider(item.provider)))
            Text(item.displayName)
                .font(.callout.weight(.semibold))
        }
    }
}

/// 主圓環卡片的內容：剩餘最少的額度的雙圓環、大數字、重置倒數、用量節奏（服務與額度名稱在標題列）。
struct RingCardContent: View {
    let item: ProviderWindow
    let stale: Bool
    let now: Date

    @Environment(\.panelMotion) private var motion
    @Environment(\.quotaHistory) private var history

    private var remaining: Double { item.window.effectiveRemainingPct(at: now) }
    /// 「照目前速度約 14:32 用完」：只用近期速度，資料不足時不顯示（ADR-0018 第 1 節）
    private var forecast: QuotaForecast? {
        QuotaForecast.current(window: item.window, provider: item.provider, history: history, stale: stale, now: now)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            DualRing(
                remaining: remaining / 100,
                timeRemaining: item.window.timeRemainingFraction(at: now),
                tint: UsageColors.bar(item.window, provider: item.provider, stale: stale, now: now),
                lineWidth: 9
            )
            .frame(width: 84, height: 84)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    RollingPercent(value: remaining * motion.appear, font: .system(size: 40, weight: .bold, design: .rounded))
                    Text("%").font(.title3.weight(.semibold))
                }
                .foregroundStyle(stale ? .secondary : .primary)
                // 畫面上不寫「剩餘最少」，VoiceOver 仍要說清楚這是哪一項
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.leastRemainingAccessibilityLabel(at: now))
                HStack(spacing: 4) {
                    Text("剩餘 ·").accessibilityHidden(true)
                    PanelResetText(window: item.window, now: now)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let forecast {
                    QuotaForecastLine(forecast: forecast, now: now, stacked: true)
                        .padding(.top, 2)
                } else if UsagePace(window: item.window, stale: stale, now: now)?.isTooFast == true {
                    TooFastNote().padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 雙圓環：外圈剩餘額度（服務識別色），內圈距離重置的剩餘時間（中性灰）。
struct DualRing: View {
    let remaining: Double
    let timeRemaining: Double?
    let tint: Color
    var lineWidth: CGFloat = 9

    @Environment(\.panelMotion) private var motion

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(remaining, 0), 1) * motion.appear)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let timeRemaining {
                Group {
                    Circle().stroke(Color.secondary.opacity(0.15), lineWidth: lineWidth * 0.55)
                    Circle()
                        .trim(from: 0, to: min(max(timeRemaining, 0), 1) * motion.appear)
                        .stroke(Color.secondary, style: StrokeStyle(lineWidth: lineWidth * 0.55, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(lineWidth * 1.6)
            }
        }
        // 線條以路徑為中心向外畫一半，內縮避免被卡片裁掉
        .padding(lineWidth / 2)
    }
}

/// 重置倒數；時間已過顯示「已重置」（FR-26）。與共用的 `ResetText` 相同，但面板關閉時不自動更新。
struct PanelResetText: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        if window.isReset(at: now) {
            Text("已重置")
        } else if let resetsAt = window.resetsAt {
            HStack(spacing: 0) {
                Text("重置 ")
                LiveRelativeText(date: resetsAt)
            }
        }
    }
}

/// 選單列有「太快」小點（平均速度）但資料不足以預測時間：只寫「用得較快」，不猜時間（ADR-0018 第 3 節）
struct TooFastNote: View {
    var body: some View {
        Label("用得較快", systemImage: "speedometer")
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            .font(.caption.weight(.medium))
            .foregroundStyle(UsageColors.notice)
    }
}

/// 「照目前速度約 14:32 用完・比平常快 2.1 倍」（ADR-0018 第 3 節）：不到 60 分鐘紅色，其他提示色；
/// 顏色以外一律有文字。取代原本的「用得較快，約 N 分鐘後用完」。
struct QuotaForecastLine: View {
    let forecast: QuotaForecast
    let now: Date
    /// 窄的地方（主圓環卡片）：倍數另起一行，不在中間斷開
    var stacked = false

    private var color: Color { forecast.urgent ? UsageColors.critical : UsageColors.notice }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: forecast.urgent ? "exclamationmark.circle.fill" : "speedometer")
                .imageScale(.small)
                .accessibilityHidden(true)
            if stacked {
                VStack(alignment: .leading, spacing: 1) {
                    Text(forecast.text(now: now))
                    if let faster = forecast.fasterText { Text(faster) }
                }
            } else {
                Text(forecast.line(now: now))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(forecast.spokenLine(now: now))
    }
}

/// 額度卡片的內容：各服務的可見額度（保留現有面板的所有資訊，FR-12、FR-26）。
struct QuotaCardContent: View {
    let snapshot: UsageSnapshot
    let stale: Bool
    let now: Date
    let showsMarker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(snapshot.orderedProviderKeys, id: \.self) { key in
                if let provider = snapshot.providers[key] {
                    ProviderQuota(key: key, provider: provider, stale: stale, now: now, showsMarker: showsMarker)
                }
            }
            if snapshot.hasNoProviders {
                NoProvidersNotice()
            }
        }
    }
}

private struct ProviderQuota: View {
    let key: String
    let provider: ProviderUsage
    let stale: Bool
    let now: Date
    let showsMarker: Bool

    @Environment(\.panelMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProviderIcon(key)
                    .foregroundStyle(stale ? AnyShapeStyle(UsageColors.stale) : AnyShapeStyle(UsageColors.provider(key)))
                    .frame(width: 15, height: 15)
                    .modifier(GlowEffect(progress: motion.glow[key] ?? 0, color: UsageColors.provider(key)))
                Text(ProviderInfo.displayName(key))
                    .font(.headline)
                if let plan = provider.plan {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            if let error = provider.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(UsageColors.notice)
                    .lineLimit(2)
            } else {
                ForEach(provider.visibleWindows) { window in
                    QuotaRow(window: window, provider: key, stale: stale, now: now, showsMarker: showsMarker)
                }
                if let credits = provider.resetCredits {
                    ResetCreditsLine(credits: credits, now: now)
                }
            }
        }
    }
}

/// 重置次數卷（FR-58）：「重置卷 2 張 · 最早 11/20 到期」，0 張時不顯示；滑鼠移上去列出每張的到期時間。
struct ResetCreditsLine: View {
    let credits: ResetCredits
    let now: Date

    var body: some View {
        if let summary = credits.summary(at: now) {
            HStack(spacing: 5) {
                Image(systemName: "ticket")
                    .accessibilityHidden(true)
                Text(summary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .help(credits.detailLines(at: now).joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(credits.accessibilityLabel(at: now) ?? summary)
            .accessibilityHint(credits.detailLines(at: now).joined(separator: "，"))
        }
    }
}

/// 一個額度：名稱、剩餘 %、進度條（含預期進度標記）、重置倒數、會在重置前用完時的預測。
struct QuotaRow: View {
    let window: UsageWindow
    let provider: String
    let stale: Bool
    let now: Date
    let showsMarker: Bool

    @Environment(\.panelMotion) private var motion
    @Environment(\.panelAnimates) private var animates
    @Environment(\.quotaHistory) private var history

    private var remaining: Double { window.effectiveRemainingPct(at: now) }
    private var forecast: QuotaForecast? {
        QuotaForecast.current(window: window, provider: provider, history: history, stale: stale, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.callout)
                Spacer(minLength: 4)
                Text("\(Int(remaining.rounded()))%")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            QuotaBar(
                fraction: remaining / 100 * motion.appear,
                expected: showsMarker ? window.expectedRemainingPct(at: now).map { $0 / 100 } : nil,
                tint: UsageColors.bar(window, provider: provider, stale: stale, now: now),
                markerOpacity: motion.marker
            )
            .frame(height: 7)
            // 資料更新時只動變化的那一條：值沒變的進度條不會有動畫
            .animation(animates ? PanelTiming.barUpdate : nil, value: remaining)
            PanelResetText(window: window, now: now)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let forecast {
                QuotaForecastLine(forecast: forecast, now: now)
            } else if UsagePace(window: window, stale: stale, now: now)?.isTooFast == true {
                TooFastNote()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 自繪進度條（macOS 的 ProgressView 在非作用中視窗會忽略 tint），上面有預期進度標記。
struct QuotaBar: View {
    let fraction: Double
    let expected: Double?
    let tint: Color
    var markerOpacity: Double = 1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
                if let expected {
                    // 照時間比例應剩多少：比標記短＝用得比預期快
                    // 說明（「照時間比例，現在應剩 2%」）滑鼠移上去顯示，VoiceOver 也會讀
                    let help = UsageWindow.expectedRemainingDescription(pct: expected * 100)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary)
                        .frame(width: 2.5, height: geo.size.height + 6)
                        // 標記只有 2.5pt 寬，滑鼠感應範圍放寬到 12pt
                        .frame(width: Self.markerHitWidth)
                        .contentShape(Rectangle())
                        .help(help)
                        .offset(x: geo.size.width * min(max(expected, 0), 1) - Self.markerHitWidth / 2)
                        .opacity(markerOpacity)
                        .accessibilityLabel(help)
                }
            }
        }
    }

    static let markerHitWidth: CGFloat = 12
}

/// 卡片亮一下（點通知打開面板時，ADR-0010 第四階段：0.6 秒）：進度 0→1 之間邊框與底色亮起再消失。
struct HighlightEffect: ViewModifier, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let intensity = progress > 0 && progress < 1 ? sin(.pi * progress) : 0
        content
            .background(Color.accentColor.opacity(0.14 * intensity), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.8 * intensity), lineWidth: 2))
    }
}
