import Foundation

/// 表情與動畫的腳本（MASCOT-SPEC 第 5 節；數值同 notch-demo.html 的 EXP_）。每個動畫開始前先歸零（`neutral`），
/// 播完由狀態機的 `pose` 事件接回模式姿勢。
extension MascotScripts {
    public func animation(_ animation: MascotAnimation, start: Int, from base: MascotPose, level: Int) -> MascotScript {
        var s = MascotScript(start: start, base: base)
        if animation == .squeeze {
            neutral(&s, duration: 100)
        } else {
            neutral(&s, duration: config.poses.neutralMs)
        }
        switch animation {
        case .hop:
            s.setEyes(.happy)
            s.to([.follow: 0, .yaw: 0, .pitch: 0.05], 150)
            Self.hop(&s, height: 0.8)
        case .wave:
            var hands: [MascotProp: Double] = [.hands: 1]
            hands.merge(restHands) { $1 }
            s.to(hands, 380, .back)
            s.to([.wave: 1], 220)
            s.to([.sway: 0.6, .pitch: 0.15, .yaw: -0.2, .follow: 0], 300, .inOut)
            s.setEyes(.happy, at: 350)
            s.to([.wave: 0, .sway: 0], 220, at: 1500)
            s.to([.hands: 0], 280, .inCubic, at: 1500)
            s.setEyes(.pill, at: 1500)
        case .dizzy:
            s.setEyes(.spiral)
            s.to([.follow: 0, .orbit: 1, .sway: 1.2, .hands: 1, .lx: -1.1, .ly: 0.9, .lz: 0.3, .rx: 1.1, .ry: 0.9, .rz: 0.3], 320)
            s.to([.orbit: 0, .sway: 0], 300, at: 2300)
            s.to([.hands: 0], 300, .inCubic, at: 2300)
            s.setEyes(.pill, at: 2500)
            s.to([.yaw: -0.3], 90, .inOut, at: 2500)
            s.to([.yaw: 0.3], 110, .inOut, at: 2600)
            s.to([.yaw: 0], 120, .inOut, at: 2720)
        case .shy:
            s.to([.follow: 0, .yaw: -0.42, .pitch: -0.28, .roll: -0.08, .blush: 1], 360, .inOut)
            s.to([.hands: 1, .lx: -0.74, .ly: 0.3, .lz: 0.9, .rx: -0.12, .ry: 0.3, .rz: 0.9], 420)
            s.setEyes(.happy, at: 150)
            s.effect(.heart, duration: 1300, at: 300)
            s.to([.rx: 0.42, .ry: 0.62, .rz: 0.8, .yaw: -0.2, .pitch: -0.1], 260, .inOut, at: 1050)
            s.setEyes(.pill, at: 1050)
            s.to([.rx: -0.12, .ry: 0.3, .rz: 0.9, .yaw: -0.42, .pitch: -0.28], 240, .inOut, at: 1450)
            s.setEyes(.happy, at: 1450)
            s.to([.blush: 0], 300, at: 1900)
        case .scared:
            s.setEyes(.dot)
            s.to([.follow: 0, .yaw: 0, .pitch: 0.1, .sx: 1.2, .sy: 0.8], 70)
            s.effect(.bang, duration: 1200)
            s.to([.jump: -1.0, .sx: 0.85, .sy: 1.18], 200, at: 70)
            s.to([.hands: 1, .lx: -1.15, .ly: -0.55, .lz: 0.25, .rx: 1.15, .ry: -0.55, .rz: 0.25], 240, .back, at: 70)
            s.to([.jump: 0, .sx: 1, .sy: 1], 220, .inCubic, at: 270)
            s.to([.sx: 1.1, .sy: 0.9], 70, at: 490)
            s.to([.sx: 1, .sy: 1], 140, .inOut, at: 560)
            s.to([.shiver: 1], 100, at: 560)
            s.to([.shiver: 0], 200, at: 1250)
        case .wake:
            s.setEyes(.dot)
            s.to([.pitch: 0, .dash: 0, .breathe: 0, .glow: 0.5], 260)
            s.effect(.bang, duration: 1000)
            Self.hop(&s, height: 0.5)
            s.setEyes(.pill, at: 500)
        case .alert:
            s.setEyes(level >= 2 ? .dot : .pill)
            s.effect(.ring(level: level), duration: 900)
            s.to([.glow: 1], 150)
            s.to([.glow: 0.5], 500, at: 300)
            Self.hop(&s, height: 0.6)
        case .squeeze:
            s.setEyes(.xx)
            s.to([.follow: 0, .sx: 1.3, .sy: 0.7, .hands: 1, .lx: -1.38, .ly: 0.38, .lz: 0.2, .rx: 1.38, .ry: 0.38, .rz: 0.2,
                  .pitch: 0, .yaw: 0], 180)
        }
        s.finalize()
        return s
    }

    /// 放開捏扁：像果凍回彈
    public func squeezeRelease(start: Int, from base: MascotPose) -> MascotScript {
        var s = MascotScript(start: start, base: base, eyes: .happy)
        s.to([.sx: 0.8, .sy: 1.22], 110)
        s.to([.sx: 1.1, .sy: 0.9], 120, .inOut, at: 110)
        s.to([.sx: 0.96, .sy: 1.04], 120, .inOut, at: 230)
        s.to([.sx: 1, .sy: 1], 170, .inOut, at: 350)
        s.to([.hands: 0], 250, .inCubic, at: 250)
        s.finalize()
        return s
    }

    /// 每個動畫開始前歸零（demo 的 neutral）：手、晃動、腮紅、壓扁、彈跳、繞圈、發抖、呼吸、打字
    private func neutral(_ s: inout MascotScript, duration: Int) {
        s.setEyes(.pill)
        s.to([.sx: 1, .sy: 1, .jump: 0, .orbit: 0, .shiver: 0, .blush: 0, .wave: 0, .sway: 0, .roll: 0, .dash: 0, .breathe: 0,
              .type: 0, .kb: 0, .hands: 0], duration, .inOut)
    }
}
