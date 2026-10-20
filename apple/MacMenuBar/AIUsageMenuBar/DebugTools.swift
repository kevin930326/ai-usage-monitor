#if DEBUG
import SwiftUI
import UsageKit
import WidgetKit

/// 開發用（只在 Debug 版本）：
/// - `AUM_DEMO_PANEL=1`：把面板放進一般視窗。MenuBarExtra 無法以程式點開，截圖用這個視窗。
/// - `AUM_RENDER_DIR=<資料夾>`：用 ImageRenderer 把桌面小工具兩種尺寸輸出成 PNG。
@MainActor
enum DebugTools {
    private static var panelWindow: NSWindow?

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if env["AUM_DEMO_PANEL"] == "1" { showPanelWindow() }
        if let dir = env["AUM_RENDER_DIR"], !dir.isEmpty { renderWidgets(to: URL(fileURLWithPath: dir)) }
    }

    private static func showPanelWindow() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI 用量（面板預覽）"
        window.contentView = NSHostingView(rootView: PanelView().environment(UsageStore.shared))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        panelWindow = window
        UsageStore.log("demo panel window \(window.windowNumber)")
    }

    private static func renderWidgets(to dir: URL) {
        let snapshot = UsageStore.shared.snapshot ?? SharedSnapshot.sample()
        let sizes: [(WidgetFamily, String, CGSize)] = [
            (.systemSmall, "small", CGSize(width: 170, height: 170)),
            (.systemMedium, "medium", CGSize(width: 364, height: 170)),
        ]
        for (family, name, size) in sizes {
            let view = UsageWidgetView(snapshot: snapshot, family: family)
                .padding(16)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let url = dir.appendingPathComponent("widget-\(name).png")
            try? png.write(to: url)
            UsageStore.log("rendered \(url.path)")
        }
    }
}
#endif
