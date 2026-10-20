import SwiftUI
import UsageKit
import UsageKitUI

// Live Activity 的畫面元件。放在 Shared/ 讓 App 也能渲染同一份畫面（除錯與文件截圖用）。

/// 鎖定畫面卡片（FR-8、11、12、15、16、17、26）。
struct LockScreenActivityView: View {
    let state: UsageActivityState
    /// ActivityKit 的 `context.isStale`：超過 staleDate 時系統設為 true
    var systemStale = false
    var now: Date = .now

    private var stale: Bool { systemStale || state.isStale(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tightest = state.tightest(at: now) {
                TightestHeader(item: tightest, mode: state.mode, stale: stale, now: now)
            }
            ForEach(state.providers) { provider in
                ProviderActivityRow(provider: provider, mode: state.mode, stale: stale, now: now)
            }
            ActivityFooter(updatedAt: state.updatedAt, stale: stale)
        }
        .padding(16)
    }
}

/// 最吃緊的一項：大字百分比（FR-15）。
struct TightestHeader: View {
    let item: ProviderWindow
    let mode: UsageDisplayMode
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ProviderInfo.displayName(item.provider)) · \(item.window.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Int(item.window.displayedPct(mode, at: now).rounded()))%")
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ActivityStyle.tint(item.window, stale: stale, now: now))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(mode.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ResetLabel(window: item.window, now: now)
                    .font(.caption)
            }
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
                .frame(width: 52, alignment: .leading)
            if let error = provider.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                ForEach(provider.windows) { window in
                    MiniWindowGauge(window: window, mode: mode, stale: stale, now: now)
                }
            }
        }
    }
}

/// 單一額度：名稱、百分比、進度條、重置倒數。
struct MiniWindowGauge: View {
    let window: UsageWindow
    let mode: UsageDisplayMode
    let stale: Bool
    let now: Date

    private var pct: Double { window.displayedPct(mode, at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(window.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("\(Int(pct.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(ActivityStyle.tint(window, stale: stale, now: now))
            }
            .font(.caption2.weight(.medium))
            ProgressView(value: pct, total: 100)
                .tint(ActivityStyle.tint(window, stale: stale, now: now))
            ResetLabel(window: window, now: now)
                .font(.system(size: 10))
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

/// 更新時間；過期時提示 Mac 可能離線（FR-11）。
struct ActivityFooter<Trailing: View>: View {
    let updatedAt: Date
    let stale: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: stale ? "exclamationmark.circle" : "clock")
            if stale {
                Text("資料已過期 · ") + Text(updatedAt, style: .time) + Text(" 更新")
            } else {
                Text(updatedAt, style: .time) + Text(" 更新")
            }
            Spacer()
            trailing
        }
        .font(.caption2)
        .foregroundStyle(stale ? .orange : .secondary)
    }
}

extension ActivityFooter where Trailing == EmptyView {
    init(updatedAt: Date, stale: Bool) {
        self.init(updatedAt: updatedAt, stale: stale) { EmptyView() }
    }
}

enum ActivityStyle {
    /// 依剩餘比例上色（FR-16）；資料過期一律灰色（FR-11）。
    static func tint(_ window: UsageWindow, stale: Bool, now: Date) -> Color {
        stale ? .gray : window.effectiveSeverity(at: now).color
    }
}
