// SwiftUI 只有 Apple 平台有；Linux CI 只編譯、測試 UsageKit
#if canImport(SwiftUI)

import SwiftUI
import UsageKit

/// 收集器沒有啟用任何服務時取代服務列表的提示（`UsageSnapshot.hasNoProviders`）。
/// 這是設定問題不是服務錯誤，文字用 primary／secondary，不用提示色。
public struct NoProvidersNotice: View {
    var showsHint: Bool

    /// `showsHint` 為 false 時只顯示標題，給小尺寸的小工具用。
    public init(showsHint: Bool = true) {
        self.showsHint = showsHint
    }

    public var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(ProviderInfo.noProvidersTitle)
                    .font(.caption.weight(.semibold))
                if showsHint {
                    Text(ProviderInfo.noProvidersHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
        }
    }
}

#endif
