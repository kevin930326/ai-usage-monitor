import ActivityKit
import SwiftUI
import UsageKit
import UsageKitUI
import WidgetKit

struct UsageLiveActivity: Widget {
    var body: some WidgetConfiguration {
        // .small：Apple Watch 智慧型堆疊用手錶專用的精簡版面（FR-27）。
        // 此 API 需要 iOS 18，所以 Widget 擴充的部署目標是 18.0（App 本身仍支援 iOS 17）。
        UsageActivityConfiguration.make()
            .supplementalActivityFamilies([.small])
    }
}

@MainActor
enum UsageActivityConfiguration {
    static func make() -> some WidgetConfiguration {
        ActivityConfiguration(for: UsageActivityAttributes.self) { context in
            ActivityContentView(state: context.state)
        } dynamicIsland: { context in
            let state = context.state
            // context.isStale 只用來觸發重繪，過期與否看資料時間（見 LockScreenActivityView）
            let stale = state.isStale()
            let tightest = state.tightest()
            return DynamicIsland {
                // 展開版面總高要在系統上限（約 160pt）內：只放剩餘最少的額度、各服務一行的 % 與細進度條、
                // 一行更新時間；更新按鈕在右上。各區另加內距，避免文字碰到動態島的圓角（Shared/ActivityViews.swift）
                DynamicIslandExpandedRegion(.leading) {
                    IslandLeading(state: state, now: .now)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandTrailing(state: state, now: .now) { RefreshButton() }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandBottom(state: state, stale: stale, now: .now)
                }
            } compactLeading: {
                if let tightest {
                    // 服務以原創圖示與識別色區分（FR-16），不用官方 logo
                    ProviderIcon(tightest.provider)
                        .frame(width: 18, height: 18)
                        .foregroundStyle(stale ? Color.gray : UsageColors.providerMark(tightest.provider))
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
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            WatchActivityView(state: state)
        default:
            LockScreenActivityView(state: state)
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
    }
}
