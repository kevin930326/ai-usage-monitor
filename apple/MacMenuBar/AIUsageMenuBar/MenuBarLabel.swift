import AppKit
import SwiftUI
import UsageKit
import UsageKitUI

/// 選單列圖示：圓點 + 最吃緊額度的剩餘 %（FR-21）。
/// 圓點與進度條同規則（FR-16）：該服務的識別色、剩餘 < 20% 紅色、過期灰色。
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        if let snapshot = store.snapshot, let item = snapshot.tightestWindow(at: store.now) {
            let stale = snapshot.isStale(now: store.now)
            let color = NSColor(UsageColors.bar(item.window, provider: item.provider, stale: stale, now: store.now))
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
