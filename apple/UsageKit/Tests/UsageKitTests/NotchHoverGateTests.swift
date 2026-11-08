import Foundation
import Testing
@testable import UsageKit

/// 瀏海面板只有游標移進瀏海才展開（收合動畫、提醒動畫時視窗還是整張 580×190 的畫布）
@Suite struct NotchHoverGateTests {
    /// 收合時的視窗範圍：真實瀏海（寬 185＋120＋44）與假瀏海（250＋44），上緣置中
    static let zones = [
        CGRect(x: 290 - 349.0 / 2, y: 0, width: 349, height: 37 + 5),
        CGRect(x: 290 - 294.0 / 2, y: 0, width: 294, height: 32 + 5),
    ]

    /// 畫布裡、離瀏海還有一段距離（下半部、左右兩側）
    static let far = [CGPoint(x: 290, y: 150), CGPoint(x: 20, y: 10), CGPoint(x: 560, y: 60)]

    @Test(arguments: zones) func enteringFarFromNotchWhileClosedDoesNotOpen(zone: CGRect) {
        for point in Self.far {
            var gate = NotchHoverGate(zone: zone)
            #expect(gate.enter(at: point, isOpen: false) == .none)
            #expect(gate.move(to: CGPoint(x: point.x, y: point.y + 3), isOpen: false) == .none)
        }
    }

    @Test(arguments: zones) func movingOntoNotchAfterEnteringFarOpens(zone: CGRect) {
        var gate = NotchHoverGate(zone: zone)
        #expect(gate.enter(at: CGPoint(x: 290, y: 150), isOpen: false) == .none)
        #expect(gate.move(to: CGPoint(x: 290, y: 90), isOpen: false) == .none)
        #expect(gate.move(to: CGPoint(x: 290, y: 20), isOpen: false) == .open)
    }

    @Test(arguments: zones) func enteringOnNotchWhileClosedOpens(zone: CGRect) {
        var gate = NotchHoverGate(zone: zone)
        #expect(gate.enter(at: CGPoint(x: 290, y: 1), isOpen: false) == .open)
    }

    /// 展開後移出、等著收回的 350 ms 內回到面板任何地方：取消收合
    @Test(arguments: zones) func reenteringWhileStillOpenStaysOpen(zone: CGRect) {
        var gate = NotchHoverGate(zone: zone)
        gate.exit()
        #expect(gate.enter(at: CGPoint(x: 290, y: 150), isOpen: true) == .stayOpen)
    }

    /// 游標在瀏海上按 Esc 收合：原地微移不重開，移出瀏海再移回來才開
    @Test(arguments: zones) func escapeOnNotchThenSmallMoveDoesNotReopen(zone: CGRect) {
        var gate = NotchHoverGate(zone: zone)
        let onNotch = CGPoint(x: 290, y: 10)
        #expect(gate.enter(at: CGPoint(x: 290, y: 150), isOpen: true) == .stayOpen)
        #expect(gate.move(to: onNotch, isOpen: true) == .none)
        // Esc：狀態機收合，游標沒動
        #expect(gate.move(to: CGPoint(x: onNotch.x + 2, y: onNotch.y), isOpen: false) == .none)
        #expect(gate.move(to: CGPoint(x: 290, y: 120), isOpen: false) == .none)
        #expect(gate.move(to: onNotch, isOpen: false) == .open)
    }

    @Test(arguments: zones) func exitingResetsSoComingBackOntoNotchOpens(zone: CGRect) {
        var gate = NotchHoverGate(zone: zone)
        let onNotch = CGPoint(x: 290, y: 10)
        #expect(gate.enter(at: onNotch, isOpen: false) == .open)
        gate.exit()
        #expect(gate.enter(at: onNotch, isOpen: false) == .open)
    }
}
