import Foundation

/// 跨裝置的 AI 狀態（ADR-0019 第 2 節）。App 只讀寫本機檔案；連中繼的是收集器的 `agent-sync`。
///
/// - `agent-state.json`：這台電腦的彙總（App 寫、收集器讀後上傳）。每個 AI 一列：最高的狀態、工作階段數、進入這個狀態的時間；
///   不含資料夾名稱、工作階段 ID 或任何內容。
/// - `agent-remote.json`：其他電腦的彙總（收集器下載後寫、App 讀）。收集器已經拿掉自己這台與裝置 ID。
///
/// 規則和 C#（UsageCore/AgentSync.cs）、Python（usage_collector/agent_sync.py）相同，`fixtures/agent` 的 golden 三邊比對。
public enum AgentSummary {
    public static let version = 1
    public static let fileName = "agent-state.json"

    /// 這台電腦的彙總，鍵的順序固定（Swift、C# 輸出相同）。沒有工作階段的 AI 不列
    public static func encoded(_ sessions: AgentSessions, at now: Int64) -> Data {
        let ordered = sessions.ordered(at: now)
        let rows = AgentKind.allCases.compactMap { ai -> String? in
            let mine = ordered.filter { $0.ai == ai }
            guard let top = mine.first else { return nil }
            let state = top.state(at: now, idleAfter: sessions.idleAfter)
            return "{\"ai\":\"\(ai.rawValue)\",\"state\":\"\(state.rawValue)\",\"sessions\":\(mine.count),\"since\":\(top.since)}"
        }
        return Data("{\"v\":\(version),\"ais\":[\(rows.joined(separator: ","))]}".utf8)
    }

    /// App 結束時寫的「全部閒置」
    public static let empty = Data("{\"v\":\(version),\"ais\":[]}".utf8)
}

/// 其他電腦的一個 AI 要顯示的狀態
public struct RemoteAgent: Sendable, Equatable {
    public var device: String
    public var ai: AgentKind
    public var state: AgentState
    public var sessions: Int

    public init(device: String, ai: AgentKind, state: AgentState, sessions: Int) {
        self.device = device
        self.ai = ai
        self.state = state
        self.sessions = sessions
    }

    /// 列表用（同一台同一個 AI 只有一列）
    public var id: String { "\(device)/\(ai.rawValue)" }

    /// 「桌機：Claude Code 需要你」
    public var text: String {
        let name = ai == .claude ? "Claude Code" : "Codex"
        let what = switch state {
        case .needsYou: "需要你"
        case .error: "出錯了"
        case .working: "工作中"
        case .done: "完成了"
        case .waiting: "等你"
        case .idle: "閒置"
        }
        return "\(device)：\(name) \(what)"
    }
}

public enum RemoteAgents {
    public static let fileName = "agent-remote.json"
    /// 中繼收到的時間超過這麼久就不顯示（那台電腦關機或斷線）
    public static let maxAge: Int64 = 30 * 60_000
    /// 顯示的狀態：等你與閒置不顯示
    static let shown: Set<AgentState> = [.needsYou, .error, .working, .done]
    static let maxDevices = 16
    static let maxName = 32

    /// 讀 `agent-remote.json`：`{"v":1,"fetched_at":<本機 ms>,"now":<中繼 ms>,"devices":[{"name","ais":[…],"updated_at":<中繼 ms>}]}`。
    /// 多久以前＝中繼那邊的差（now − updated_at，同一個時鐘）＋下載後在本機經過的時間。格式不對整個不顯示；個別欄位不對略過那一列。
    /// 依狀態（需要你最前）、裝置名稱、AI 排序
    public static func parse(_ data: Data, localNow: Int64) -> [RemoteAgent] {
        guard data.count <= 64 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              int(root["v"]) == 1,
              let fetched = int(root["fetched_at"]), let now = int(root["now"]),
              let devices = root["devices"] as? [Any] else { return [] }
        let elapsed = max(0, localNow - fetched)
        var list: [RemoteAgent] = []
        for case let device as [String: Any] in devices.prefix(maxDevices) {
            guard let name = device["name"] as? String, let updated = int(device["updated_at"]),
                  let ais = device["ais"] as? [Any] else { continue }
            let clean = cleanName(name)
            guard !clean.isEmpty, now - updated + elapsed <= maxAge, now - updated >= -60_000 else { continue }
            var seen: Set<AgentKind> = []
            for case let row as [String: Any] in ais.prefix(2) {
                guard let ai = (row["ai"] as? String).flatMap(AgentKind.init(rawValue:)), !seen.contains(ai),
                      let state = (row["state"] as? String).flatMap(AgentState.init(rawValue:)),
                      let sessions = int(row["sessions"]), (0...32).contains(sessions) else { continue }
                seen.insert(ai)
                if shown.contains(state) { list.append(RemoteAgent(device: clean, ai: ai, state: state, sessions: Int(sessions))) }
            }
        }
        return list.sorted { a, b in
            if a.state.rank != b.state.rank { return a.state.rank > b.state.rank }
            if a.device != b.device { return a.device < b.device }
            return a.ai.rawValue < b.ai.rawValue
        }
    }

    /// iPhone 直接讀中繼的 `GET /agents/state`（`{"now","devices":[{"device_id","name","ais","updated_at"}]}`）：
    /// 剛下載完，經過的時間是 0；其他規則同 `parse`。iPhone 不是裝置，所有電腦都列出
    public static func parseRelay(_ data: Data, localNow: Int64) -> [RemoteAgent] {
        guard data.count <= 64 * 1024,
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        root["v"] = 1
        root["fetched_at"] = NSNumber(value: localNow)
        guard let wrapped = try? JSONSerialization.data(withJSONObject: root) else { return [] }
        return parse(wrapped, localNow: localNow)
    }

    /// 控制字元與格式字元拿掉、前後空白去掉、最多 32 個 Unicode 純量（同 C# 的 Rune、Python 的字元）
    static func cleanName(_ name: String) -> String {
        let kept = name.unicodeScalars.filter { !($0.properties.generalCategory == .control || $0.properties.generalCategory == .format) }
        let trimmed = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maxName)))
    }

    /// JSON 的整數（不收小數、布林）。布林的 objCType 是 "c"（Linux 的 Foundation 沒有 CFBooleanGetTypeID）；
    /// JSON 的數字不會是 char
    static func int(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) < 9e15 else { return nil }
        return number.int64Value
    }
}
