#if DEBUG
import SwiftUI
import UsageKit
import UsageKitUI

/// 開發用：`AUM_RENDER=1` 時把動態島展開版面以 ImageRenderer 輸出到 App 容器的 Documents
/// （`island-<情境>.png` 與各張的高度 `island-sizes.json`），用 `xcrun simctl get_app_container` 取出。
/// 外框是近似的（寬 371pt、系統內距 12pt、黑底），只用來檢查內容高度與內距；實際版面以模擬器的動態島為準。
@MainActor
enum IslandRender {
    static let width: CGFloat = 371
    static let systemInset: CGFloat = 12

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["AUM_RENDER"] == "1" else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var sizes: [String: Double] = [:]
        let scenarios: [DemoData.Scenario] = [.normal, .claudeOnly, .error, .stale, .noProviders]
        for scenario in scenarios {
            let state = UsageActivityState(snapshot: DemoData.snapshot(for: scenario), mode: DemoData.mode(for: scenario))
            let view = mock(state: state)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            if let image = renderer.uiImage, let png = image.pngData() {
                try? png.write(to: dir.appendingPathComponent("island-\(scenario.rawValue).png"))
                sizes[scenario.rawValue] = image.size.height
            } else {
                sizes[scenario.rawValue] = -1  // 畫不出來
            }
        }
        if let json = try? JSONSerialization.data(withJSONObject: sizes, options: [.sortedKeys]) {
            try? json.write(to: dir.appendingPathComponent("island-sizes.json"))
        }
    }

    /// 依系統的排法近似：上方左右兩區、下方一區
    private static func mock(state: UsageActivityState) -> some View {
        let now = Date.now
        return VStack(spacing: 6) {
            HStack(alignment: .top) {
                IslandLeading(state: state, now: now)
                Spacer(minLength: 8)
                IslandTrailing(state: state, now: now) { RefreshButton() }
            }
            IslandBottom(state: state, stale: state.isStale(at: now), now: now)
        }
        .padding(systemInset)
        .frame(width: width)
        .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
#endif
