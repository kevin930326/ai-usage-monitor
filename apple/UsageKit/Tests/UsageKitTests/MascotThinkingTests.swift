import Testing
@testable import UsageKit

/// 思考泡泡的時間（ADR-0021 第 4 節）
@Suite struct MascotThinkingTests {
    /// 收合時各種一輪的長度：敲鍵盤 2π×310、霓虹 2π×480、線框（迷你 3 條經線）、LED（R = 9）、ASCII
    static let loops = [2 * Double.pi * 310, 2 * Double.pi * 480, 2600 * Double.pi / 3, 2.6 * 9 * 14 * 9, 110.0 * 27]

    @Test func stepsDivideTheLoopNearTheTarget() {
        for loop in Self.loops {
            let step = MascotThinking.stepMs(loop: loop)
            #expect((225...260).contains(step), "\(loop)")
            let steps = loop / step
            #expect(abs(steps - steps.rounded()) < 1e-9 && Int(steps.rounded()) % 4 == 0, "\(loop)")
        }
    }

    @Test func countsUpThenClears() {
        let loop = 2 * Double.pi * 310
        let step = MascotThinking.stepMs(loop: loop)
        #expect(MascotThinking.dots(at: 0, loop: loop) == 0)
        #expect((0..<4).map { MascotThinking.dots(at: Int((Double($0) + 0.5) * step), loop: loop) } == [0, 1, 2, 3])
        #expect(MascotThinking.dots(at: Int(4.5 * step), loop: loop) == 0)
        // 一輪的最後一刻是三顆全亮，接回開頭是 0 顆
        #expect(MascotThinking.dots(at: Int(loop) - 1, loop: loop) == 3)
        #expect(MascotThinking.dots(at: Int(loop) + 1, loop: loop) == 0)
    }
}
