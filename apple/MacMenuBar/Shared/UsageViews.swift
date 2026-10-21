import SwiftUI
import UsageKit
import UsageKitUI

// 面板與桌面小工具共用的畫面元件。所有百分比都以「剩餘」顯示，並考慮重置時間（FR-26）。

/// 一個額度：名稱、剩餘 %、進度條、重置倒數或「已重置」。
struct WindowGauge: View {
    let window: UsageWindow
    let provider: String
    var stale = false
    var now: Date = .now
    var compact = false

    private var pct: Double { window.effectiveRemainingPct(at: now) }
    /// 進度條顏色（FR-16）；百分比文字一律 primary
    private var tint: Color { UsageColors.bar(window, provider: provider, stale: stale, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(compact ? .caption2 : .callout)
                Spacer(minLength: 4)
                Text("\(Int(pct.rounded()))%")
                    .font((compact ? Font.caption : .callout).weight(.semibold).monospacedDigit())
            }
            UsageBar(fraction: pct / 100, tint: tint)
                .frame(height: compact ? 4 : 6)
            ResetText(window: window, now: now)
                .font(compact ? .system(size: 9) : .caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 自繪進度條：macOS 的 ProgressView 在非作用中視窗與小工具會忽略 tint 變成灰色。
struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

/// 重置倒數；時間已過顯示「已重置」。`.relative` 樣式由系統自動倒數。
struct ResetText: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        if window.isReset(at: now) {
            Text("已重置")
        } else if let resetsAt = window.resetsAt {
            Text("重置 ") + Text(resetsAt, style: .relative)
        }
    }
}

/// 最後更新時間；過期時提示 Mac 可能睡眠或收集器停止（FR-11）。
struct UpdatedText: View {
    let updatedAt: Date
    let stale: Bool

    var body: some View {
        Label {
            if stale {
                Text("資料已過期 · ") + Text(updatedAt, style: .time) + Text(" 更新")
            } else {
                Text(updatedAt, style: .relative) + Text("前更新")
            }
        } icon: {
            Image(systemName: stale ? "exclamationmark.circle" : "clock")
        }
        .foregroundStyle(stale ? AnyShapeStyle(UsageColors.notice) : AnyShapeStyle(.secondary))
    }
}

/// 一個服務的所有可見額度；失敗時只顯示錯誤，不影響其他服務。
struct ProviderBlock: View {
    let key: String
    let provider: ProviderUsage
    var stale = false
    var now: Date = .now
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(spacing: 6) {
                Text(ProviderInfo.displayName(key))
                    .font((compact ? Font.caption : .headline).weight(.semibold))
                if let plan = provider.plan, !compact {
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
                    WindowGauge(window: window, provider: key, stale: stale, now: now, compact: compact)
                }
            }
        }
    }
}
