import Foundation
import Testing
@testable import UsageKit

/// 瀏海面板只有游標移進瀏海才展開（收合動畫、提醒動畫時視窗還是整張 580×190 的畫布）
@Suite struct NotchHoverGateTests {
    /// 看得到的瀏海（`NotchLayout.hoverRect`）：真實瀏海（寬 185＋120）與假瀏海（250），上緣置中
    static let zones = [
        CGRect(x: 290 - 305.0 / 2, y: 0, width: 305, height: 37),
        CGRect(x: 290 - 250.0 / 2, y: 0, width: 250, height: 32),
    ]

    /// 沿著選單列從左右靠近：碰到瀏海邊緣才展開，視窗左右各 22 的透明邊不算
    @Test(arguments: zones) func approachingFromSidesOpensOnlyAtNotchEdge(zone: CGRect) {
        let left = zone.origin.x, right = zone.origin.x + zone.size.width
        for (outside, inside) in [(left - 22, left - 1), (right + 21, right + 1)] {
            var gate = NotchHoverGate(zone: zone)
            #expect(gate.enter(at: CGPoint(x: outside, y: 10), isOpen: false) == .none)
            #expect(gate.move(to: CGPoint(x: inside, y: 10), isOpen: false) == .none)
            let edge = inside < left ? left : right - 1
            #expect(gate.move(to: CGPoint(x: edge, y: 10), isOpen: false) == .open)
        }
    }

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
