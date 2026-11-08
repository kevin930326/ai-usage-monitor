import Foundation

/// 瀏海面板什麼時候因為滑鼠展開（ADR-0016 第 4 節）。收合動畫（含移出後等著收回的時間）與收著時的提醒動畫播放時，
/// 視窗還是整張畫布：只看「游標進入視窗」的話，離瀏海還很遠就又展開。所以收著時只有游標從外面移進 `zone`
/// （看得到的瀏海，畫布座標）才展開；在 `zone` 裡按 Esc 收合後原地動一下不會又打開。純邏輯、可以測。
public struct NotchHoverGate: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// 收著：展開
        case open
        /// 展開中（含等著收回）回到面板上：取消收合
        case stayOpen
    }

    public let zone: CGRect
    /// 游標在 `zone` 裡
    public private(set) var onNotch = false

    public init(zone: CGRect) {
        self.zone = zone
    }

    /// 游標移入視窗
    public mutating func enter(at point: CGPoint, isOpen: Bool) -> Action {
        onNotch = false
        if isOpen {
            onNotch = inZone(point)
            return .stayOpen
        }
        return move(to: point, isOpen: isOpen)
    }

    /// 游標在視窗裡移動
    public mutating func move(to point: CGPoint, isOpen: Bool) -> Action {
        let on = inZone(point)
        defer { onNotch = on }
        return on && !onNotch && !isOpen ? .open : .none
    }

    /// 游標移出視窗
    public mutating func exit() {
        onNotch = false
    }

    /// `CGRect.contains`、`minX` 等在 CoreGraphics（UsageKit 只 import Foundation）：自己比
    private func inZone(_ point: CGPoint) -> Bool {
        let dx = point.x - zone.origin.x, dy = point.y - zone.origin.y
        return dx >= 0 && dx < zone.size.width && dy >= 0 && dy < zone.size.height
    }
}
