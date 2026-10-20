import AppKit
import SwiftUI
import UsageKit

/// 選單列圖示：彩色圓點 + 最吃緊額度的剩餘 %（FR-21）；過期時圓點轉灰。
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        if let snapshot = store.snapshot, let item = snapshot.tightestWindow(at: store.now) {
            let stale = snapshot.isStale(now: store.now)
            let color = stale ? NSColor.systemGray : item.window.effectiveSeverity(at: store.now).nsColor
            Image(nsImage: StatusDot.image(color: color))
            Text("\(Int(item.window.effectiveRemainingPct(at: store.now).rounded()))%")
        } else {
            Image(systemName: "gauge.with.dots.needle.0percent")
        }
    }
}

/// 選單列會把 SF Symbol 與文字轉成單色，顏色只能靠非範本（non-template）的點陣圖。
enum StatusDot {
    static func image(color: NSColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
