import Foundation

/// 瀏海面板的大小（MASCOT-SPEC 第 3 節）：展開剛度 190、阻尼比 .74（輕微回彈）；收回剛度 230、阻尼比 1（不回彈）。
/// demo 逐格積分；這裡用彈簧的解析解，任一時間點的進度都能直接算出來（截圖可以指定時間）。
public struct MascotSpring: Sendable, Equatable {
    public var target: Double
    public var start: Int
    public var position: Double
    public var velocity: Double
    public var stiffness: Double
    public var dampingRatio: Double

    public init(target: Double, start: Int, position: Double, velocity: Double, stiffness: Double, dampingRatio: Double) {
        self.target = target
        self.start = start
        self.position = position
        self.velocity = velocity
        self.stiffness = stiffness
        self.dampingRatio = dampingRatio
    }

    /// 靜止在某個位置
    public static func resting(at position: Double) -> MascotSpring {
        MascotSpring(target: position, start: 0, position: position, velocity: 0, stiffness: 1, dampingRatio: 1)
    }

    /// (位置, 速度)；時間以毫秒計，速度以「每秒」計
    public func state(at time: Int) -> (position: Double, velocity: Double) {
        let t = Double(max(time - start, 0)) / 1000
        let x0 = position - target, v0 = velocity
        let w = stiffness.squareRoot(), z = dampingRatio
        var x: Double, v: Double
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot()
            let decay = exp(-z * w * t)
            let b = (v0 + z * w * x0) / wd
            x = decay * (x0 * cos(wd * t) + b * sin(wd * t))
            v = decay * ((-z * w) * (x0 * cos(wd * t) + b * sin(wd * t)) + (-x0 * wd * sin(wd * t) + b * wd * cos(wd * t)))
        } else {
            let decay = exp(-w * t)
            let b = v0 + w * x0
            x = (x0 + b * t) * decay
            v = (b - w * (x0 + b * t)) * decay
        }
        // 和 demo 一樣：夠接近就停在終點
        if abs(x) < 0.0005, abs(v) < 0.001 { return (target, 0) }
        return (target + x, v)
    }

    public func isSettled(at time: Int) -> Bool {
        let s = state(at: time)
        return s.position == target && s.velocity == 0
    }

    /// 從 `time` 的位置與速度出發、往新的目標
    public func retarget(_ newTarget: Double, at time: Int, stiffness: Double, dampingRatio: Double) -> MascotSpring {
        let s = state(at: time)
        return MascotSpring(target: newTarget, start: time, position: s.position, velocity: s.velocity,
                            stiffness: stiffness, dampingRatio: dampingRatio)
    }
}

/// 瀏海面板某一刻的外形（demo 的 frame()）
public struct MascotPanelShape: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var corner: Double
    /// 迷你角色與迷你圓環的透明度
    public var miniOpacity: Double
    public var progress: Double

    public init(progress p: Double, bump: Double, panel: MascotConfig.Panel) {
        let c = panel.collapsed, e = panel.expanded
        progress = p
        width = c.width + panel.alertBump.width * bump + (e.width - c.width) * p
        height = c.height + panel.alertBump.height * bump + (e.height - c.height) * p
        corner = c.corner + (e.corner - c.corner) * min(panel.cornerOvershootMax, p)
        miniOpacity = min(max(1 - p * panel.miniFadeFactor, 0), 1)
    }
}

/// 收合時的提醒：瀏海往外鼓一下（寬 +44、高 +5），1.1 秒後收回
public enum MascotBump {
    public static func value(at time: Int, start: Int?, panel: MascotConfig.Panel) -> Double {
        guard let start, time >= start else { return 0 }
        let b = panel.alertBump
        let local = time - start
        let rise = MascotEase.back(Double(local) / Double(b.riseMs))
        guard local >= b.holdMs else { return rise }
        let fall = MascotEase.inOut(Double(local - b.holdMs) / Double(b.fallMs))
        return rise * (1 - fall)
    }

    public static func isActive(at time: Int, start: Int?, panel: MascotConfig.Panel) -> Bool {
        guard let start else { return false }
        return time >= start && time < start + panel.alertBump.holdMs + panel.alertBump.fallMs
    }
}
