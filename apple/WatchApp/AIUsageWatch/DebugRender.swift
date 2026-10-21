#if DEBUG
import SwiftUI
import UsageKit
import UsageKitUI
import WidgetKit

/// 開發用：`AUM_RENDER=1` 時把三種複雜功能以 ImageRenderer 輸出到 App 容器的 Documents，
/// 用 `xcrun simctl get_app_container` 取出（錶面無法以程式設定）。
@MainActor
enum DebugRender {
    static func runIfRequested(snapshot: UsageSnapshot?) {
        guard ProcessInfo.processInfo.environment["AUM_RENDER"] == "1" else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let items: [(WidgetFamily, String, CGSize)] = [
            (.accessoryCircular, "circular", CGSize(width: 52, height: 52)),
            (.accessoryRectangular, "rectangular", CGSize(width: 180, height: 64)),
            (.accessoryInline, "inline", CGSize(width: 180, height: 22)),
        ]
        for (family, name, size) in items {
            let view = ComplicationView(snapshot: snapshot, family: family)
                .frame(width: size.width, height: size.height)
                .padding(6)
                .background(.black)
                .environment(\.colorScheme, .dark)
            write(view, to: dir.appendingPathComponent("complication-\(name).png"))
        }
        // 圓形複雜功能的另外兩種外觀：淺色背景，以及模擬單色／主題色錶面
        // （系統只用形狀的 alpha，再套主題色；圖示的鏤空處要透出背景）
        let circular = ComplicationView(snapshot: snapshot, family: .accessoryCircular)
            .frame(width: 52, height: 52)
        write(circular.padding(6).background(.white).environment(\.colorScheme, .light),
              to: dir.appendingPathComponent("complication-circular-light.png"))
        write(Color.yellow.mask(circular.environment(\.colorScheme, .dark))
                .frame(width: 52, height: 52).padding(6).background(Color(white: 0.12)),
              to: dir.appendingPathComponent("complication-circular-tinted.png"))
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        guard let image = renderer.uiImage, let png = image.pngData() else { return }
        try? png.write(to: url)
    }
}
#endif
