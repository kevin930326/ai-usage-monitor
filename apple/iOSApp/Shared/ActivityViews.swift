import AppIntents
import SwiftUI
import UsageKit
import UsageKitUI

// Live Activity 的畫面元件。放在 Shared/ 讓 App 也能渲染同一份畫面（除錯與文件截圖用）。

/// 鎖定畫面卡片（FR-8、11、12、15、16、17、26）。中型主畫面小工具也用這個版面，
/// 頁尾右側換成小工具自己的按鈕。
struct LockScreenActivityView<Trailing: View>: View {
    let state: UsageActivityState
    var now: Date = .now
    @ViewBuilder var trailing: Trailing

    // 只看資料時間（FR-11）。ActivityKit 的 `context.isStale` 在 staleDate 到時變成 true，
    // 但 staleDate 也可能是下一個重置時間，那時資料仍是新的，不能拿來判斷過期。
    private var stale: Bool { state.isStale(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tightest = state.tightest(at: now) {
                TightestHeader(item: tightest, mode: state.mode, stale: stale, now: now)
            }
            if state.providers.isEmpty {
                NoProvidersNotice()
            }
            ForEach(state.providers) { provider in
                ProviderActivityRow(provider: provider, mode: state.mode, stale: stale, now: now)
            }
            ActivityFooter(updatedAt: state.updatedAt, stale: stale, refreshError: state.refreshError) {
                trailing
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

extension LockScreenActivityView where Trailing == RefreshButton {
    init(state: UsageActivityState, now: Date = .now) {
        self.init(state: state, now: now) { RefreshButton() }
    }
}

/// 最吃緊的一項：大字百分比（FR-15）。
struct TightestHeader: View {
    let item: ProviderWindow
    let mode: UsageDisplayMode
    let stale: Bool
    let now: Date

    var body: some View {
        // 單行標題，讓整張卡片維持在鎖定畫面約 160pt 的高度內
        HStack(alignment: .center, spacing: 10) {
            Text("\(Int(item.window.displayedPct(mode, at: now).rounded()))%")
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
            VStack(alignment: .leading, spacing: 0) {
                Text("\(ProviderInfo.displayName(item.provider)) · \(item.window.label)")
                    .font(.caption.weight(.semibold))
                Text("\(mode.label) · 最吃緊")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ResetLabel(window: item.window, now: now)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 一個服務：名稱 + 每個額度的迷你進度條；失敗時只顯示錯誤（FR-12）。
struct ProviderActivityRow: View {
    let provider: UsageActivityState.Provider
    let mode: UsageDisplayMode
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(provider.displayName)
                .font(.caption.weight(.semibold))
                // 最大字級時縮小，不要在字中間換行（「Claud／e」）
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 52, alignment: .leading)
            if let error = provider.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(UsageColors.notice)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                ForEach(provider.windows) { window in
                    MiniWindowGauge(window: window, provider: provider.key, mode: mode, stale: stale, now: now)
                }
            }
        }
    }
}

/// 單一額度：名稱、百分比、進度條、重置倒數。
struct MiniWindowGauge: View {
    let window: UsageWindow
    let provider: String
    let mode: UsageDisplayMode
    let stale: Bool
    let now: Date

    private var pct: Double { window.displayedPct(mode, at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(window.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("\(Int(pct.rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.medium))
            ProgressView(value: pct, total: 100)
                .tint(UsageColors.bar(window, provider: provider, stale: stale, now: now))
            ResetLabel(window: window, now: now)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 重置倒數；已過重置時間顯示「已重置」（FR-26）。倒數由系統依絕對時間自動更新。
struct ResetLabel: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        if window.isReset(at: now) {
            Text("已重置")
        } else if let resetsAt = window.resetsAt {
            Text(resetsAt, style: .relative)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 更新時間；過期時提示 Mac 可能離線（FR-11），「更新」抓不到資料時在後面加上原因。
struct ActivityFooter<Trailing: View>: View {
    let updatedAt: Date
    let stale: Bool
    var refreshError: String? = nil
    @ViewBuilder var trailing: Trailing

    private var warning: Bool { stale || refreshError != nil }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: warning ? "exclamationmark.circle" : "clock")
            Group {
                if let refreshError {
                    // 仍顯示資料時間（沿用的舊資料），原因放後面，太長就截掉
                    Text(updatedAt, style: .time) + Text(" 更新 · 更新失敗：\(refreshError)")
                } else if stale {
                    Text("資料已過期 · ") + Text(updatedAt, style: .time) + Text(" 更新")
                } else {
                    Text(updatedAt, style: .time) + Text(" 更新")
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            trailing
        }
        .font(.caption2)
        .foregroundStyle(warning ? UsageColors.notice : .secondary)
    }
}

extension ActivityFooter where Trailing == EmptyView {
    init(updatedAt: Date, stale: Bool, refreshError: String? = nil) {
        self.init(updatedAt: updatedAt, stale: stale, refreshError: refreshError) { EmptyView() }
    }
}

/// Apple Watch 智慧型堆疊的精簡版面：只顯示最吃緊的一項（FR-27）。
struct WatchActivityView: View {
    let state: UsageActivityState
    var now: Date = .now

    private var stale: Bool { state.isStale(at: now) }

    var body: some View {
        if let item = state.tightest(at: now) {
            let pct = item.window.displayedPct(state.mode, at: now)
            HStack(spacing: 8) {
                Gauge(value: pct, in: 0...100) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(pct.rounded()))")
                        .font(.system(.body, design: .rounded).weight(.bold).monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(UsageColors.bar(item.window, provider: item.provider, stale: stale, now: now))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(ProviderInfo.displayName(item.provider)) \(item.window.label)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("\(state.mode.label) \(Int(pct.rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ResetLabel(window: item.window, now: now)
                        .font(.caption2)
                        .foregroundStyle(stale ? UsageColors.notice : .secondary)
                }
            }
            .padding(8)
        } else if state.providers.isEmpty {
            NoProvidersNotice(showsHint: false)
                .padding(8)
        } else {
            Label("沒有資料", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .padding(8)
        }
    }
}

/// 「更新」按鈕（FR-9）：卡片上觸發 `RefreshUsageIntent`，主畫面小工具傳入自己的 Intent。
struct RefreshButton: View {
    var intent: any AppIntent = RefreshUsageIntent()

    var body: some View {
        Button(intent: intent) {
            Label("更新", systemImage: "arrow.clockwise")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                // 依外觀自動調整，淺色鎖定畫面也看得到（白字會消失在淺色背景上）
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
