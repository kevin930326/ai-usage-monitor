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
/// `{"v":1,"ai":"claude","ev":"Stop","need":"","sub":false,"sid":"0123456789abcdef","t":1761650000000,"dir":"my-project"}`
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

    public static let version = 1
    /// 一行最多多少位元組（App 讀超過就丟掉）
    public static let maxLength = 1024

    public init(ai: AgentKind, event: AgentHookEvent, need: AgentNeed?, session: String, time: Int64, folder: String,
                sub: Bool = false) {
        self.ai = ai
        self.event = event
        self.need = need
        self.session = session
        self.time = time
        self.folder = folder
        self.sub = sub
    }

    /// 送出的一行（不含換行）；鍵的順序固定，Swift 與 C# 輸出相同
    public func encoded() -> Data {
        let fields: [(String, Any)] = [("v", Self.version), ("ai", ai.rawValue), ("ev", event.rawValue),
                                       ("need", need?.rawValue ?? ""), ("sub", sub), ("sid", session), ("t", time),
                                       ("dir", folder)]
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
              Set(object.keys) == ["v", "ai", "ev", "need", "sub", "sid", "t", "dir"],
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
        let message = AgentHookMessage(ai: ai, event: event, need: need, session: session, time: time, folder: folder, sub: sub)
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

/// 工作階段的狀態；彙總時依 `rank` 取最高的（需要你 > 出錯 > 工作中 > 完成未看 > 等你 > 閒置）
public enum AgentState: String, Sendable, Codable, CaseIterable {
    case needsYou, error, working, done, waiting, idle

    public var rank: Int {
        switch self {
        case .needsYou: 5
        case .error: 4
        case .working: 3
        case .done: 2
        case .waiting: 1
        case .idle: 0
        }
    }
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

    public func state(at now: Int64, idleAfter: Int64) -> AgentState {
        stored == .waiting && now - since >= idleAfter ? .idle : stored
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
        session.last = now
        let next = Self.transition(from: session.stored, event: message.event, need: message.need, sub: message.sub)
        if let next, next.state != session.stored || next.need != session.need {
            session.stored = next.state
            session.need = next.need
            session.since = now
        }
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
    /// 需要你算醒著；完成未看、出錯、等你進入後超過睡覺時間就可以睡（未看的標記保留，只是不撐著不睡；Fable F-06）。
    public func activity(at now: Int64, fallback: [AgentKind: (working: Bool, active: Bool)]) -> (working: Bool, idle: Bool) {
        var working = false, active = false
        for ai in AgentKind.allCases {
            let mine = sessions.filter { $0.ai == ai }
            if !mine.isEmpty {
                for session in mine {
                    working = working || session.stored == .working
                    active = active || session.stored == .working || session.stored == .needsYou
                        || now - session.since < idleAfter
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
