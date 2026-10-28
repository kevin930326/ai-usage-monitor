import Foundation
import Testing
@testable import UsageKit

/// 第二輪第 0 部分：額度改用表情（沒有狀態點）、睡覺看 AI 是否閒置、全畫面看滑鼠、選單的表情與動作
@Suite struct MascotMoodTests {
    static func config() throws -> MascotConfig { try MascotDirectorTests.config() }

    @Test func quotaMoodsDifferInShapeNotJustColor() {
        // ADR-0008：不能只靠顏色。四種額度表情的眼睛（形狀、眼皮、眉毛）都不同
        let moods = [MascotMood.quota(level: 0, unavailable: false), .quota(level: 1, unavailable: false),
                     .quota(level: 2, unavailable: false), .quota(level: 0, unavailable: true)]
        #expect(moods == [.normal, .worried, .out, .stale])
        let shapes = moods.map { "\($0.eyes?.rawValue ?? "pill")/\($0.lid)/\($0.brow)" }
        #expect(Set(shapes).count == 4)
        // 讀取失敗或過期優先於用完（額度不明時不畫 ×）
        #expect(MascotMood.quota(level: 2, unavailable: true) == .stale)
    }

    @Test func moodEyesDoNotBlink() throws {
        var d = MascotDirector(config: try Self.config(), seed: 3, startTime: 0)
        d.open(at: 0, intro: false)
        d.setMood(.worried)
        #expect(stride(from: 1000, to: 12_000, by: 10).allSatisfy { d.blink(at: $0) == 0 })
        d.setMood(.normal)
        #expect(stride(from: 1000, to: 12_000, by: 10).contains { d.blink(at: $0) > 0.99 })
    }

    @Test func menuFaceShowsChosenMoodThenReturns() throws {
        let config = try Self.config()
        var d = MascotDirector(config: config, startTime: 0)
        d.open(at: 0, intro: false)
        d.advance(to: 1000)
        d.setMood(.worried)
        d.requestFace(.sick, at: 1000)
        #expect(d.mood(at: 1500) == .sick)
        d.advance(to: 1000 + config.timing.duration(of: .face) + 10)
        #expect(d.mood(at: d.machine.now) == .worried)
    }

    @Test func collapsedSleepIsAStillPoseWithDoze() throws {
        let config = try Self.config()
        var d = MascotDirector(config: config, startTime: 0)
        d.setAgentIdle(true, at: 0)
        #expect(d.mode == .sleep && d.showsDoze && !d.showsSleep)
        let pose = d.pose(at: 600)
        #expect(pose[.dash] == 1 && pose[.pitch] < 0 && pose[.follow] == 0 && pose[.breathe] == 0)
        // 換姿勢之後完全靜止：不重畫
        #expect(!d.isAnimating(at: 600) && !d.isIdleMoving(at: 600))
        // 收著時游標移動：睡著的臉不跟著轉，也不重畫
        let turned = d.look(at: 700, dx: 300, dy: 200)
        #expect(turned && !d.isIdleMoving(at: 750))
        // 展開：照樣睡（有 z、呼吸）；收合後回到閉眼的迷你角色
        d.open(at: 1000, intro: false)
        #expect(d.showsSleep && !d.showsDoze)
        d.close(at: 3000)
        d.advance(to: 4000)
        #expect(d.pose(at: 4000)[.dash] == 1 && d.showsDoze)
        // AI 開始動了：醒來、睜眼
        d.setAgentIdle(false, at: 4000)
        #expect(d.pose(at: 4600)[.dash] == 0 && !d.showsDoze)
    }

    @Test func pointerMovesCollapsedEyesOnlyAboveThreshold() throws {
        var d = MascotDirector(config: try Self.config(), startTime: 0)
        #expect(!d.isIdleMoving(at: 100))
        let turned = d.look(at: 100, dx: 400, dy: 300, threshold: 0.02)
        #expect(turned)
        // 收著時視線也會轉（全畫面看滑鼠），轉到位後停止重畫
        #expect(d.isIdleMoving(at: 150))
        #expect(!d.isIdleMoving(at: 3000))
        // 差不到門檻：不更新、不重畫
        let small = d.look(at: 3000, dx: 401, dy: 301, threshold: 0.02)
        #expect(!small)
        #expect(!d.isIdleMoving(at: 3010))
        let gaze = d.gaze(at: 3000)
        #expect(gaze.yaw > 0.5 && gaze.pitch < -0.3)   // 游標在右下：往右下看
    }

    @Test func mouseMovementDoesNotWake() throws {
        var d = MascotDirector(config: try Self.config(), startTime: 0)
        d.open(at: 0, intro: false)
        d.setAgentIdle(true, at: 100)
        for t in stride(from: 200, to: 5000, by: 100) { d.move(at: t) }
        #expect(d.mode == .sleep && d.machine.playing == nil)
    }

    @Test func everyTapReactionAndMenuActionReturnsToRest() throws {
        let config = try Self.config()
        for request in MascotRequest.allCases where request != .alert {
            var d = MascotDirector(config: config, startTime: 0)
            d.open(at: 0, intro: false)
            d.advance(to: 1000)
            d.request(request, at: 1000)
            d.advance(to: 1000 + config.timing.duration(of: request.animation) + 1000)
            let pose = d.pose(at: d.machine.now)
            #expect(pose[.hands] < 0.01 && abs(pose[.sx] - 1) < 0.01 && abs(pose[.jump]) < 0.01 && abs(pose[.roll]) < 0.01,
                    "\(request) 沒有回到平常")
            #expect(!d.isAnimating(at: d.machine.now), "\(request) 還在動")
        }
    }

    @Test func tomorrowMorningIsEightNextDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let lateNight = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 16:00 台北
        let until = MascotQuiet.tomorrowMorning(after: lateNight, calendar: calendar)
        let parts = calendar.dateComponents([.day, .hour, .minute], from: until)
        #expect(parts.hour == 8 && parts.minute == 0)
        #expect(until > lateNight && until.timeIntervalSince(lateNight) < 24 * 3600)
    }
}
