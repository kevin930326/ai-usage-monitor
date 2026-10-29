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

    /// 這台電腦的彙總，鍵的順序固定（Swift、C# 輸出相同）。沒有工作階段的 AI 不列；`since` 是最高狀態的工作階段中最早進入的
    public static func encoded(_ sessions: AgentSessions, at now: Int64) -> Data {
        let ordered = sessions.ordered(at: now)
        let rows = AgentKind.allCases.compactMap { ai -> String? in
            let mine = ordered.filter { $0.ai == ai }
            guard let top = mine.first else { return nil }
            let state = top.state(at: now, idleAfter: sessions.idleAfter)
            // 同一個狀態有幾個工作階段時取最早進入的：哪一個最近有事件不影響彙總，不會每個工具事件就改一次（Fable F-01）
            let since = mine.filter { $0.state(at: now, idleAfter: sessions.idleAfter) == state }.map(\.since).min() ?? top.since
            // 背景執行中寫成工作中（ADR-0017 第 7 節）：中繼與舊版 App 不用改格式
            let shared = state == .background ? AgentState.working : state
            return "{\"ai\":\"\(ai.rawValue)\",\"state\":\"\(shared.rawValue)\",\"sessions\":\(mine.count),\"since\":\(since)}"
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
    /// 列表用：檔案裡第幾台＋AI（裝置名稱可能重複，不能當識別）
    public var id: String
    /// 本機時間（ms）到了就不顯示：中繼收到後滿 30 分鐘（畫面停著不重新下載時也會消失）
    public var expiresAt: Int64

    public init(device: String, ai: AgentKind, state: AgentState, sessions: Int, id: String? = nil, expiresAt: Int64 = .max) {
        self.device = device
        self.ai = ai
        self.state = state
        self.sessions = sessions
        self.id = id ?? "\(device)/\(ai.rawValue)"
        self.expiresAt = expiresAt
    }

    public func isShown(at localNow: Int64) -> Bool { localNow < expiresAt }

    /// 「桌機：Claude Code 需要你」
    public var text: String {
        let name = ai == .claude ? "Claude Code" : "Codex"
        let what = switch state {
        case .needsYou: "需要你"
        case .error: "出錯了"
        case .working: "工作中"
        case .background: "背景執行中"
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
    /// 「完成了」「出錯」進入那個狀態超過這麼久，當成「等你」不顯示（ADR-0017 第 9 節）：那台電腦每 10 分鐘重傳一次，
    /// 中繼收到的時間一直是新的，在那台的終端機或 Claude App 裡看過也不會清掉
    public static let fadeAfter: Int64 = 30 * 60_000
    /// 會淡出的狀態（需要你、工作中不淡出）
    static let fades: Set<AgentState> = [.done, .error]
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
        for (index, item) in devices.prefix(maxDevices).enumerated() {
            guard let device = item as? [String: Any] else { continue }
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
                guard shown.contains(state) else { continue }
                var expires = fetched + maxAge - (now - updated) + 1
                // 完成、出錯：從進入的時間（中繼夾在 updated_at 之前 24 小時內）算 30 分鐘，用中繼的時鐘＋下載後經過的時間
                if fades.contains(state), let since = int(row["since"]) {
                    guard now - since + elapsed < fadeAfter else { continue }
                    expires = min(expires, fetched + fadeAfter - (now - since))
                }
                list.append(RemoteAgent(device: clean, ai: ai, state: state, sessions: Int(sessions), id: "\(index)/\(ai.rawValue)",
                                        expiresAt: expires))
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
