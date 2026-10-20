// SwiftUI 只有 Apple 平台有；Linux CI 只編譯、測試 UsageKit
#if canImport(SwiftUI)

import SwiftUI
import UsageKit

/// 一個額度：名稱、百分比、進度條、重置倒數；重置時間已過顯示「已重置」（FR-26）。
public struct UsageWindowRow: View {
    let window: UsageWindow
    let display: UsageDisplayMode
    var dimmed: Bool
    var now: Date

    // 預設顯示剩餘，與分級顏色（依剩餘比例）一致
    public init(window: UsageWindow, display: UsageDisplayMode = .remaining, dimmed: Bool = false, now: Date = .now) {
        self.window = window
        self.display = display
        self.dimmed = dimmed
        self.now = now
    }

    private var pct: Double { window.displayedPct(display, at: now) }
    private var tint: Color { dimmed ? .secondary : window.effectiveSeverity(at: now).color }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(pct.rounded()))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText(value: pct))
            }
            ProgressView(value: pct, total: 100)
                .tint(tint)
            if window.isReset(at: now) {
                Text("已重置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let resetsAt = window.resetsAt {
                // relative 樣式會自己倒數，不需要重新抓資料
                (Text("重置 ") + Text(resetsAt, style: .relative))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label)，\(display.label) \(Int(pct.rounded()))%")
    }
}

// 用 PreviewProvider 而非 #Preview：#Preview 巨集只有 Xcode 有，命令列 swift build 會失敗
struct UsageWindowRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            UsageWindowRow(window: UsageWindow(id: "five_hour", label: "5 小時", usedPct: 24, resetsAt: .now.addingTimeInterval(3600)))
            UsageWindowRow(window: UsageWindow(id: "weekly", label: "每週", usedPct: 63, resetsAt: .now.addingTimeInterval(86400 * 3)))
            UsageWindowRow(window: UsageWindow(id: "weekly", label: "每週", usedPct: 91), display: .used)
        }
        .padding()
    }
}

#endif
