#if DEBUG
import SwiftUI
import UsageKit
import UsageKitUI

/// 開發用：`AUM_RENDER=1` 時把動態島展開版面以 ImageRenderer 輸出到 App 容器的 Documents
/// （每個示範情境一張 `island-<情境>.png`，另有最大一般字級的 `-xxxl`），各張的高度與超過上限的情境寫在
/// `island-sizes.json`（`over` 不是空的就是版面太高），用 `xcrun simctl get_app_container` 取出。
/// 外框是近似的（寬 371pt、系統內距 12pt、黑底），只用來檢查內容高度與內距；實際版面以模擬器的動態島為準。
@MainActor
enum IslandRender {
    static let width: CGFloat = 371
    static let systemInset: CGFloat = 12

    /// 系統的展開版面高度上限（約 160pt）；近似外框超過時記在 `island-sizes.json` 的 `over`
    static let heightLimit: CGFloat = 160

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["AUM_RENDER"] == "1" else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var sizes: [String: Double] = [:]
        var over: [String] = []
        // 每個示範情境一張；兩個最高的情境另以最大的一般字級（xxxLarge）畫一張
        var items: [(String, DemoData.Scenario, DynamicTypeSize)] = DemoData.Scenario.allCases.map { ($0.rawValue, $0, .large) }
        items += [("normal-xxxl", .normal, .xxxLarge), ("error-xxxl", .error, .xxxLarge)]
        for (name, scenario, typeSize) in items {
            let state = UsageActivityState(snapshot: DemoData.snapshot(for: scenario), mode: DemoData.mode(for: scenario))
            let renderer = ImageRenderer(content: mock(state: state).dynamicTypeSize(typeSize))
            renderer.scale = 3
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            guard let image = renderer.uiImage, let png = image.pngData() else {
                over.append(name)  // 畫不出來也算失敗
                continue
            }
            try? png.write(to: dir.appendingPathComponent("island-\(name).png"))
            sizes[name] = image.size.height
            if image.size.height > heightLimit { over.append(name) }
        }
        let report: [String: Any] = ["limit": Double(heightLimit), "heights": sizes, "over": over.sorted()]
        if let json = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
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
