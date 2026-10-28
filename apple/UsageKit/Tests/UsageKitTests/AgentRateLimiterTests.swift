import Testing
@testable import UsageKit

/// 速率上限只丟「還在跑」的事件，決定狀態的事件一定處理（ADR-0017、Fable F-02）
@Suite struct AgentRateLimiterTests {
    func message(_ event: AgentHookEvent, need: AgentNeed? = nil) -> AgentHookMessage {
        AgentHookMessage(ai: .claude, event: event, need: need, session: "0123456789abcdef", time: 1, folder: "")
    }

    @Test func burstOfToolEventsNeverDropsStop() {
        var limiter = AgentRateLimiter()
        var sessions = AgentSessions(idleAfter: 300_000)
        sessions.apply(message(.userPromptSubmit), at: 0)
        var dropped = 0
        for _ in 0..<50 {
            let tool = message(.postToolUse)
            if limiter.admit(tool, at: 500) { sessions.apply(tool, at: 500) } else { dropped += 1 }
        }
        #expect(dropped == 10)
        for event in [AgentHookEvent.stop, .stopFailure, .sessionEnd, .sessionStart, .userPromptSubmit, .permissionRequest,
                      .notification, .interrupt] {
            let admitted = limiter.admit(message(event), at: 500)
            #expect(admitted, "\(event) 不能被丟")
        }
        let question = limiter.admit(message(.preToolUse, need: .question), at: 500)
        let plainTool = limiter.admit(message(.preToolUse), at: 500)
        #expect(question && !plainTool)
        let stop = message(.stop)
        if limiter.admit(stop, at: 600) { sessions.apply(stop, at: 600) }
        #expect(sessions.top(at: 600)?.stored == .done)
        // 下一秒重新計算
        let nextSecond = limiter.admit(message(.postToolUse), at: 1000)
        #expect(nextSecond)
    }

    @Test func sessionEndAfterBurstRemovesTheSession() {
        var limiter = AgentRateLimiter()
        var sessions = AgentSessions(idleAfter: 300_000)
        for _ in 0..<50 where limiter.admit(message(.postToolUse), at: 0) {
            sessions.apply(message(.postToolUse), at: 0)
        }
        let end = message(.sessionEnd)
        if limiter.admit(end, at: 0) { sessions.apply(end, at: 0) }
        #expect(sessions.isEmpty)
    }
}
