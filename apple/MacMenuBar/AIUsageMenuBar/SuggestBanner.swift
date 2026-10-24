import SwiftUI
import UsageKit
import UsageKitUI

// MARK: - 建議接下來用（FR-39）

/// 一行提示，不收合（只有一行，收合後沒有內容可以藏）；都充足時整個不顯示、不占空間。
struct SuggestBanner: View {
    let suggestion: NextProviderSuggestion

    @Environment(\.panelMotion) private var motion

    var body: some View {
        HStack(spacing: 6) {
            Text("建議接下來用")
                .font(.callout)
            ProviderIcon(suggestion.provider)
                .foregroundStyle(UsageColors.provider(suggestion.provider))
                .frame(width: 15, height: 15)
                .id(suggestion.provider)
                .transition(.opacity)
            Text(ProviderInfo.displayName(suggestion.provider))
                .font(.callout.weight(.semibold))
                .id("name-\(suggestion.provider)")
                .transition(.opacity)
            Spacer(minLength: 4)
            Text("\(suggestion.window.label)還剩 \(Int(suggestion.remainingPct.rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(UsageColors.provider(suggestion.provider).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UsageColors.provider(suggestion.provider).opacity(0.25)))
        // 從上方滑入（ADR-0010：0.3 秒）
        .offset(y: -10 * (1 - motion.suggest))
        .opacity(motion.suggest)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("建議接下來用 \(ProviderInfo.displayName(suggestion.provider))，\(suggestion.window.label)還剩 \(Int(suggestion.remainingPct.rounded()))%，\(ProviderInfo.displayName(suggestion.exhaustedProvider))快用完了")
    }
}
