import AppIntents
import SwiftUI
import UsageKit
import UsageKitUI

// 主畫面小工具的小、大尺寸版面。放在 Shared/ 讓 App 也能渲染同一份畫面（截圖比對用）；
// 中型沿用 LockScreenActivityView，鎖定畫面小工具用 UsageKitUI 的 ComplicationView。

/// 小：只顯示剩餘最少的額度（FR-15）。
struct SmallUsageView: View {
    let state: UsageActivityState
    let now: Date

    private var stale: Bool { state.isStale(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let item = state.tightest(at: now) {
                let pct = item.window.displayedPct(state.mode, at: now)
                HStack(spacing: 5) {
                    ProviderIcon(item.provider)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(stale ? Color.gray : UsageColors.provider(item.provider))
                    Text(item.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .accessibilityHidden(true)
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(stale ? .secondary : .primary)
                    .accessibilityLabel(item.leastRemainingAccessibilityLabel(mode: state.mode, at: now))
                Text(state.mode.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                ProgressView(value: pct, total: 100)
                    .tint(UsageColors.bar(item.window, provider: item.provider, stale: stale, now: now))
                Label {
                    ResetLabel(window: item.window, now: now)
                } icon: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else if state.providers.isEmpty {
                NoProvidersNotice()
            } else {
                Label("沒有資料", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            Spacer(minLength: 0)
            ActivityFooter(updatedAt: state.updatedAt, stale: stale, refreshError: state.refreshError)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

/// 大：剩餘最少的額度 + 每個服務的所有可見額度（與 App 主畫面相同的 `UsageWindowRow`）。
/// 只用一個服務時（收集器沒有啟用另一個）放大剩餘最少的額度、額度改單欄，不留下半部空白。
struct LargeUsageView: View {
    let state: UsageActivityState
    let now: Date
    /// 小工具傳自己的 Intent（重新整理小工具），App 截圖用預設
    var refreshIntent: any AppIntent = RefreshUsageIntent()

    private var stale: Bool { state.isStale(at: now) }
    private var single: Bool { state.providers.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: single ? 16 : 12) {
            if let tightest = state.tightest(at: now) {
                if single {
                    LargeTightestHeader(item: tightest, mode: state.mode, stale: stale, now: now)
                } else {
                    TightestHeader(item: tightest, mode: state.mode, stale: stale, now: now)
                }
            }
            ForEach(state.providers) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ProviderIcon(provider.key)
                            .frame(width: 14, height: 14)
                            .foregroundStyle(stale ? Color.gray : UsageColors.provider(provider.key))
                        Text(provider.displayName)
                            .font(.subheadline.weight(.semibold))
                        if let plan = provider.plan {
                            Text(plan)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if let error = provider.error {
                        // 單一服務失敗不影響其他服務（FR-12）
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(UsageColors.notice)
                            .lineLimit(2)
                    } else {
                        // 兩欄，額度多於兩個時換行，不會把頁尾擠出畫面；只有一個服務且額度不多時改單欄
                        let oneColumn = single && provider.windows.count <= 3
                        LazyVGrid(columns: oneColumn ? [GridItem(.flexible())]
                                                     : [GridItem(.flexible(), spacing: 14), GridItem(.flexible())],
                                  alignment: .leading, spacing: oneColumn ? 14 : 8) {
                            ForEach(provider.windows) { window in
                                UsageWindowRow(window: window, provider: provider.key, display: state.mode,
                                               dimmed: stale, now: now)
                            }
                        }
                    }
                }
            }
            if state.providers.isEmpty {
                // 置中，不要只佔左上角
                Spacer(minLength: 0)
                NoProvidersNotice()
            }
            Spacer(minLength: 0)
            ActivityFooter(updatedAt: state.updatedAt, stale: stale, refreshError: state.refreshError) {
                RefreshButton(intent: refreshIntent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

/// 大尺寸只有一個服務時剩餘最少的額度：大字百分比與重置倒數。
struct LargeTightestHeader: View {
    let item: ProviderWindow
    let mode: UsageDisplayMode
    let stale: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(item.window.label) · \(mode.label)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(item.window.displayedPct(mode, at: now).rounded()))%")
                    .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(stale ? .secondary : .primary)
                    .accessibilityLabel(item.leastRemainingAccessibilityLabel(mode: mode, at: now))
                Spacer()
                ResetLabel(window: item.window, now: now)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
