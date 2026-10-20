import SwiftUI
import UsageKit
import UsageKitUI
import WidgetKit

/// 桌面小工具畫面（FR-24）。尺寸以參數傳入，App 也能用 ImageRenderer 輸出同一個畫面。
struct UsageWidgetView: View {
    let snapshot: UsageSnapshot
    let family: WidgetFamily
    var isSample = false
    var now: Date = .now

    private var stale: Bool { snapshot.isStale(now: now) }

    var body: some View {
        switch family {
        case .systemSmall: small
        default: medium
        }
    }

    /// 小：最吃緊的一項大字。
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let item = snapshot.tightestWindow(at: now) {
                Text("\(ProviderInfo.displayName(item.provider)) · \(item.window.label)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(Int(item.window.effectiveRemainingPct(at: now).rounded()))%")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(stale ? .secondary : item.window.effectiveSeverity(at: now).color)
                Text("剩餘").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ResetText(window: item.window, now: now)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label("沒有資料", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 中：兩個服務並排。
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(snapshot.orderedProviderKeys, id: \.self) { key in
                    if let provider = snapshot.providers[key] {
                        ProviderBlock(key: key, provider: provider, stale: stale, now: now, compact: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        Group {
            if isSample {
                Text("範例資料 · 未連結 App Group")
                    .foregroundStyle(.secondary)
            } else {
                UpdatedText(updatedAt: snapshot.updatedAt, stale: stale)
            }
        }
        .font(.caption2)
        .lineLimit(1)
    }
}
