import Foundation
import Testing
@testable import UsageKit

/// 角色的畫面（ADR-0016 第 1 節）：姿勢是「狀態＋時間＋種子」的純函式；換段時姿勢連續；彈簧、漣漪與眨眼照 demo 的數字。
@Suite struct MascotDirectorTests {
    static func config() throws -> MascotConfig {
        try MascotConfig.decode(Data(contentsOf: MascotGoldenTests.configURL))
    }

    @Test func configDecodesWholeFile() throws {
        let config = try Self.config()
        #expect(config.panel.collapsed.width == 250)
        #expect(config.panel.expanded.height == 180)
        #expect(config.panel.openSpring.stiffness == 190)
        #expect(config.hero.card.radius == 33)
        #expect(config.ripple.particles == 560)
        #expect(config.ripple.edgeFlash.ms == 320)
        #expect(config.intro.ringsAt == [40, 190, 360, 560])
        // 眼睛中心距約直徑 27%：sin(0.3) ≈ 0.296R → 兩眼相距 ≈ 0.59R ≈ 直徑的 29.5%（球面投影後正面看）
        #expect(abs(2 * sin(config.hero.eye.yaw) / 2 - 0.27) < 0.03)
    }

    @Test func sameEventsGiveSameFrames() throws {
        let config = try Self.config()
        func run() -> MascotDirector {
            var d = MascotDirector(config: config, seed: 42, startTime: 0)
            d.open(at: 0, intro: true)
            d.advance(to: 6000)
            d.request(.wave, at: 6000)
            return d
        }
        let a = run(), b = run()
        for t in stride(from: 0, through: 8000, by: 137) {
            #expect(a.pose(at: t) == b.pose(at: t))
            #expect(a.blink(at: t) == b.blink(at: t))
        }
    }

    @Test func introEndsOnCharacterCard() throws {
        let config = try Self.config()
        var d = MascotDirector(config: config, startTime: 0)
        d.open(at: 0, intro: true)
        let start = d.pose(at: 0)
        #expect(abs(start[.sc]) < 1e-9)
        #expect(start[.tint] == 0)
        #expect(start[.pitch] == config.intro.startPitch)
        d.advance(to: 6000)
        let end = d.pose(at: 6000)
        #expect(abs(end[.x] - config.hero.card.x) < 0.01)
        #expect(abs(end[.r] - config.hero.card.radius) < 0.01)
        #expect(end[.tint] == 1 && end[.dot] == 1 && end[.hands] == 0)
        // 4680 ms 起內容浮現、開始接受互動
        #expect(d.content(at: 4600).opacity == 0)
        #expect(d.content(at: 5100).opacity > 0.9)
        #expect(d.isIntro == false)
    }

    @Test func poseIsContinuousWhenSegmentsChange() throws {
        let config = try Self.config()
        var d = MascotDirector(config: config, startTime: 0)
        d.open(at: 0, intro: false)
        d.request(.dizzy, at: 1000)
        let before = d.pose(at: 1999)
        d.close(at: 2000)
        let after = d.pose(at: 2000)
        for prop in MascotProp.allCases {
            #expect(abs(before[prop] - after[prop]) < 0.05, "\(prop) 在收合時跳動")
        }
        d.advance(to: 3000)
        let collapsed = d.pose(at: 3000)
        #expect(abs(collapsed[.r] - config.hero.mini.radius) < 0.01)
        #expect(collapsed[.hands] == 0 && collapsed[.orbit] == 0)
    }

    @Test func everyAnimationReturnsToNeutralParts() throws {
        // 每個動畫開始前歸零：上一個留下的手、晃動、繞圈不會殘留到下一個的結尾
        let config = try Self.config()
        for animation in [MascotRequest.hop, .wave, .dizzy, .shy, .scared, .alert] {
            var d = MascotDirector(config: config, startTime: 0)
            d.open(at: 0, intro: false)
            d.request(.wave, at: 1000)
            d.click(at: 1100, choice: .hop)
            d.advance(to: 4000)
            d.request(animation, at: 4000)
            d.advance(to: 9000)
            let rest = d.pose(at: 9000)
            for prop in [MascotProp.hands, .wave, .sway, .orbit, .shiver, .blush, .jump, .type, .kb] {
                #expect(abs(rest[prop]) < 0.001, "\(animation) 之後 \(prop) 沒有歸零")
            }
        }
    }

    @Test func waveKeepsHandInFront() throws {
        // 揮手時手不穿過身體：右手的 z 一直是正的
        let config = try Self.config()
        let scripts = MascotScripts(config: config)
        let s = scripts.animation(.wave, start: 0, from: scripts.cardPose, level: 0)
        for t in stride(from: 0, through: 1800, by: 20) {
            #expect(s.pose(at: t)[.rz] > 0)
        }
    }

    @Test func workPoseAfterReaction() throws {
        let config = try Self.config()
        var d = MascotDirector(config: config, startTime: 0)
        d.open(at: 0, intro: false)
        d.setWorking(true, at: 1000)
        d.click(at: 2000, choice: .hop)
        d.advance(to: 5000)
        let pose = d.pose(at: 5000)
        #expect(abs(pose[.pitch] - config.poses.work.pitch) < 0.001)
        #expect(pose[.kb] == 1 && pose[.type] == 1)
    }

    @Test func springMatchesDemoShape() throws {
        let config = try Self.config()
        let open = MascotSpring.resting(at: 0).retarget(1, at: 0, stiffness: config.panel.openSpring.stiffness,
                                                         dampingRatio: config.panel.openSpring.dampingRatio)
        // 阻尼比 .74：輕微回彈（超過 1），最後停在 1
        let peak = stride(from: 0, through: 1500, by: 5).map { open.state(at: $0).position }.max() ?? 0
        #expect(peak > 1.0 && peak < 1.05)
        #expect(open.isSettled(at: 2000))
        let close = open.retarget(0, at: 2000, stiffness: 230, dampingRatio: 1)
        let low = stride(from: 2000, through: 4000, by: 5).map { close.state(at: $0).position }.min() ?? 1
        #expect(low >= 0)   // 阻尼比 1：不回彈
        #expect(close.isSettled(at: 4000))
    }

    @Test func edgeFlashLastsOnly320ms() throws {
        let config = try Self.config()
        let ripple = MascotRipple(config: config.ripple, introStart: 0, ringsAt: config.intro.ringsAt,
                                  confettiAt: config.intro.confettiAt, seed: 1)
        let lit = stride(from: 0, through: 3000, by: 1).filter { ripple.edgeFlashAlpha(at: $0, halfWidth: 290) > 0 }
        // 前兩圈各亮一次，每次不超過 0.32 秒
        #expect(!lit.isEmpty)
        #expect(lit.count <= 2 * 320)
        #expect(ripple.rings.count == 4 && ripple.rings[0].particles.count == 560)
        #expect(ripple.endTime <= 560 + 1700)
    }

    @Test func blinksOnlyWhenIdleAndOpen() throws {
        let config = try Self.config()
        var d = MascotDirector(config: config, seed: 3, startTime: 0)
        #expect((0..<20_000).allSatisfy { d.blink(at: $0) == 0 })   // 收合時不眨眼
        d.open(at: 0, intro: false)
        d.move(at: 0, dx: 0, dy: 0)
        let blinks = stride(from: 1000, to: 9000, by: 10).filter { d.blink(at: $0) > 0.99 }
        #expect(!blinks.isEmpty)
        d.request(.shy, at: 9000)
        #expect(stride(from: 9000, to: 11_000, by: 10).allSatisfy { d.blink(at: $0) == 0 })
    }

    @Test func collapsedIdleStopsAnimating() throws {
        let config = try Self.config()
        var d = MascotDirector(config: config, startTime: 0)
        #expect(!d.isAnimating(at: 0) && !d.isLive)
        d.open(at: 0, intro: true)
        #expect(d.isAnimating(at: 100))
        d.close(at: 7000)
        #expect(d.isAnimating(at: 7100))
        d.advance(to: 9000)
        #expect(!d.isAnimating(at: 9000) && !d.isLive)
        // 粒子在收合時清掉
        #expect(d.ripple == nil)
    }

    @Test func idleStopsBetweenBlinks() throws {
        // 展開待著：眨眼中與視線追滑鼠時要重畫，其他時間畫面不動（停止重畫到下一次眨眼）
        let config = try Self.config()
        var d = MascotDirector(config: config, seed: 5, startTime: 0)
        d.open(at: 0, intro: false)
        d.advance(to: 2000)
        d.move(at: 2000, dx: 200, dy: 0)
        #expect(d.isIdleMoving(at: 2050))           // 視線還在轉
        let settled = stride(from: 2000, to: 9000, by: 10).first { !d.isIdleMoving(at: $0) }
        #expect(settled != nil && settled! < 4000)
        let next = d.nextBlink(after: 5000)
        #expect(next > 5000 && next <= 5000 + config.hero.blink.maxGapMs + config.hero.blink.maxGapMs)
        // 下一次眨眼之前畫面不動（不在睡覺邊緣：10 秒沒操作才睡）
        let quiet = stride(from: 5000, to: min(next, 11_900), by: 10).allSatisfy { !d.isIdleMoving(at: $0) || d.blink(at: $0) > 0 }
        #expect(quiet)
        if next + 30 < 12_000 { #expect(d.isIdleMoving(at: next + 30)) }
        // 工作中一直在動
        d.setWorking(true, at: 6000)
        #expect(d.isIdleMoving(at: 6100))
    }
}
