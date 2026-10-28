import Foundation
import Testing
@testable import UsageKit

/// 面板裡的手勢（ADR-0016 第 2 節）：照 demo 的門檻；忙碌時不累積
@Suite struct MascotGestureTests {
    static let center = CGPoint(x: 100, y: 100)

    static func detector() throws -> MascotGestureDetector {
        MascotGestureDetector(config: try MascotDirectorTests.config())
    }

    /// 以 `radius` 繞角色 `turns` 圈，每 `gap` 毫秒一個取樣、每次轉 `step` 弧度；回傳第一個觸發的手勢與時間
    static func circle(_ d: inout MascotGestureDetector, radius: Double, turns: Double, step: Double = 0.25,
                       gap: Double = 1000.0 / 60, canDetect: Bool = true) -> (MascotGesture, Int)? {
        var t = 0.0
        var angle = 0.0
        while angle < turns * 2 * .pi {
            let p = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if let g = d.move(to: p, at: Int(t), center: center, radius: 33, canDetect: canDetect) { return (g, Int(t)) }
            angle += step
            t += gap
        }
        return nil
    }

    @Test func twoTurnsMakeDizzy() throws {
        var d = try Self.detector()
        // 一秒多一點繞一圈多（半徑 45：水平移動每格不到 12 px，不算甩動）
        let hit = Self.circle(&d, radius: 45, turns: 6)
        #expect(hit?.0 == .circle)
        // 衰減下要繞超過兩圈才觸發
        var once = try Self.detector()
        #expect(Self.circle(&once, radius: 45, turns: 1.9) == nil)
    }

    @Test func circleFeelsTheSameAt120Hz() throws {
        // 同樣的手速，滑鼠事件加倍（每次轉一半）：觸發的時間差不到一格
        var at60 = try Self.detector()
        var at120 = try Self.detector()
        let slow = Self.circle(&at60, radius: 45, turns: 6)
        let fast = Self.circle(&at120, radius: 45, turns: 6, step: 0.125, gap: 1000.0 / 120)
        #expect(slow?.0 == .circle && fast?.0 == .circle)
        if let slow, let fast { #expect(abs(slow.1 - fast.1) <= 34) }
    }

    @Test func circlingFarAwayOrSlowlyDoesNothing() throws {
        var far = try Self.detector()
        #expect(Self.circle(&far, radius: 150, turns: 8, step: 0.07) == nil)   // 超出 130（慢慢繞，也不算甩動）
        // 取樣間隔超過 200 ms 時不累積
        var slow = try Self.detector()
        var t = 0
        var angle = 0.0
        var fired: MascotGesture?
        while angle < 6 * .pi {
            let p = CGPoint(x: Self.center.x + 80 * cos(angle), y: Self.center.y + 80 * sin(angle))
            fired = fired ?? slow.move(to: p, at: t, center: Self.center, radius: 33, canDetect: true)
            angle += 0.25
            t += 250
        }
        #expect(fired == nil)
    }

    @Test func busyClearsAccumulation() throws {
        var d = try Self.detector()
        #expect(Self.circle(&d, radius: 45, turns: 1.8) == nil)
        _ = d.move(to: CGPoint(x: 180, y: 100), at: 2000, center: Self.center, radius: 33, canDetect: false)
        #expect(d.turned == 0)
        #expect(Self.circle(&d, radius: 45, turns: 6, canDetect: false) == nil)
    }

    @Test func fastShakeMakesScared() throws {
        var d = try Self.detector()
        var fired: (MascotGesture, Int)?
        var x = 100.0
        for i in 0..<20 where fired == nil {
            x += (i % 2 == 0 ? 30 : -30)
            if let g = d.move(to: CGPoint(x: x, y: 60), at: i * 17, center: Self.center, radius: 33, canDetect: true) {
                fired = (g, i)
            }
        }
        #expect(fired?.0 == .shake)
        // 第一個取樣沒有位移、第二個定方向，之後每個都換方向：第 5 次換方向是第 7 個取樣
        #expect(fired?.1 == 6)
    }

    @Test func slowOrSmallShakeDoesNothing() throws {
        var small = try Self.detector()
        var x = 100.0
        for i in 0..<30 {
            x += (i % 2 == 0 ? 10 : -10)   // 每格不到 12 px
            #expect(small.move(to: CGPoint(x: x, y: 60), at: i * 17, center: Self.center, radius: 33, canDetect: true) == nil)
        }
        var slow = try Self.detector()
        for i in 0..<30 {
            x += (i % 2 == 0 ? 30 : -30)
            // 慢慢移（每 100 ms 30 px，每格約 5 px）
            #expect(slow.move(to: CGPoint(x: x, y: 60), at: i * 100, center: Self.center, radius: 33, canDetect: true) == nil)
        }
    }

    @Test func restingOnCharacterMakesShy() throws {
        var d = try Self.detector()
        let p = CGPoint(x: 105, y: 98)
        #expect(d.move(to: p, at: 0, center: Self.center, radius: 33, canDetect: true) == nil)
        #expect(d.move(to: p, at: 800, center: Self.center, radius: 33, canDetect: true) == nil)
        #expect(d.move(to: p, at: 801, center: Self.center, radius: 33, canDetect: true) == .hover)
        // 觸發後重新計時
        #expect(d.move(to: p, at: 900, center: Self.center, radius: 33, canDetect: true) == nil)
        // 移出角色就重來
        var out = try Self.detector()
        _ = out.move(to: p, at: 0, center: Self.center, radius: 33, canDetect: true)
        _ = out.move(to: CGPoint(x: 160, y: 100), at: 400, center: Self.center, radius: 33, canDetect: true)
        #expect(out.move(to: p, at: 900, center: Self.center, radius: 33, canDetect: true) == nil)
    }

    @Test func tapHitRadius() throws {
        let d = try Self.detector()
        #expect(d.hits(CGPoint(x: 100 + 33 * 1.19, y: 100), center: Self.center, radius: 33))
        #expect(!d.hits(CGPoint(x: 100 + 33 * 1.21, y: 100), center: Self.center, radius: 33))
    }
}
