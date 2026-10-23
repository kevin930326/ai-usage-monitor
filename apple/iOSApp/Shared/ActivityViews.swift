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
    // 但資料已過期後 staleDate 改為下一個重置時間，不能拿來判斷過期。
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

/// 剩餘最少的額度：大字百分比（FR-15）。名稱就是標題，不另加「剩餘最少」。
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
                .accessibilityLabel(item.leastRemainingAccessibilityLabel(mode: mode, at: now))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayName)
                    .font(.caption.weight(.semibold))
                Text(mode.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
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

// MARK: - 動態島展開版面

/// 動態島展開版面的內距：左上與右上的文字要離開圓角，最下方一行不能貼著底邊。
enum IslandLayout {
    static let sideInset: CGFloat = 8
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 4
}

/// 左上：剩餘最少的額度（名稱一行＋大數字，FR-15）。沒有服務時顯示提示。
struct IslandLeading: View {
    let state: UsageActivityState
    let now: Date

    var body: some View {
        Group {
            if let item = state.tightest(at: now) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(item.displayName) · \(state.mode.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(Int(item.window.displayedPct(state.mode, at: now).rounded()))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                        .accessibilityLabel(item.leastRemainingAccessibilityLabel(mode: state.mode, at: now))
                }
            } else if state.providers.isEmpty {
                NoProvidersNotice(showsHint: false)
            }
        }
        .padding(.leading, IslandLayout.sideInset)
        .padding(.top, IslandLayout.topInset)
    }
}

/// 右上：更新按鈕，下面一行是剩餘最少的額度的重置倒數（各額度的重置時間不放，空間不夠）。
struct IslandTrailing<Trailing: View>: View {
    let state: UsageActivityState
    let now: Date
    @ViewBuilder var button: Trailing

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            button
            if let item = state.tightest(at: now) {
                ResetLabel(window: item.window, now: now)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.trailing, IslandLayout.sideInset)
        .padding(.top, IslandLayout.topInset)
    }
}

/// 下方：每個服務一行（名稱＋各額度的 % 與細進度條；失敗時一行錯誤），最後一行更新時間。
struct IslandBottom: View {
    let state: UsageActivityState
    let stale: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(state.providers) { provider in
                IslandProviderRow(provider: provider, mode: state.mode, stale: stale, now: now)
            }
            ActivityFooter(updatedAt: state.updatedAt, stale: stale, refreshError: state.refreshError)
        }
        .padding(.horizontal, IslandLayout.sideInset)
        .padding(.bottom, IslandLayout.bottomInset)
    }
}

/// 動態島的一個服務：一行，不放重置倒數（鎖定畫面的 `ProviderActivityRow` 才有）。
struct IslandProviderRow: View {
    let provider: UsageActivityState.Provider
    let mode: UsageDisplayMode
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(provider.displayName)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 44, alignment: .leading)
                .layoutPriority(1)
            if let error = provider.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(UsageColors.notice)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                ForEach(provider.windows) { window in
                    let pct = window.displayedPct(mode, at: now)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(window.label)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            Text("\(Int(pct.rounded()))%")
                                .monospacedDigit()
                        }
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        IslandBar(pct: pct, color: UsageColors.bar(window, provider: provider.key, stale: stale, now: now))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// 動態島的細進度條（3pt）。自己畫而不用 `ProgressView`：比較細，ImageRenderer 也畫得出來。
struct IslandBar: View {
    let pct: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.18))
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * min(max(pct, 0), 100) / 100)
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
    }
}

/// Apple Watch 智慧型堆疊的精簡版面：只顯示剩餘最少的額度（FR-27）。
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
