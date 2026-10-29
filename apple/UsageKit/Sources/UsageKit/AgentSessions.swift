import Foundation

// AI 的確切狀態（ADR-0017）：Claude Code 與 Codex 的 hook 把事件送到 App，這裡是三段共用邏輯——
// hook 從事件 JSON 只挑出幾個欄位（`AgentHookInput`）、App 驗證 socket 收到的一行（`AgentHookMessage`）、
// 每個工作階段的狀態與彙總（`AgentSessions`）。Windows 的 UsageCore/AgentSessions.cs 跑同一份
// `fixtures/agent/` golden。

/// 哪個 AI
public enum AgentKind: String, Sendable, CaseIterable, Codable {
    case claude, codex
}

/// 「需要你」與其他事件的種類（hook 從事件推得，只傳種類、不傳工具名稱或訊息）
public enum AgentNeed: String, Sendable, Codable {
    /// 等你批准權限
    case permission
    /// 問你問題（AskUserQuestion、elicitation）
    case question
    /// 等你批准計畫（ExitPlanMode）
    case plan
    /// Claude Code 的 idle_prompt：已經在等你輸入一段時間
    case idle
}

/// hook 送出的事件（官方的 hook_event_name；白名單以外的名稱一律不送）
public enum AgentHookEvent: String, Sendable, CaseIterable, Codable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case interrupt = "Interrupt"

    /// 安裝時要掛上的事件（各 AI 的官方文件有的才掛；2026-10-28 查閱）
    public static func installed(for ai: AgentKind) -> [AgentHookEvent] {
        switch ai {
        case .claude:
            [.sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
             .permissionRequest, .notification, .stop, .stopFailure, .subagentStop, .preCompact]
        case .codex:
            [.sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .permissionRequest,
             .stop, .subagentStop, .preCompact, .interrupt]
        }
    }
}

// MARK: - hook：從事件 JSON 只挑出需要的欄位

/// hook 從標準輸入的事件 JSON 取出的東西。其餘欄位（提示、工具輸入與輸出、訊息、紀錄路徑、完整的工作目錄）
/// 在這裡就丟掉，不會進到任何回傳值（隱私底線）。
public struct AgentHookInput: Sendable, Equatable {
    public var event: AgentHookEvent
    public var need: AgentNeed?
    /// 原始的工作階段 ID：只在 hook 裡用來算加鹽雜湊，不送出
    public var sessionID: String
    /// 工作目錄的最後一段（資料夾名稱），只給畫面用
    public var folder: String
    /// 事件來自子代理（輸入有 `agent_id`；只記有沒有，不記內容）
    public var sub: Bool

    public init(event: AgentHookEvent, need: AgentNeed?, sessionID: String, folder: String, sub: Bool = false) {
        self.event = event
        self.need = need
        self.sessionID = sessionID
        self.folder = folder
        self.sub = sub
    }

    /// 事件 JSON 最多讀多少（超過就整個丟掉）
    public static let maxInput = 1 << 20
    /// 資料夾名稱最多幾個字
    public static let maxFolder = 48

    /// 解析事件；格式不對、事件不在白名單、或這個事件不影響狀態（例如不認得的通知）時回傳 nil
    public static func extract(_ data: Data) -> AgentHookInput? {
        guard data.count <= maxInput,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let event = AgentHookEvent(rawValue: name),
              let sessionID = object["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 256
        else { return nil }
        var need: AgentNeed?
        switch event {
        case .notification:
            switch object["notification_type"] as? String {
            case "permission_prompt": need = .permission
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": need = .question
            case "idle_prompt": need = .idle
            default: return nil
            }
        case .permissionRequest:
            need = .permission
        case .preToolUse:
            switch object["tool_name"] as? String {
            case "AskUserQuestion", "request_user_input": need = .question
            case "ExitPlanMode": need = .plan
            default: need = nil
            }
        default:
            need = nil
        }
        // 子代理的事件帶父工作階段的 session_id，另有 agent_id（Fable F-03）
        let sub = (object["agent_id"] as? String).map { !$0.isEmpty } ?? false
        return AgentHookInput(event: event, need: need, sessionID: sessionID,
                              folder: folderName(object["cwd"] as? String), sub: sub)
    }

    /// 完整路徑只取最後一段；去掉控制字元與路徑分隔字元，最多 48 字
    public static func folderName(_ path: String?) -> String {
        guard let path else { return "" }
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard let last = parts.last else { return "" }
        let cleaned = last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(cleaned).prefix(maxFolder))
    }
}

// MARK: - socket：App 收到的一行

/// hook 經 Unix socket 送給 App 的一行 JSON：
/// `{"v":1,"ai":"claude","ev":"Stop","need":"","sub":false,"sid":"0123456789abcdef","t":1761650000000,"dir":"my-project","pid":4242}`。
/// `pid`（AI 程序的 PID，ADR-0017 第 7 節）只有知道時才寫（大於 0），沒有這個鍵就是不知道
public struct AgentHookMessage: Sendable, Equatable, Codable {
    public var ai: AgentKind
    public var event: AgentHookEvent
    public var need: AgentNeed?
    /// 工作階段 ID 的加鹽雜湊（16 個小寫十六進位字元）
    public var session: String
    /// hook 的時鐘（毫秒）
    public var time: Int64
    public var folder: String
    /// 事件來自子代理
    public var sub: Bool
    /// AI 程序的 PID（偵測背景工作用）；0 是不知道
    public var pid: Int32

    public static let version = 1
    /// 一行最多多少位元組（App 讀超過就丟掉）
    public static let maxLength = 1024

    public init(ai: AgentKind, event: AgentHookEvent, need: AgentNeed?, session: String, time: Int64, folder: String,
                sub: Bool = false, pid: Int32 = 0) {
        self.ai = ai
        self.event = event
        self.need = need
        self.session = session
        self.time = time
        self.folder = folder
        self.sub = sub
        self.pid = max(pid, 0)
    }

    /// 送出的一行（不含換行）；鍵的順序固定，Swift 與 C# 輸出相同
    public func encoded() -> Data {
        var fields: [(String, Any)] = [("v", Self.version), ("ai", ai.rawValue), ("ev", event.rawValue),
                                       ("need", need?.rawValue ?? ""), ("sub", sub), ("sid", session), ("t", time),
                                       ("dir", folder)]
        if pid > 0 { fields.append(("pid", Int(pid))) }
        let body = fields.map { key, value -> String in
            let encoded: String = if let text = value as? String { Self.quote(text) } else if let flag = value as? Bool {
                flag ? "true" : "false"
            } else { "\(value)" }
            return "\"\(key)\":\(encoded)"
        }.joined(separator: ",")
        return Data("{\(body)}".utf8)
    }

    /// 驗證收到的一行：版本、欄位、白名單、長度都要對，否則回傳 nil（App 直接丟掉）。
    /// 最後要求重新編碼後和收到的一字不差：`1.0`、`1e3`、重複鍵、多餘空白都不收，Swift 與 C# 一樣嚴格（Fable F-12）
    public static func parse(_ data: Data) -> AgentHookMessage? {
        guard data.count <= maxLength,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).subtracting(["pid"]) == ["v", "ai", "ev", "need", "sub", "sid", "t", "dir"],
              let sub = object["sub"] as? Bool,
              let version = object["v"] as? Int, version == Self.version,
              let ai = (object["ai"] as? String).flatMap(AgentKind.init(rawValue:)),
              let event = (object["ev"] as? String).flatMap(AgentHookEvent.init(rawValue:)),
              let needText = object["need"] as? String,
              let session = object["sid"] as? String, isSessionHash(session),
              let time = (object["t"] as? Int).map(Int64.init), time > 0,
              let folder = object["dir"] as? String, folder == AgentHookInput.folderName(folder) || folder.isEmpty
        else { return nil }
        // 種類只能是空字串或白名單內的值
        let need: AgentNeed?
        if needText.isEmpty { need = nil } else if let value = AgentNeed(rawValue: needText) { need = value } else { return nil }
        var pid: Int32 = 0
        if let value = object["pid"] {
            guard let number = value as? Int, number > 0, number <= Int(Int32.max) else { return nil }
            pid = Int32(number)
        }
        let message = AgentHookMessage(ai: ai, event: event, need: need, session: session, time: time, folder: folder, sub: sub, pid: pid)
        return message.encoded() == data ? message : nil
    }

    public static func isSessionHash(_ text: String) -> Bool {
        text.utf8.count == 16 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

// MARK: - 每個工作階段的狀態與彙總

/// 工作階段的狀態；彙總時依 `rank` 取最高的（需要你 > 出錯 > 工作中 > 背景執行中 > 完成未看 > 等你 > 閒置）。
/// 背景執行中（ADR-0017 第 7 節）不是存的狀態：完成未看或等你、AI 程序底下還有回合中新產生的子孫程序時顯示成它
public enum AgentState: String, Sendable, Codable, CaseIterable {
    case needsYou, error, working, background, done, waiting, idle

    public var rank: Int {
        switch self {
        case .needsYou: 6
        case .error: 5
        case .working: 4
        case .background: 3
        case .done: 2
        case .waiting: 1
        case .idle: 0
        }
    }
}

/// 一個程序的識別：PID 加開始時間（微秒；Windows 是建立時間），PID 被重用時開始時間不同（ADR-0017 第 7 節）
public struct AgentProcess: Sendable, Hashable, Comparable {
    public var pid: Int32
    public var start: Int64

    public init(pid: Int32, start: Int64) {
        self.pid = pid
        self.start = start
    }

    public static func < (a: AgentProcess, b: AgentProcess) -> Bool { (a.pid, a.start) < (b.pid, b.start) }
}

public struct AgentSession: Sendable, Equatable {
    public var ai: AgentKind
    public var id: String
    public var folder: String
    /// 存的狀態（閒置是由「等你」加上時間算出來的，見 `state(at:idleAfter:)`）
    public var stored: AgentState
    /// 需要你的種類
    public var need: AgentNeed?
    /// 進入目前狀態的時間（毫秒）
    public var since: Int64
    /// 最後一個事件的時間（毫秒）
    public var last: Int64
    /// 這一回合開始工作的時間（從不在跑的狀態進入工作中時記下；完成後用來算跑了多久）
    public var turnStart: Int64? = nil
    /// AI 程序的 PID（最新的事件說了算；0 是不知道，不偵測背景工作）
    public var pid: Int32 = 0
    /// 回合開始時 AI 程序底下已經有的子孫程序（常駐的 MCP、語言伺服器）；nil 是還沒拍
    public var baseline: Set<AgentProcess>? = nil
    /// App 要替這個工作階段拍基準（回合開始、或沒有基準就收到 Stop）
    public var wantsBaseline = false
    /// 下一次看背景工作的時間；nil 是不看
    public var checkAt: Int64? = nil
    /// 上一次看到、不在基準裡的子孫程序（候選）。新回合開始時不併進基準（Fable F-06）
    public var pending: Set<AgentProcess> = []
    /// 候選第一次出現的時間；30 分鐘上限從這裡起算
    public var pendingSince: Int64? = nil
    /// 回合結束後連續兩次都看到同一個候選（背景執行中；只看一次的多半是其他 App 跑得久的 Stop hook，Fable F-09）
    public var background = false
    /// 睡覺倒數另外的起點：背景工作結束的時間（不動 `since`，通知與跨裝置的時間照舊，Fable F-11）
    public var awakeSince: Int64? = nil

    /// 醒著倒數的起點
    public var idleFrom: Int64 { max(since, awakeSince ?? since) }

    public func state(at now: Int64, idleAfter: Int64) -> AgentState {
        if background, stored == .done || stored == .waiting { return .background }
        return stored == .waiting && now - idleFrom >= idleAfter ? .idle : stored
    }
}

public struct AgentSessions: Sendable, Equatable {
    /// 工作中超過這麼久沒有事件，當成被中斷了（Claude Code 被使用者中斷時不送 Stop）
    public static let workingTimeout: Int64 = 20 * 60_000
    /// 需要你超過這麼久沒有事件，當成沒人等了（例如直接關掉終端機，沒送 SessionEnd；Fable F-06）
    public static let needsYouTimeout: Int64 = 60 * 60_000
    /// 任何狀態超過這麼久沒有事件就移除（例如 AI 當掉、沒送 SessionEnd）
    public static let forgetAfter: Int64 = 12 * 3_600_000
    /// 同時最多記幾個工作階段（假事件塞爆時丟掉最久沒事件的）
    public static let maxSessions = 32
    /// 主回合 Stop 後多久第一次看背景工作（hook 自己與其他 App 的 Stop hook 大多已經結束）
    public static let backgroundFirstCheck: Int64 = 3_000
    /// 背景執行中（與確認候選）每隔多久再看一次
    public static let backgroundEvery: Int64 = 20_000
    /// 背景執行中最多多久：之後剩下的程序當成常駐的（併進基準），角色才不會永遠不睡
    public static let backgroundMax: Int64 = 30 * 60_000
    /// 基準最多記幾個程序
    public static let maxProcesses = 256

    public private(set) var sessions: [AgentSession] = []
    /// 每個工作階段（含已結束的）最後一個事件在 hook 端的時間：連線是並行讀的，較早的事件可能較晚讀完；
    /// 比這個舊的事件丟掉，免得把完成改回工作中、或重建已結束的工作階段（Codex C-02）。最多記 `maxSessions` × 2 個
    private var latest: [String: Int64] = [:]
    /// 等你多久算閒置（設定的「睡覺」分鐘數）
    public var idleAfter: Int64

    public init(idleAfter: Int64) {
        self.idleAfter = idleAfter
    }

    public var isEmpty: Bool { sessions.isEmpty }

    /// 收到一個事件（時間用 App 收到的時間；hook 的時間只用來排除較晚讀完的舊事件）。舊事件丟掉時回傳 false
    @discardableResult
    public mutating func apply(_ message: AgentHookMessage, at now: Int64) -> Bool {
        let key = "\(message.ai.rawValue)/\(message.session)"
        if let seen = latest[key], message.time < seen { return false }
        latest[key] = message.time
        if latest.count > Self.maxSessions * 2, let oldest = latest.min(by: { $0.value < $1.value })?.key {
            latest[oldest] = nil
        }
        let index = sessions.firstIndex { $0.ai == message.ai && $0.id == message.session }
        if message.event == .sessionEnd {
            if let index { sessions.remove(at: index) }
            return true
        }
        var session = index.map { sessions[$0] }
            ?? AgentSession(ai: message.ai, id: message.session, folder: message.folder, stored: .waiting, need: nil,
                            since: now, last: now)
        if !message.folder.isEmpty { session.folder = message.folder }
        if message.pid > 0 && !message.sub && message.pid != session.pid {
            // 換了程序（例如 resume 到另一個終端機）：舊的基準不適用
            session.pid = message.pid
            session.baseline = nil
            session.pending = []
            session.pendingSince = nil
        }
        session.last = now
        let next = Self.transition(from: session.stored, event: message.event, need: message.need, sub: message.sub)
        let changed = next.map { $0.state != session.stored || $0.need != session.need } ?? false
        if let next, changed {
            let wasRunning = session.stored == .working || session.stored == .needsYou
            if next.state == .working && !wasRunning { session.turnStart = now }
            session.stored = next.state
            session.need = next.need
            session.since = now
        }
        Self.trackBackground(&session, event: message.event, sub: message.sub, changed: changed, at: now)
        if let index {
            sessions[index] = session
        } else {
            sessions.append(session)
            if sessions.count > Self.maxSessions,
               let oldest = sessions.indices.min(by: { sessions[$0].last < sessions[$1].last }) {
                sessions.remove(at: oldest)
            }
        }
        return true
    }

    /// 背景工作的記錄（ADR-0017 第 7 節）：回合開始拍基準（候選不併進去）；每一次主回合 Stop 後 3 秒看一次（Stop→Stop 也重排，Fable F-07）；
    /// 其他改變狀態的事件（工作中、需要你、出錯、中斷、新開始）都不看、不顯示背景（Fable F-13）。候選與它的起始時間跨回合保留
    static func trackBackground(_ session: inout AgentSession, event: AgentHookEvent, sub: Bool, changed: Bool, at now: Int64) {
        if event == .userPromptSubmit {
            session.baseline = nil
            session.wantsBaseline = session.pid > 0
        }
        if event == .stop && !sub && session.stored == .done {
            guard session.pid > 0 else { session.checkAt = nil; return }
            if session.baseline == nil {
                // App 在回合中途才啟動、或沒收到回合開始：現在才拍基準，這一回合不判斷（寧可漏報）
                session.wantsBaseline = true
                session.checkAt = nil
            } else {
                session.checkAt = now + AgentSessions.backgroundFirstCheck
            }
        } else if changed {
            session.background = false
            session.checkAt = nil
        }
    }

    /// 狀態轉換；nil 表示不變
    static func transition(from state: AgentState, event: AgentHookEvent, need: AgentNeed?,
                           sub: Bool = false) -> (state: AgentState, need: AgentNeed?)? {
        // 子代理（例如主回合 Stop 之後還在跑的背景子代理）的工具事件只代表還在跑：
        // 不把完成、等你、出錯改回工作中（Fable F-03）；子代理要權限或問問題照樣是需要你
        let stillRunning = state == .working || state == .needsYou
        switch event {
        case .sessionStart:
            // 回合中途自動壓縮也會送 SessionStart（source=compact）：工作中時維持（Fable F-07）
            return state == .working ? nil : (.waiting, nil)
        case .interrupt:
            return (.waiting, nil)
        case .userPromptSubmit:
            return (.working, nil)
        case .postToolUse, .postToolUseFailure:
            return sub && !stillRunning ? nil : (.working, nil)
        case .preToolUse:
            if let need, need != .idle { return (.needsYou, need) }
            return sub && !stillRunning ? nil : (.working, nil)
        case .permissionRequest:
            return (.needsYou, .permission)
        case .notification:
            switch need {
            case .permission?, .question?, .plan?: return (.needsYou, need)
            // 已經等你輸入一陣子：還記成工作中的（漏了 Stop）改成等你；完成未看、需要你維持
            case .idle?: return state == .working ? (.waiting, nil) : nil
            case nil: return nil
            }
        case .stop:
            return (.done, nil)
        case .stopFailure:
            return (.error, nil)
        // 子代理與壓縮只代表還在跑：工作中或剛批准（需要你）時算工作中，其他狀態不變
        case .subagentStart, .subagentStop, .preCompact, .postCompact:
            return stillRunning ? (.working, nil) : nil
        case .sessionEnd:
            return nil
        }
    }

    /// 使用者看過了（展開瀏海或點角色）：完成未看與出錯都變成等你
    public mutating func markSeen(at now: Int64) {
        for i in sessions.indices where sessions[i].stored == .done || sessions[i].stored == .error {
            sessions[i].stored = .waiting
            sessions[i].need = nil
            sessions[i].since = now
        }
    }

    /// 切回 AI 的程式（ADR-0017 第 8 節）：前景是代表 `ais` 的宿主程式、從 `foregroundSince` 開始在前景。
    /// 這些 AI 的「完成未看」在完成之後才切過來的、或完成後在前景停留滿 `dwell` 的，變成等你；需要你與出錯不動。回傳是否有改變
    @discardableResult
    public mutating func markSeenByHost(_ ais: Set<AgentKind>, foregroundSince: Int64, at now: Int64, dwell: Int64 = AgentHosts.dwellMs) -> Bool {
        var changed = false
        for i in sessions.indices where sessions[i].stored == .done && ais.contains(sessions[i].ai) {
            guard sessions[i].since < foregroundSince || now - sessions[i].since >= dwell else { continue }
            sessions[i].stored = .waiting
            sessions[i].need = nil
            sessions[i].since = now
            changed = true
        }
        return changed
    }

    /// 宿主程式一直在前景時，下一次要看「完成後停留滿 3 秒」的時間；沒有就是 nil
    public func nextHostCheck(_ ais: Set<AgentKind>, foregroundSince: Int64, after now: Int64, dwell: Int64 = AgentHosts.dwellMs) -> Int64? {
        sessions.filter { $0.stored == .done && ais.contains($0.ai) && $0.since >= foregroundSince && $0.since + dwell > now }
            .map { $0.since + dwell }
            .min()
    }

    // MARK: 背景工作（ADR-0017 第 7 節）

    /// 要拍基準的工作階段（AI、ID、AI 程序的 PID）
    public var baselineRequests: [(ai: AgentKind, id: String, pid: Int32)] {
        sessions.filter { $0.wantsBaseline && $0.pid > 0 }.map { ($0.ai, $0.id, $0.pid) }
    }

    /// 拍好的基準（`processes` 是 AI 程序底下所有子孫程序；nil 是 AI 程序已經不在）
    public mutating func setBaseline(ai: AgentKind, id: String, pid: Int32, processes: Set<AgentProcess>?) {
        guard let i = sessions.firstIndex(where: { $0.ai == ai && $0.id == id && $0.pid == pid }), sessions[i].wantsBaseline else { return }
        sessions[i].wantsBaseline = false
        // 上一回合留下、還在跑的候選不算常駐（Fable F-06）
        sessions[i].baseline = Set((processes ?? []).subtracting(sessions[i].pending).sorted().prefix(Self.maxProcesses))
    }

    /// 到時間要看背景工作的工作階段
    public func backgroundChecks(at now: Int64) -> [(ai: AgentKind, id: String, pid: Int32)] {
        sessions.filter { s in s.pid > 0 && s.checkAt.map { $0 <= now } ?? false }.map { ($0.ai, $0.id, $0.pid) }
    }

    /// 下一次要看背景工作的時間（所有工作階段中最早的）；沒有就是 nil，App 不排計時器
    public var nextBackgroundCheck: Int64? {
        sessions.compactMap { $0.pid > 0 ? $0.checkAt : nil }.min()
    }

    /// 看了 AI 程序底下的子孫程序（nil 是 AI 程序已經不在）。扣掉基準還有剩的是候選：和上一次的候選有重疊就是背景執行中，
    /// 第一次看到的 20 秒後再確認。沒有候選了就離開，睡覺倒數從這一刻重新起算。候選出現超過 30 分鐘把剩下的併進基準。回傳是否有改變
    @discardableResult
    public mutating func observe(ai: AgentKind, id: String, pid: Int32, processes: Set<AgentProcess>?, at now: Int64) -> Bool {
        guard let i = sessions.firstIndex(where: { $0.ai == ai && $0.id == id && $0.pid == pid }),
              sessions[i].checkAt != nil else { return false }
        let before = sessions[i]
        var s = sessions[i]
        let fresh = processes.map { $0.subtracting(s.baseline ?? []) } ?? []
        if processes == nil || fresh.isEmpty || s.pendingSince.map({ now - $0 >= Self.backgroundMax }) == true {
            if processes != nil, !fresh.isEmpty {
                s.baseline = Set((s.baseline ?? []).union(fresh).sorted().prefix(Self.maxProcesses))
            }
            if s.background { s.awakeSince = now }
            s.background = false
            s.pending = []
            s.pendingSince = nil
            s.checkAt = nil
        } else {
            let confirmed = !fresh.isDisjoint(with: s.pending)
            s.pendingSince = s.pendingSince ?? now
            s.pending = Set(fresh.sorted().prefix(Self.maxProcesses))
            s.background = confirmed
            s.checkAt = now + Self.backgroundEvery
        }
        sessions[i] = s
        return s != before
    }

    /// 時間經過：工作中或需要你太久沒事件變等你、太久沒事件的移除。回傳是否有改變
    @discardableResult
    public mutating func expire(at now: Int64) -> Bool {
        let before = sessions
        sessions.removeAll { now - $0.last >= Self.forgetAfter }
        for i in sessions.indices {
            let timeout: Int64? = switch sessions[i].stored {
            case .working: Self.workingTimeout
            case .needsYou: Self.needsYouTimeout
            default: nil
            }
            guard let timeout, now - sessions[i].last >= timeout else { continue }
            sessions[i].stored = .waiting
            sessions[i].need = nil
            sessions[i].since = sessions[i].last + timeout
        }
        return sessions != before
    }

    /// 彙總：最高優先的工作階段（同等級取最近有事件的；再相同依 AI、ID 排，兩邊結果一致）
    public func top(at now: Int64) -> AgentSession? {
        ordered(at: now).first
    }

    /// 依優先順序排好的工作階段（展開時的列表）
    public func ordered(at now: Int64) -> [AgentSession] {
        sessions.sorted { a, b in
            let ra = a.state(at: now, idleAfter: idleAfter).rank, rb = b.state(at: now, idleAfter: idleAfter).rank
            if ra != rb { return ra > rb }
            if a.last != b.last { return a.last > b.last }
            if a.ai != b.ai { return a.ai.rawValue < b.ai.rawValue }
            return a.id < b.id
        }
    }

    /// 某個狀態的工作階段數
    public func count(_ state: AgentState, at now: Int64) -> Int {
        sessions.filter { $0.state(at: now, idleAfter: idleAfter) == state }.count
    }

    /// 某個 AI 是否有工作階段（沒有的話退回修改時間判斷）
    public func has(_ ai: AgentKind) -> Bool {
        sessions.contains { $0.ai == ai }
    }

    /// 某個 AI 最高優先的狀態
    public func top(_ ai: AgentKind, at now: Int64) -> AgentState? {
        ordered(at: now).first { $0.ai == ai }?.state(at: now, idleAfter: idleAfter)
    }

    /// 角色的工作中與睡覺（ADR-0016 第 5 節）：有 hook 工作階段的 AI 照 hook 的狀態，其他 AI 照紀錄檔的修改時間
    /// （`fallback`：沒接 hook 的 AI 是否工作中、最近是否有動）。只有「工作中」算工作；所有 AI 都閒置才睡覺。
    /// 需要你、背景執行中算醒著；完成未看、出錯、等你進入後超過睡覺時間就可以睡（未看的標記保留，只是不撐著不睡；Fable F-06）。
    public func activity(at now: Int64, fallback: [AgentKind: (working: Bool, active: Bool)]) -> (working: Bool, idle: Bool) {
        var working = false, active = false
        for ai in AgentKind.allCases {
            let mine = sessions.filter { $0.ai == ai }
            if !mine.isEmpty {
                for session in mine {
                    working = working || session.stored == .working
                    active = active || session.stored == .working || session.stored == .needsYou || session.background
                        || now - session.idleFrom < idleAfter
                }
            } else if let probe = fallback[ai] {
                working = working || probe.working
                active = active || probe.active
            }
        }
        return (working, !working && !active)
    }
}

// MARK: - App 收事件的速率上限

/// 每秒最多處理幾個「只代表還在跑」的事件（工具前後、子代理、壓縮）；同一使用者的程式塞假事件時不會吃滿 CPU。
/// 決定狀態的事件（開始、結束、送出提示、需要你、通知、停止、出錯、中斷）稀少又關鍵，永遠不丟：
/// 子代理多時正常使用一秒也可能超過上限，丟掉 Stop 會讓狀態卡在工作中（Fable F-02）。
public struct AgentRateLimiter: Sendable {
    public static let maxPerSecond = 40
    private var second: Int64 = .min
    private var count = 0

    public init() {}

    /// 這個事件可以在超過上限時丟掉嗎
    public static func mayDrop(_ message: AgentHookMessage) -> Bool {
        switch message.event {
        case .preToolUse: message.need == nil
        case .postToolUse, .postToolUseFailure, .subagentStart, .subagentStop, .preCompact, .postCompact: true
        default: false
        }
    }

    /// 要處理就回傳 true（`now` 是毫秒）
    public mutating func admit(_ message: AgentHookMessage, at now: Int64) -> Bool {
        guard Self.mayDrop(message) else { return true }
        let current = now / 1000
        if current != second { (second, count) = (current, 0) }
        count += 1
        return count <= Self.maxPerSecond
    }
}

// MARK: - 系統通知（第 2 部分）

/// 該發的系統通知。只有 AI、種類與工作階段，不含資料夾名稱：通知中心會把通知內容存到磁碟（隱私底線）
public struct AgentNotice: Sendable, Equatable {
    public enum Kind: String, Sendable { case needsYou, done }
    public var ai: AgentKind
    public var kind: Kind
    public var need: AgentNeed?
    /// 同一次狀態只發一次：工作階段、種類與進入狀態的時間
    public var key: String
}

public struct AgentNoticePolicy: Sendable, Equatable {
    /// 需要你多久還沒處理才發通知（設定，預設 20 秒）
    public var needsYouAfter: Int64
    /// 跑超過多久的任務完成時發通知（設定，預設 3 分鐘）
    public var longTask: Int64

    public init(needsYouAfter: Int64 = 20_000, longTask: Int64 = 180_000) {
        self.needsYouAfter = needsYouAfter
        self.longTask = longTask
    }
}

extension AgentSessions {
    /// 現在該發的通知（呼叫端用 `key` 去掉已經發過的）：需要你超過設定的秒數；跑超過設定分鐘數的回合完成
    public func notices(at now: Int64, policy: AgentNoticePolicy) -> [AgentNotice] {
        ordered(at: now).compactMap { s in
            let key = Self.noticeKey(s)
            switch s.stored {
            case .needsYou where now - s.since >= policy.needsYouAfter:
                return AgentNotice(ai: s.ai, kind: .needsYou, need: s.need, key: key)
            case .done where s.turnStart.map { s.since - $0 >= policy.longTask } ?? false:
                return AgentNotice(ai: s.ai, kind: .done, need: nil, key: key)
            default:
                return nil
            }
        }
    }

    /// 每個工作階段目前的狀態（工作階段＋狀態＋進入時間）：通知去重用，狀態結束或工作階段消失時鍵就不在了
    public func noticeKeys(at now: Int64) -> Set<String> {
        Set(ordered(at: now).map(Self.noticeKey))
    }

    static func noticeKey(_ s: AgentSession) -> String {
        "\(s.ai.rawValue)/\(s.id)/\(s.stored.rawValue)@\(s.since)"
    }

    /// 下一次要檢查通知的時間（還沒到時間的需要你）；沒有就是 nil。門檻是 `Int64.max`（關閉）時不會溢位
    public func nextNoticeCheck(after now: Int64, policy: AgentNoticePolicy) -> Int64? {
        sessions.filter { $0.stored == .needsYou && now - $0.since < policy.needsYouAfter }
            .compactMap { s in
                let (at, overflow) = s.since.addingReportingOverflow(policy.needsYouAfter)
                return overflow ? nil : at
            }
            .min()
    }
}

/// 通知去重（Codex C-04）：同一個工作階段的同一次狀態只通知一次。記錄只在那個狀態結束、或工作階段消失時才清掉，
/// 所以通知後把門檻調高、或關掉再打開，都不會讓同一次「需要你」再通知一次
public struct AgentNoticeLog: Sendable {
    private var sent: Set<String> = []

    public init() {}

    /// 這次該送的（還沒送過的）；呼叫後都記成送過（靜音時也一樣，結束後不補發）
    public mutating func take(_ sessions: AgentSessions, at now: Int64, policy: AgentNoticePolicy) -> [AgentNotice] {
        let fresh = sessions.notices(at: now, policy: policy).filter { !sent.contains($0.key) }
        sent = sent.intersection(sessions.noticeKeys(at: now)).union(fresh.map(\.key))
        return fresh
    }
}
