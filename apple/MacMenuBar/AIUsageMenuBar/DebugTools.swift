#if DEBUG
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UsageKit
import UsageKitUI
import WidgetKit

/// 開發用（只在 Debug 版本）：
/// - `AUM_DEMO_PANEL=1`：把面板放進一般視窗。MenuBarExtra 無法以程式點開，截圖與量測用這個視窗。
/// - `AUM_RENDER_DIR=<資料夾>`：用 ImageRenderer 輸出桌面小工具、面板、選單列圖示與設定視窗的 PNG（淺色、深色）。
/// - `AUM_RENDER_FRAMES=1`（搭配 `AUM_RENDER_DIR`）：每個動畫以 30 fps 輸出 PNG 序列並組成 GIF。
/// - `AUM_RENDER_EXIT=1`：輸出完就結束。
/// - `AUM_DEMO_PERF=1`（搭配 `AUM_DEMO_PANEL=1`）：依固定時間表打開面板、觸發動畫、關閉、再開關一次，給 `scripts/measure-panel-perf.sh` 量測。
@MainActor
enum DebugTools {
    private static var panelWindow: NSWindow?

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        // 量測時先記錄面板開啟前的基準，10 秒後才打開
        if env["AUM_DEMO_PANEL"] == "1", env["AUM_DEMO_PERF"] != "1" { showPanelWindow() }
        if let dir = env["AUM_RENDER_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            renderWidgets(to: url)
            renderPanel(to: url)
            renderMenuBarIcons(to: url)
            renderSettings(to: url)
            if env["AUM_RENDER_FRAMES"] == "1" { renderAnimations(to: url) }
            if env["AUM_RENDER_EXIT"] == "1" { exit(0) }
        }
        if env["AUM_DEMO_PERF"] == "1" { runPerfSchedule() }
    }

    private static func showPanelWindow() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI 用量（面板預覽）"
        window.contentView = NSHostingView(rootView: PanelView().environment(UsageStore.shared).environment(PanelSettings.shared))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        panelWindow = window
        UsageStore.log("demo panel window \(window.windowNumber)")
    }

    // MARK: - 效能量測的時間表（ADR-0010 第 3 節）

    /// 每個步驟在 stderr 印出 `perf-mark <秒> <名稱>`，量測腳本依此把 ps 的取樣分段。
    private static func runPerfSchedule() {
        let steps: [(TimeInterval, String, @MainActor () -> Void)] = [
            (0, "launch", {}),
            (10, "panel-open", { showPanelWindow() }),
            (22, "refresh", { DebugAction.send("refresh") }),
            (27, "glow", { DebugAction.send("glow") }),
            (32, "collapse", { DebugAction.send("collapse") }),
            (35, "expand", { DebugAction.send("expand") }),
            (38, "appearance-dark", { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }),
            (42, "appearance-light", { NSApplication.shared.appearance = nil }),
            (46, "panel-close", { panelWindow?.orderOut(nil) }),
            (46 + 60, "closed-60s", {}),
            (46 + 90, "closed-90s", {}),
            // 第二次開關：比較兩次關閉後的記憶體，確認沒有累積（第一次開啟會載入框架，不能和開啟前比）
            (46 + 92, "panel-reopen", { panelWindow?.makeKeyAndOrderFront(nil) }),
            (46 + 100, "panel-close-2", { panelWindow?.orderOut(nil) }),
            (46 + 120, "exit", { exit(0) }),
        ]
        let start = Date.now
        for (offset, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                MainActor.assumeIsolated {
                    action()
                    UsageStore.log(String(format: "perf-mark %.1f %@", Date.now.timeIntervalSince(start), name))
                }
            }
        }
    }

    // MARK: - 靜態截圖

    private static var snapshot: UsageSnapshot { UsageStore.shared.snapshot ?? SharedSnapshot.sample() }

    private static func renderWidgets(to dir: URL) {
        let sizes: [(WidgetFamily, String, CGSize)] = [
            (.systemSmall, "small", CGSize(width: 170, height: 170)),
            (.systemMedium, "medium", CGSize(width: 364, height: 170)),
        ]
        for (family, name, size) in sizes {
            let view = UsageWidgetView(snapshot: snapshot, family: family)
                .padding(16)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
            write(view, scheme: .dark, to: dir.appendingPathComponent("widget-\(name).png"))
        }
    }

    private static func panel(_ motion: PanelMotion = .settled) -> some View {
        PanelView(fixedMotion: motion, scrolls: false)
            .environment(UsageStore.shared)
            .environment(PanelSettings.shared)
    }

    private static func renderPanel(to dir: URL) {
        for scheme in [ColorScheme.light, .dark] {
            write(panel().background(Color(nsColor: .windowBackgroundColor)), scheme: scheme,
                  to: dir.appendingPathComponent("panel-\(scheme.name).png"))
            var collapsed = PanelMotion.settled
            collapsed.reveal = [PanelSection.ring.rawValue: 0]
            write(panel(collapsed).background(Color(nsColor: .windowBackgroundColor)), scheme: scheme,
                  to: dir.appendingPathComponent("panel-collapsed-\(scheme.name).png"))
        }
    }

    private static func renderSettings(to dir: URL) {
        for scheme in [ColorScheme.light, .dark] {
            let view = SettingsView(scrolls: false)
                .environment(UsageStore.shared)
                .environment(PanelSettings.shared)
                .background(Color(nsColor: .windowBackgroundColor))
            write(view, scheme: scheme, to: dir.appendingPathComponent("settings-\(scheme.name).png"))
        }
    }

    /// 四種狀態 × 四種樣式，放在模擬的選單列上。
    private static func renderMenuBarIcons(to dir: URL) {
        let states: [(String, MenuBarIconContent)] = [
            ("正常", .init(provider: "claude", remainingPct: 62, timeRemaining: 70, state: .normal, label: "Claude 5 小時")),
            ("用得太快", .init(provider: "claude", remainingPct: 27, timeRemaining: 40, state: .tooFast, label: "Claude 5 小時")),
            ("剩不到 20%", .init(provider: "codex", remainingPct: 12, timeRemaining: 30, state: .critical, label: "Codex 每週")),
            ("資料過期", .init(provider: "claude", remainingPct: 62, timeRemaining: 70, state: .stale, label: "Claude 5 小時")),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 10) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    HStack(spacing: 18) {
                        Text(style.title).font(.caption).frame(width: 56, alignment: .leading)
                        ForEach(states, id: \.0) { title, content in
                            HStack(spacing: 6) {
                                MenuBarIconView(content: content, style: style).font(.system(size: 13))
                                Text(title).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 120, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                }
            }
            .padding(12)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.9))
            write(view, scheme: scheme, to: dir.appendingPathComponent("menubar-icons-\(scheme.name).png"))
        }
    }

    // MARK: - 動畫的 PNG 序列與 GIF

    private static let fps = 30.0

    private static func renderAnimations(to dir: URL) {
        let animations: [(String, Double, (Double) -> PanelMotion)] = [
            // 主圓環與用量條從 0 長到目前位置，預期標記稍後淡入
            ("appear", 0.9, { t in
                PanelMotion(appear: Curve.easeOut(t / 0.6), marker: Curve.easeOut((t - 0.45) / 0.2))
            }),
            // 更新按鈕轉一圈，完成後狀態點閃一下
            ("refresh", 1.3, { t in
                var m = PanelMotion.settled
                m.refreshTurns = Curve.easeInOut(t / 0.6)
                m.dotFlash = t > 0.6 ? Curve.linear((t - 0.6) / 0.5) : 0
                if m.dotFlash >= 1 { m.dotFlash = 0 }
                return m
            }),
            // 額度重置：服務圖示閃一下光芒
            ("reset-glow", 1.0, { t in
                var m = PanelMotion.settled
                let p = Curve.linear(t / 0.8)
                m.glow = ["claude": p >= 1 ? 0 : p]
                return m
            }),
            // 卡片收合再展開
            ("collapse", 1.0, { t in
                var m = PanelMotion.settled
                let p = t < 0.5 ? 1 - Curve.easeInOut(t / 0.25) : Curve.easeInOut((t - 0.5) / 0.25)
                m.reveal = [PanelSection.ring.rawValue: p]
                return m
            }),
        ]
        for (name, duration, motionAt) in animations {
            for scheme in [ColorScheme.light, .dark] {
                let folder = dir.appendingPathComponent("anim-\(name)-\(scheme.name)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var frames: [CGImage] = []
                let count = Int(duration * fps) + 1
                for index in 0..<count {
                    let view = panel(motionAt(Double(index) / fps)).background(Color(nsColor: .windowBackgroundColor))
                    guard let image = cgImage(view, scheme: scheme) else { continue }
                    writePNG(image, to: folder.appendingPathComponent(String(format: "frame-%03d.png", index)))
                    frames.append(image)
                }
                writeGIF(frames, to: dir.appendingPathComponent("anim-\(name)-\(scheme.name).gif"))
            }
        }
        renderThemeCrossfade(to: dir)
    }

    /// 深淺色切換：SwiftUI 在兩個外觀的顏色之間過渡；這裡以兩張截圖的交叉淡入示意（0.3 秒）。
    private static func renderThemeCrossfade(to dir: URL) {
        guard let light = cgImage(panel().background(Color(nsColor: .windowBackgroundColor)), scheme: .light),
              let dark = cgImage(panel().background(Color(nsColor: .windowBackgroundColor)), scheme: .dark) else { return }
        let folder = dir.appendingPathComponent("anim-theme")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var frames: [CGImage] = []
        let count = Int(0.3 * fps) + 1
        for index in 0..<(count * 2 + 10) {
            // 淺→深、停留、深→淺
            let t = Double(index) / Double(count - 1)
            let mix = index < count ? Curve.easeInOut(t) : index < count + 10 ? 1 : 1 - Curve.easeInOut(Double(index - count - 10) / Double(count - 1))
            guard let frame = blend(light, dark, mix) else { continue }
            writePNG(frame, to: folder.appendingPathComponent(String(format: "frame-%03d.png", index)))
            frames.append(frame)
        }
        writeGIF(frames, to: dir.appendingPathComponent("anim-theme.gif"))
    }

    // MARK: - 輸出

    private static func cgImage(_ view: some View, scheme: ColorScheme) -> CGImage? {
        let content = view.environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var image: CGImage?
        // UsageColors 的動態顏色依「目前的繪製外觀」解析，所以外觀也要一起切換
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return image
    }

    private static func write(_ view: some View, scheme: ColorScheme, to url: URL) {
        guard let image = cgImage(view, scheme: scheme) else { return }
        writePNG(image, to: url)
        UsageStore.log("rendered \(url.lastPathComponent)")
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func writeGIF(_ frames: [CGImage], to url: URL) {
        guard !frames.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, frame, delay) }
        CGImageDestinationFinalize(destination)
        UsageStore.log("rendered \(url.lastPathComponent) (\(frames.count) frames)")
    }

    private static func blend(_ a: CGImage, _ b: CGImage, _ mix: Double) -> CGImage? {
        let width = max(a.width, b.width), height = max(a.height, b.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(a, in: CGRect(x: 0, y: height - a.height, width: a.width, height: a.height))
        context.setAlpha(mix)
        context.draw(b, in: CGRect(x: 0, y: height - b.height, width: b.width, height: b.height))
        return context.makeImage()
    }
}

/// 量測腳本觸發面板動畫的方式（只在 Debug 版本）。
enum DebugAction {
    static let notification = Notification.Name("AUMDebugPanelAction")

    @MainActor static func send(_ action: String) {
        NotificationCenter.default.post(name: notification, object: action)
    }
}

/// 與 SwiftUI 內建曲線相同的三次貝茲曲線（easeOut＝0,0,0.58,1；easeInOut＝0.42,0,0.58,1）。
private enum Curve {
    static func linear(_ t: Double) -> Double { min(max(t, 0), 1) }
    static func easeOut(_ t: Double) -> Double { bezier(linear(t), 0, 0, 0.58, 1) }
    static func easeInOut(_ t: Double) -> Double { bezier(linear(t), 0.42, 0, 0.58, 1) }

    private static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func component(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if component(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return component(t, y1, y2)
    }
}

private extension ColorScheme {
    var name: String { self == .dark ? "dark" : "light" }
}
#endif
