import SwiftUI
import UsageKit
import UsageKitUI

// 面板的卡片（FR-34、FR-36、FR-38，ADR-0008 第 2～4 節）。
// 文字一律 primary／secondary，顏色只用在圓環、進度條、服務圖示與提示文字（設計 skill 第 1 節）。

/// 可收合的卡片：標題列＋內容。收合動畫結束後移除內容視圖，不再計算或播放動畫。
struct PanelCard<Content: View>: View {
    let id: String
    let title: String
    @Binding var collapsed: Bool
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
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(90 * progress))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
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

/// 主圓環卡片的內容：最吃緊額度的雙圓環、大數字、服務、重置倒數、用量節奏。
struct RingCardContent: View {
    let item: ProviderWindow
    let stale: Bool
    let now: Date

    @Environment(\.panelMotion) private var motion

    private var remaining: Double { item.window.effectiveRemainingPct(at: now) }
    private var pace: UsagePace? { UsagePace(window: item.window, stale: stale, now: now) }

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
                HStack(spacing: 6) {
                    ProviderIcon(item.provider)
                        .foregroundStyle(stale ? AnyShapeStyle(UsageColors.stale) : AnyShapeStyle(UsageColors.provider(item.provider)))
                        .frame(width: 15, height: 15)
                        .modifier(GlowEffect(progress: motion.glow[item.provider] ?? 0, color: UsageColors.provider(item.provider)))
                    Text("\(ProviderInfo.displayName(item.provider)) · \(item.window.label)")
                        .font(.callout.weight(.semibold))
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    RollingPercent(value: remaining * motion.appear, font: .system(size: 40, weight: .bold, design: .rounded))
                    Text("%").font(.title3.weight(.semibold))
                }
                .foregroundStyle(stale ? .secondary : .primary)
                HStack(spacing: 4) {
                    Text("剩餘 ·")
                    PanelResetText(window: item.window, now: now)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let pace, pace.isTooFast {
                    PaceBadge(pace: pace, now: now)
                        .padding(.top, 2)
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

/// 「用得較快，約 N 分鐘後用完」（提示色，ADR-0008 第 4 節）。
struct PaceBadge: View {
    let pace: UsagePace
    let now: Date
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            if !compact {
                Circle().fill(UsageColors.notice).frame(width: 7, height: 7)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(UsageColors.notice)
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 3)
        .background(compact ? Color.clear : UsageColors.notice.opacity(0.12), in: Capsule())
    }

    private var text: String {
        guard let at = pace.exhaustsAt else { return "用得較快" }
        let minutes = max(Int((at.timeIntervalSince(now) / 60).rounded()), 1)
        if compact { return "用得較快" }
        return minutes >= 120 ? "用得較快，約 \(minutes / 60) 小時後用完" : "用得較快，約 \(minutes) 分鐘後用完"
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
            }
        }
    }
}

/// 一個額度：名稱、剩餘 %、進度條（含預期進度標記）、重置倒數、用得較快的提示。
struct QuotaRow: View {
    let window: UsageWindow
    let provider: String
    let stale: Bool
    let now: Date
    let showsMarker: Bool

    @Environment(\.panelMotion) private var motion
    @Environment(\.panelAnimates) private var animates

    private var remaining: Double { window.effectiveRemainingPct(at: now) }
    private var pace: UsagePace? { UsagePace(window: window, stale: stale, now: now) }

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
            HStack(spacing: 4) {
                PanelResetText(window: window, now: now)
                if let pace, pace.isTooFast {
                    Text("·")
                    PaceBadge(pace: pace, now: now, compact: true)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary)
                        .frame(width: 2.5, height: geo.size.height + 6)
                        .offset(x: geo.size.width * min(max(expected, 0), 1) - 1.25)
                        .opacity(markerOpacity)
                        .accessibilityLabel("預期剩餘 \(Int((expected * 100).rounded()))%")
                }
            }
        }
    }
}
