import Foundation

/// 面板裡的滑鼠手勢（ADR-0016 第 2 節、demo 的 `mousemove`）：繞著角色畫兩圈 → 轉暈、快速左右甩動 → 嚇到、
/// 停在角色身上 → 害羞。只吃面板自己視窗裡的移動（不裝全域監聽）；時間與座標由呼叫端給，純邏輯、可以測。
/// demo 的門檻是「每個 mousemove」（約 60 Hz）；這裡換算成以 60 Hz 一格的時間，滑鼠事件 120 Hz 時手感相同。
public struct MascotGestureDetector: Sendable {
    public let gestures: MascotConfig.Gestures
    public let hoverShyMs: Int

    /// 累積繞過的角度（弧度，會衰減）
    private(set) var turned = 0.0
    private var lastAngle: Double?
    private var lastAngleTime = 0
    private var lastX: Double?
    private var lastMoveTime: Int?
    private var lastDx = 0.0
    private var reversals = 0
    private var reversalTime = 0
    private var hoverStart: Int?

    /// demo 的一個 mousemove（60 Hz）
    static let frameMs = 1000.0 / 60

    public init(gestures: MascotConfig.Gestures, hoverShyMs: Int) {
        self.gestures = gestures
        self.hoverShyMs = hoverShyMs
    }

    public init(config: MascotConfig) {
        self.init(gestures: config.gestures, hoverShyMs: config.interaction.hoverShyMs)
    }

    /// 滑鼠移到 `point`（畫布座標）；`center`、`radius` 是角色此刻的位置與半徑。
    /// `canDetect` 為 false（收合、過場、播放中、按住、睡覺）時清掉累積，什麼都不觸發。
    public mutating func move(to point: CGPoint, at time: Int, center: CGPoint, radius: Double,
                              canDetect: Bool) -> MascotGesture? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        // 距離上一個事件幾格（60 Hz 一格；最多算 4 格，停很久再動不會一次衰減光）
        let frames = lastMoveTime.map { min(max(Double(time - $0) / Self.frameMs, 0.25), 4) } ?? 1
        let moveX = lastX.map { point.x - $0 } ?? 0
        lastX = point.x
        lastMoveTime = time
        guard canDetect else {
            reset(keepingX: true)
            return nil
        }

        // 繞圈：在半徑內，相鄰兩次取樣間隔夠短時累積角度變化
        if distance < gestures.circleRadiusPx {
            let angle = atan2(dy, dx)
            if let lastAngle, time - lastAngleTime < gestures.circleSampleGapMs {
                var delta = angle - lastAngle
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                turned += delta
            }
            lastAngle = angle
            lastAngleTime = time
        } else {
            lastAngle = nil
        }
        turned *= pow(gestures.circleDecayPerMove, frames)
        if abs(turned) > gestures.circleTurns * 2 * .pi {
            turned = 0
            return .circle
        }

        // 甩動：夠快（每格超過 shake_min_dx_px）的水平移動換方向的次數；停太久就重算
        if abs(moveX) / frames > gestures.shakeMinDxPx && distance < gestures.shakeRadiusPx {
            if lastDx != 0 && (moveX > 0) != (lastDx > 0) {
                reversals += 1
                reversalTime = time
            }
            lastDx = moveX
        }
        if time - reversalTime > gestures.shakeResetMs { reversals = 0 }
        if reversals >= gestures.shakeReversals {
            reversals = 0
            return .shake
        }

        // 停留：在角色身上超過 hover_shy_ms
        if distance < radius {
            if let hoverStart {
                if time - hoverStart > hoverShyMs {
                    self.hoverStart = nil
                    return .hover
                }
            } else {
                hoverStart = time
            }
        } else {
            hoverStart = nil
        }
        return nil
    }

    /// 滑鼠離開面板：全部重來
    public mutating func reset() { reset(keepingX: false) }

    private mutating func reset(keepingX: Bool) {
        turned = 0
        lastAngle = nil
        reversals = 0
        hoverStart = nil
        if !keepingX {
            lastX = nil
            lastDx = 0
            lastMoveTime = nil
        }
    }

    /// 點擊是否落在角色上（半徑的 `tap_hit_radius` 倍）
    public func hits(_ point: CGPoint, center: CGPoint, radius: Double) -> Bool {
        hypot(point.x - center.x, point.y - center.y) < radius * gestures.tapHitRadius
    }
}
