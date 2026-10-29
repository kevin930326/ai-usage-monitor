import Foundation
import Testing
@testable import UsageKit

/// AI 狀態的跨平台一致性（ADR-0017）：讀 `fixtures/agent/cases.json`，用 UsageKit 的
/// `AgentHookInput`、`AgentHookMessage`、`AgentSessions` 算出結果，和 `fixtures/agent/golden.json` 比對。
/// Windows 的 C# 測試讀同一份輸入，必須算出同樣的結果。
///
/// 規則有意改變時：`AUM_UPDATE_GOLDEN=1 swift test --filter AgentGoldenTests` 重新產生 golden.json，
/// 檢查 `git diff` 後和 C# 的修改一起提交。
@Suite struct AgentGoldenTests {
    static let folder = FixtureTests.folder.appendingPathComponent("agent")

    struct Input: Decodable {
        var inputs: [Raw]
        var messages: [Raw]
        var sessions: [SessionCase]
        var remote: [RemoteCase]
        var activity: [ActivityCase]
    }

    /// 角色合併所有電腦（ADR-0019）：本機的旗標＋其他電腦的原始資料。`seen_from`：這份資料裡的出錯先在這台看過
    struct ActivityCase: Decodable {
        var name: String
        var local_now: Int64
        var idle_after_ms: Int64
        var local: Local
        var raw: String
        var seen_from: String?

        struct Local: Decodable {
            var working: Bool
            var idle: Bool
            var needs_you: Bool
            var background: Bool
            var top: String?
        }
    }

    struct RemoteCase: Decodable {
        var name: String
        var local_now: Int64
        var raw: String
    }

    struct Raw: Decodable {
        var name: String
        var raw: String
    }

    struct SessionCase: Decodable {
        var name: String
        var idle_after_ms: Int64?
        var events: [Event]
    }

    struct Event: Decodable {
        var t: Int64
        var e: String
        var ai: String?
        var ev: String?
        var need: String?
        var sid: String?
        var dir: String?
        var sub: Bool?
        /// hook 端的時間（預設同 t）：模擬較早的事件較晚讀完
        var sent: Int64?
        /// AI 程序的 PID（msg）
        var pid: Int32?
        /// 程序清單（baseline、procs）：[[pid, start], …]；procs 為 null 是 AI 程序已經不在
        var procs: [[Int64]]?
        /// 前景宿主代表的 AI 與開始在前景的時間（fg）
        var ais: [String]?
        var since: Int64?
    }

    struct Output: Codable, Equatable {
        var inputs: [Named]
        var messages: [Named]
        var sessions: [Named]
        var remote: [Named]
        var activity: [Named]
    }

    struct Named: Codable, Equatable {
        var name: String
        var result: [String]
    }

    static func extract(_ raw: Raw) -> Named {
        guard let input = AgentHookInput.extract(Data(raw.raw.utf8)) else { return Named(name: raw.name, result: ["nil"]) }
        return Named(name: raw.name, result: ["event=\(input.event.rawValue)", "need=\(input.need?.rawValue ?? "")",
                                              "session=\(input.sessionID)", "folder=\(input.folder)"] + (input.sub ? ["sub"] : []))
    }

    static func parse(_ raw: Raw) -> Named {
        guard let message = AgentHookMessage.parse(Data(raw.raw.utf8)) else { return Named(name: raw.name, result: ["nil"]) }
        return Named(name: raw.name, result: [String(decoding: message.encoded(), as: UTF8.self)])
    }

    static func describe(_ sessions: AgentSessions, at now: Int64) -> String {
        let list = sessions.ordered(at: now).map { s in
            let state = s.state(at: now, idleAfter: sessions.idleAfter)
            let bg = s.checkAt.map { " check@\($0)" } ?? ""
            return "\(s.ai.rawValue)/\(s.id.prefix(4))/\(s.folder):\(state.rawValue)\(s.need.map { "(\($0.rawValue))" } ?? "")@\(s.since)\(bg)"
        }
        let top = sessions.top(at: now).map { "\($0.ai.rawValue)/\($0.id.prefix(4))" } ?? "none"
        return "top=\(top) [\(list.joined(separator: ", "))]"
    }

    static func run(_ testCase: SessionCase) -> Named {
        var sessions = AgentSessions(idleAfter: testCase.idle_after_ms ?? 300_000)
        var log: [String] = []
        // hold：記下現在要拍的基準與要看的工作階段（非同步列程序的途中）；late：途中又有事件之後，才把那時的結果交回來（Codex C-01）
        var held: (baselines: [(ai: AgentKind, id: String, pid: Int32, probe: Int64)], checks: [(ai: AgentKind, id: String, pid: Int32, probe: Int64)]) = ([], [])
        for event in testCase.events {
            switch event.e {
            case "hold":
                held = (sessions.baselineRequests, sessions.backgroundChecks(at: event.t))
                log.append("\(event.t) hold baselines=\(held.baselines.count) checks=\(held.checks.count)")
            case "late":
                for r in held.baselines {
                    sessions.setBaseline(ai: r.ai, id: r.id, pid: r.pid, probe: r.probe, processes: Self.processes(event.procs))
                }
                for c in held.checks {
                    sessions.observe(ai: c.ai, id: c.id, pid: c.pid, probe: c.probe, processes: Self.processes(event.procs), at: event.t)
                }
                held = ([], [])
                let next = sessions.nextBackgroundCheck.map(String.init) ?? "none"
                log.append("\(event.t) late → \(describe(sessions, at: event.t)) next=\(next)")
            case "msg":
                let message = AgentHookMessage(ai: AgentKind(rawValue: event.ai!)!, event: AgentHookEvent(rawValue: event.ev!)!,
                                               need: event.need.flatMap(AgentNeed.init(rawValue:)), session: event.sid!,
                                               time: event.sent ?? event.t, folder: event.dir ?? "", sub: event.sub ?? false,
                                               pid: event.pid ?? 0)
                let applied = sessions.apply(message, at: event.t)
                let wants = sessions.baselineRequests.map { "\($0.ai.rawValue)/\($0.id.prefix(4))" }
                log.append("\(event.t) \(event.ai!) \(event.ev!)\(event.need.map { $0.isEmpty ? "" : "(\($0))" } ?? "")"
                           + "\(event.sub == true ? "[sub]" : "")\(applied ? "" : " (stale)") → \(describe(sessions, at: event.t))"
                           + (wants.isEmpty ? "" : " baseline? \(wants.joined(separator: ","))"))
            case "baseline":
                for request in sessions.baselineRequests {
                    sessions.setBaseline(ai: request.ai, id: request.id, pid: request.pid, probe: request.probe, processes: Self.processes(event.procs))
                }
                log.append("\(event.t) baseline → \(describe(sessions, at: event.t))")
            case "procs":
                let due = sessions.backgroundChecks(at: event.t)
                for check in due {
                    sessions.observe(ai: check.ai, id: check.id, pid: check.pid, probe: check.probe, processes: Self.processes(event.procs), at: event.t)
                }
                let next = sessions.nextBackgroundCheck.map(String.init) ?? "none"
                log.append("\(event.t) procs checked=\(due.count) → \(describe(sessions, at: event.t)) next=\(next)")
            case "fg":
                let ais = Set((event.ais ?? []).compactMap(AgentKind.init(rawValue:)))
                let changed = sessions.markSeenByHost(ais, foregroundSince: event.since ?? event.t, at: event.t)
                let next = sessions.nextHostCheck(ais, foregroundSince: event.since ?? event.t, after: event.t).map(String.init) ?? "none"
                log.append("\(event.t) fg \((event.ais ?? []).joined(separator: "+"))\(changed ? "" : " (no change)") → \(describe(sessions, at: event.t)) next=\(next)")
            case "activity":
                let (working, idle) = sessions.activity(at: event.t, fallback: [:])
                log.append("\(event.t) activity working=\(working) idle=\(idle)")
            case "notices":
                let policy = AgentNoticePolicy()
                let list = sessions.notices(at: event.t, policy: policy).map { n in
                    "\(n.ai.rawValue):\(n.kind.rawValue)\(n.need.map { "(\($0.rawValue))" } ?? "") key=\(n.key)"
                }
                let next = sessions.nextNoticeCheck(after: event.t, policy: policy).map(String.init) ?? "none"
                log.append("\(event.t) notices [\(list.joined(separator: ", "))] next=\(next)")
            case "summary":
                log.append("\(event.t) summary \(String(decoding: AgentSummary.encoded(sessions, at: event.t), as: UTF8.self))")
            case "seen":
                sessions.markSeen(at: event.t)
                log.append("\(event.t) seen → \(describe(sessions, at: event.t))")
            case "expire":
                let changed = sessions.expire(at: event.t)
                log.append("\(event.t) expire\(changed ? "" : " (no change)") → \(describe(sessions, at: event.t))")
            default:
                Issue.record("不認得的事件 \(event.e)")
            }
        }
        return Named(name: testCase.name, result: log)
    }

    static func processes(_ list: [[Int64]]?) -> Set<AgentProcess>? {
        list.map { Set($0.map { AgentProcess(pid: Int32($0[0]), start: $0[1]) }) }
    }

    static func remote(_ testCase: RemoteCase) -> Named {
        let list = RemoteAgents.parse(Data(testCase.raw.utf8), localNow: testCase.local_now)
        return Named(name: testCase.name, result: list.map { "\($0.device)|\($0.ai.rawValue)|\($0.state.rawValue)|\($0.sessions)|\($0.text)" })
    }

    static func activity(_ c: ActivityCase) -> Named {
        let remote = RemoteAgents.parse(Data(c.raw.utf8), localNow: c.local_now, all: true)
        let seen = Set(c.seen_from.map { RemoteAgents.parse(Data($0.utf8), localNow: c.local_now, all: true) }?
            .filter { $0.state == .error }.map(AgentActivity.errorKey) ?? [])
        let a = AgentActivity.combine(localWorking: c.local.working, localIdle: c.local.idle, localNeedsYou: c.local.needs_you,
                                      localBackground: c.local.background, remote: remote, now: c.local_now, idleAfter: c.idle_after_ms,
                                      seenErrors: seen)
        let top = c.local.top.flatMap(AgentState.init(rawValue:))
        func b(_ v: Bool) -> String { v ? "1" : "0" }
        return Named(name: c.name, result: ["working=\(b(a.working)) background=\(b(a.background)) needsYou=\(b(a.needsYou)) "
            + "remoteWorking=\(b(a.remoteWorking)) remoteError=\(b(a.remoteError)) idle=\(b(a.idle)) "
            + "mood=\(a.moodState(localTop: top)?.rawValue ?? "none")"])
    }

    @Test func matchesGolden() throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: Self.folder.appendingPathComponent("cases.json")))
        let output = Output(inputs: input.inputs.map(Self.extract), messages: input.messages.map(Self.parse),
                            sessions: input.sessions.map(Self.run), remote: input.remote.map(Self.remote),
                            activity: input.activity.map(Self.activity))
        let goldenURL = Self.folder.appendingPathComponent("golden.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if ProcessInfo.processInfo.environment["AUM_UPDATE_GOLDEN"] == "1" {
            try (encoder.encode(output) + Data("\n".utf8)).write(to: goldenURL)
        }
        let golden = try JSONDecoder().decode(Output.self, from: Data(contentsOf: goldenURL))
        for (expected, actual) in zip(golden.inputs + golden.messages + golden.sessions + golden.remote + golden.activity,
                                      output.inputs + output.messages + output.sessions + output.remote + output.activity) {
            #expect(expected == actual, "\(actual.name)：\n預期 \(expected.result)\n實際 \(actual.result)")
        }
        #expect(golden.inputs.count == output.inputs.count && golden.messages.count == output.messages.count
                && golden.sessions.count == output.sessions.count && golden.remote.count == output.remote.count
                && golden.activity.count == output.activity.count, "golden.json 與 cases.json 的情境數不同")
    }

    /// 其他電腦的「完成了」：心跳讓中繼收到的時間一直是新的，從進入完成的時間算 30 分鐘就不顯示（畫面停著不重新下載時也會消失）
    @Test func remoteDoneFadesWhileHeartbeatsKeepItFresh() {
        let now: Int64 = 1_800_000_000_000
        let raw = """
        {"now":\(now),"devices":[
          {"device_id":"a","name":"桌機","updated_at":\(now - 60_000),"ais":[{"ai":"claude","state":"done","sessions":3,"since":\(now - 20 * 60_000)}]}
        ]}
        """
        let list = RemoteAgents.parseRelay(Data(raw.utf8), localNow: now)
        #expect(list.map(\.state) == [.done])
        #expect(list[0].expiresAt == now + 10 * 60_000)
        #expect(list[0].isShown(at: now + 10 * 60_000 - 1))
        #expect(!list[0].isShown(at: now + 10 * 60_000))
        // 需要你不淡出：照中繼收到的時間
        let needs = RemoteAgents.parseRelay(Data(raw.replacingOccurrences(of: "\"done\"", with: "\"needsYou\"").utf8), localNow: now)
        #expect(needs[0].expiresAt == now + RemoteAgents.maxAge - 60_000 + 1)
    }

    /// iPhone 直接讀中繼的回應：剛下載（經過 0），所有電腦都列出，30 分鐘以前的不列
    @Test func relayResponseOnPhone() {
        let now: Int64 = 1_800_000_000_000
        let raw = """
        {"now":\(now),"devices":[
          {"device_id":"a","name":"桌機","updated_at":\(now - 60_000),"ais":[{"ai":"claude","state":"needsYou","sessions":1,"since":1}]},
          {"device_id":"b","name":"舊筆電","updated_at":\(now - 31 * 60_000),"ais":[{"ai":"codex","state":"working","sessions":1,"since":1}]},
          {"device_id":"c","name":"工作 PC","updated_at":\(now),"ais":[{"ai":"codex","state":"idle","sessions":0,"since":1}]}
        ]}
        """
        let list = RemoteAgents.parseRelay(Data(raw.utf8), localNow: now + 5_000)
        #expect(list == [RemoteAgent(device: "桌機", ai: .claude, state: .needsYou, sessions: 1, id: "0/claude",
                                     expiresAt: now + 5_000 + RemoteAgents.maxAge - 60_000 + 1,
                                     // 中繼的時間換成本機：中繼的 now 對到下載的那一刻（now + 5 秒）
                                     since: 5_001, updated: now + 5_000 - 60_000)])
        // 畫面停著不重新下載：中繼收到後滿 30 分鐘就不顯示
        #expect(list[0].isShown(at: now + 5_000 + 29 * 60_000))
        #expect(!list[0].isShown(at: now + 5_000 + 29 * 60_000 + 1))
        #expect(list.first?.text == "桌機：Claude Code 需要你")
        #expect(RemoteAgents.parseRelay(Data("[]".utf8), localNow: now).isEmpty)
        // 同名的兩台：列表識別不同
        let twins = """
        {"now":\(now),"devices":[
          {"device_id":"a","name":"MacBook","updated_at":\(now),"ais":[{"ai":"claude","state":"working","sessions":1,"since":1}]},
          {"device_id":"b","name":"MacBook","updated_at":\(now),"ais":[{"ai":"claude","state":"working","sessions":1,"since":1}]}
        ]}
        """
        let ids = RemoteAgents.parseRelay(Data(twins.utf8), localNow: now).map(\.id)
        #expect(ids.count == 2 && Set(ids).count == 2)
        #expect(RemoteAgents.parseRelay(Data("{\"devices\":[]}".utf8), localNow: now).isEmpty)
    }

    /// 隱私：擷取的結果只有事件、種類、ID、資料夾名稱，提示與工具內容不會出現在任何欄位
    @Test func extractDropsContent() throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: Self.folder.appendingPathComponent("cases.json")))
        for raw in input.inputs {
            let joined = Self.extract(raw).result.joined(separator: "\n")
            for secret in ["id_rsa", "rm -rf", "secret?", "/etc/passwd", "curl", "secret answer", "/Users/me", ".jsonl", "step 1"] {
                #expect(!joined.contains(secret), "\(raw.name) 帶出了 \(secret)")
            }
        }
    }

    /// 送出的一行一定能被 App 接受，而且不超過長度上限（最長的資料夾名稱與 ID）
    @Test func encodedMessageRoundTrips() {
        let message = AgentHookMessage(ai: .codex, event: .postToolUseFailure, need: .permission, session: "0123456789abcdef",
                                       time: Int64.max, folder: String(repeating: "名", count: AgentHookInput.maxFolder))
        let data = message.encoded()
        #expect(data.count <= AgentHookMessage.maxLength)
        #expect(AgentHookMessage.parse(data) == message)
    }

    /// 有 hook 的 AI 照 hook，沒有的照修改時間；全部閒置才睡
    @Test func activityPrefersHookAndFallsBackPerAgent() {
        let quiet: [AgentKind: (working: Bool, active: Bool)] = [.claude: (false, false), .codex: (false, false)]
        var sessions = AgentSessions(idleAfter: 300_000)
        #expect(sessions.activity(at: 0, fallback: quiet) == (false, true))
        #expect(sessions.activity(at: 0, fallback: [.codex: (true, true)]) == (true, false))
        let message = { (event: AgentHookEvent, ai: AgentKind) in
            AgentHookMessage(ai: ai, event: event, need: nil, session: "0123456789abcdef", time: 1, folder: "")
        }
        sessions.apply(message(.userPromptSubmit, .claude), at: 0)
        // Claude 的紀錄檔沒動（例如在跑很久的指令），但 hook 說工作中
        #expect(sessions.activity(at: 1000, fallback: quiet) == (true, false))
        sessions.apply(message(.stop, .claude), at: 2000)
        #expect(sessions.activity(at: 3000, fallback: quiet) == (false, false))
        // 完成後看過、等你超過睡覺時間：Codex 也沒動就睡
        sessions.markSeen(at: 4000)
        #expect(sessions.activity(at: 4000 + 300_000, fallback: quiet) == (false, true))
        // hook 只管有工作階段的 AI：Codex 的紀錄檔還在動就醒著
        #expect(sessions.activity(at: 4000 + 300_000, fallback: [.claude: (true, true), .codex: (false, true)]) == (false, false))
    }

    /// 同一次需要你只通知一次：通知後提高門檻、關掉再打開都不重發；處理後的下一次需要你照樣通知（Codex C-04）
    @Test func noticeLogSendsEachStateOnce() {
        var sessions = AgentSessions(idleAfter: 300_000)
        let message = { (event: AgentHookEvent, need: AgentNeed?) in
            AgentHookMessage(ai: .claude, event: event, need: need, session: "0123456789abcdef", time: 1, folder: "")
        }
        var log = AgentNoticeLog()
        let fast = AgentNoticePolicy(needsYouAfter: 20_000), slow = AgentNoticePolicy(needsYouAfter: 120_000)
        let off = AgentNoticePolicy(needsYouAfter: .max, longTask: .max)
        sessions.apply(message(.permissionRequest, .permission), at: 0)
        #expect(log.take(sessions, at: 10_000, policy: fast).isEmpty)
        #expect(log.take(sessions, at: 20_000, policy: fast).count == 1)
        #expect(log.take(sessions, at: 30_000, policy: slow).isEmpty)
        #expect(log.take(sessions, at: 120_000, policy: slow).isEmpty)
        #expect(log.take(sessions, at: 130_000, policy: off).isEmpty)
        #expect(log.take(sessions, at: 140_000, policy: fast).isEmpty)
        // 處理後再一次需要你：新的狀態，照樣通知
        sessions.apply(message(.postToolUse, nil), at: 150_000)
        #expect(log.take(sessions, at: 150_000, policy: fast).isEmpty)
        sessions.apply(message(.permissionRequest, .permission), at: 160_000)
        #expect(log.take(sessions, at: 180_000, policy: fast).count == 1)
    }

    /// 通知關閉（門檻 Int64.max）：不發、也不排下一次檢查，不會溢位
    @Test func disabledNoticesNeverFire() {
        var sessions = AgentSessions(idleAfter: 300_000)
        let off = AgentNoticePolicy(needsYouAfter: .max, longTask: .max)
        sessions.apply(AgentHookMessage(ai: .claude, event: .userPromptSubmit, need: nil, session: "0123456789abcdef", time: 0, folder: ""), at: 0)
        sessions.apply(AgentHookMessage(ai: .claude, event: .permissionRequest, need: .permission, session: "0123456789abcdef",
                                        time: 1000, folder: ""), at: 1_000_000)
        #expect(sessions.notices(at: 9_000_000, policy: off).isEmpty)
        #expect(sessions.nextNoticeCheck(after: 9_000_000, policy: off) == nil)
    }

    /// 出錯難過；完成未看只在額度正常時開心；其他照額度
    @Test func agentMoodKeepsQuotaWarnings() {
        #expect(MascotMood.agent(.error, quota: .out) == .sad)
        #expect(MascotMood.agent(.done, quota: .normal) == .happy)
        #expect(MascotMood.agent(.done, quota: .worried) == .worried)
        #expect(MascotMood.agent(.working, quota: .stale) == .stale)
        #expect(MascotMood.agent(nil, quota: .normal) == .normal)
    }

    @Test func installedEventsAreHandled() {
        for ai in AgentKind.allCases {
            #expect(!AgentHookEvent.installed(for: ai).isEmpty)
        }
        #expect(!AgentHookEvent.installed(for: .codex).contains(.notification), "Codex 沒有 Notification 事件")
        #expect(!AgentHookEvent.installed(for: .claude).contains(.interrupt), "Claude Code 沒有 Interrupt 事件")
    }
}

/// 切回 AI 的程式（ADR-0017 第 8 節）：shared/agent-hosts.json 能讀、終端機代表兩個 AI、格式不對時沒有宿主
@Suite struct AgentHostsTests {
    @Test func readsTheSharedList() throws {
        let url = FixtureTests.folder.deletingLastPathComponent().appendingPathComponent("shared/agent-hosts.json")
        let hosts = AgentHosts.decode(try Data(contentsOf: url))
        #expect(hosts.ais(bundleID: "com.anthropic.claudefordesktop") == [.claude])
        #expect(hosts.ais(bundleID: "com.openai.codex") == [.codex])
        #expect(hosts.ais(bundleID: "com.apple.Terminal") == [.claude, .codex])
        #expect(hosts.ais(bundleID: "COM.MICROSOFT.VSCODE") == [.claude, .codex])
        #expect(hosts.ais(bundleID: "com.apple.Safari").isEmpty)
        #expect(hosts.ais(bundleID: nil).isEmpty)
        #expect(hosts.windows["windowsterminal.exe"] == [.claude, .codex])
        #expect(AgentHosts.decode(Data("{}".utf8)) == AgentHosts())
    }
}
