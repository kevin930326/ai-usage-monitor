import ActivityKit
import SwiftUI
import UsageKit
import UsageKitUI
import WidgetKit

struct UsageLiveActivity: Widget {
    var body: some WidgetConfiguration {
        // FR-27 手錶精簡版面需要 `.supplementalActivityFamilies([.small])`（iOS 18 API）。
        // 部署目標為 iOS 17 時無法以 #available 條件套用（WidgetConfiguration 不支援分支），
        // 因此暫不開啟；watchOS 11 仍會以動態島的 compact 版面顯示卡片。
        // 若決定擴充最低支援 iOS 18：把 UsageWidget 的部署目標改為 18.0 並在下一行加上該修飾器。
        UsageActivityConfiguration.make()
    }
}

@MainActor
enum UsageActivityConfiguration {
    static func make() -> some WidgetConfiguration {
        ActivityConfiguration(for: UsageActivityAttributes.self) { context in
            ActivityContentView(state: context.state, systemStale: context.isStale)
        } dynamicIsland: { context in
            let state = context.state
            let stale = context.isStale || state.isStale()
            let tightest = state.tightest()
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let tightest {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(ProviderInfo.displayName(tightest.provider)) · \(tightest.window.label)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            PercentText(item: tightest, mode: state.mode, stale: stale, size: 28)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let tightest {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(state.mode.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ResetLabel(window: tightest.window, now: .now)
                                .font(.caption)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ForEach(state.providers) { provider in
                            ProviderActivityRow(provider: provider, mode: state.mode, stale: stale, now: .now)
                        }
                        ActivityFooter(updatedAt: state.updatedAt, stale: stale)
                    }
                }
            } compactLeading: {
                if let tightest {
                    Text(ProviderInfo.displayName(tightest.provider).prefix(1))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ActivityStyle.tint(tightest.window, stale: stale, now: .now))
                }
            } compactTrailing: {
                if let tightest {
                    PercentText(item: tightest, mode: state.mode, stale: stale, size: 14)
                }
            } minimal: {
                if let tightest {
                    PercentText(item: tightest, mode: state.mode, stale: stale, size: 12)
                }
            }
        }
    }
}

/// 依 activityFamily 選擇版面：手錶（.small）用精簡版，其他用完整鎖定畫面。
struct ActivityContentView: View {
    let state: UsageActivityState
    let systemStale: Bool

    var body: some View {
        if #available(iOS 18.0, *) {
            FamilyAwareActivityView(state: state, systemStale: systemStale)
        } else {
            LockScreenActivityView(state: state, systemStale: systemStale)
        }
    }
}

@available(iOS 18.0, *)
private struct FamilyAwareActivityView: View {
    let state: UsageActivityState
    let systemStale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            WatchActivityView(state: state, systemStale: systemStale)
        default:
            LockScreenActivityView(state: state, systemStale: systemStale)
        }
    }
}

private struct PercentText: View {
    let item: ProviderWindow
    let mode: UsageDisplayMode
    let stale: Bool
    let size: CGFloat

    var body: some View {
        Text("\(Int(item.window.displayedPct(mode, at: .now).rounded()))%")
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(ActivityStyle.tint(item.window, stale: stale, now: .now))
    }
}
