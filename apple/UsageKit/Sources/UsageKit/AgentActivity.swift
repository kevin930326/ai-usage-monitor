import Foundation

/// 角色合併所有電腦的狀態（ADR-0019「角色合併所有電腦」）：本機的工作階段＋其他電腦（`agent-remote.json`）中最重要的狀態，
/// 換成狀態機要的旗標。Mac、Windows 同一套規則（C# 的 `AgentActivity`），由 `fixtures/agent` 的 `activity` golden 檢查。
/// 清單、通知與系統匣不用這裡：清單照原本先列本機再列其他電腦，通知只對本機發
public struct AgentActivity: Equatable, Sendable {
    /// 本機在工作（敲鍵盤＋思考泡泡）
    public var working: Bool
    /// 本機背景執行中（呼吸＋慢速泡泡）
    public var background: Bool
    /// 任何一台需要你（舉手、外框琥珀色）
    public var needsYou: Bool
    /// 只有其他電腦在工作時的旗標來源：任何一台其他電腦在工作（含那台的背景執行中）
    public var remoteWorking: Bool
    /// 其他電腦出錯（沒被這台看過壓下）：表情難過
    public var remoteError: Bool
    /// 所有電腦都閒置：才睡
    public var idle: Bool

    public init(working: Bool, background: Bool, needsYou: Bool, remoteWorking: Bool, remoteError: Bool, idle: Bool) {
        self.working = working
        self.background = background
        self.needsYou = needsYou
        self.remoteWorking = remoteWorking
        self.remoteError = remoteError
        self.idle = idle
    }

    /// 其他電腦的工作中、需要你對角色的效力：中繼收到後 20 分鐘（本機的收集器停了、`agent-remote.json` 不再更新時不一直想，Fable G-07）
    public static let remoteEffect: Int64 = 20 * 60_000

    /// 遠端出錯在這台看過的記號（裝置名稱、AI、進入出錯的時間）：`since` 改了才再顯示（Fable G-06）。只在記憶體，不寫檔、不上傳
    public static func errorKey(_ agent: RemoteAgent) -> String {
        "\(agent.device)|\(agent.ai.rawValue)|\(agent.since.map(String.init) ?? "-")"
    }

    /// `remote` 是 `RemoteAgents.parse(_, all: true)` 的結果（含等你、閒置）；`idleAfter` 是本機的睡覺分鐘數（ms）。
    /// 遠端的需要你、出錯、工作中一律醒著（工作中、需要你在中繼收到後 20 分鐘內）；完成、等你從 `since` 起未超過睡覺分鐘數算醒著；閒置不算
    public static func combine(localWorking: Bool, localIdle: Bool, localNeedsYou: Bool, localBackground: Bool,
                               remote: [RemoteAgent], now: Int64, idleAfter: Int64, seenErrors: Set<String> = []) -> AgentActivity {
        var needsYou = localNeedsYou
        var remoteWorking = false
        var remoteError = false
        var remoteAwake = false
        for agent in remote where shown(agent, at: now) {
            let fresh = now - agent.updated <= remoteEffect
            switch agent.state {
            case .needsYou:
                if fresh { needsYou = true; remoteAwake = true }
            case .working, .background:
                if fresh { remoteWorking = true; remoteAwake = true }
            case .error:
                if !seenErrors.contains(errorKey(agent)) { remoteError = true }
                remoteAwake = true
            case .done, .waiting:
                if let since = agent.since, now - since < idleAfter { remoteAwake = true }
            case .idle:
                break
            }
        }
        return AgentActivity(working: localWorking, background: localBackground, needsYou: needsYou, remoteWorking: remoteWorking,
                             remoteError: remoteError, idle: localIdle && !remoteAwake)
    }

    /// 只有其他電腦在工作（同狀態機的 `thinksRemotely`）：動畫「簡單」「關閉」時狀態機不換姿勢，小電腦照這個靜態顯示（Fable G-11）
    public var thinksRemotely: Bool { remoteWorking && !working && !background && !needsYou }

    /// 表情用的狀態：需要你 > 出錯（本機或遠端）> 本機最重要的狀態。遠端的完成不讓角色開心（不是這台完成的）
    public func moodState(localTop: AgentState?) -> AgentState? {
        if needsYou { return .needsYou }
        if localTop == .error || remoteError { return .error }
        return localTop
    }

    /// 中繼收到後 30 分鐘內；完成、出錯從進入的時間起 30 分鐘內（同 `RemoteAgents.parse`，畫面停著不重讀時也照時間過期）
    static func shown(_ agent: RemoteAgent, at now: Int64) -> Bool {
        guard now - agent.updated <= RemoteAgents.maxAge else { return false }
        if RemoteAgents.fades.contains(agent.state), let since = agent.since, now - since >= RemoteAgents.fadeAfter { return false }
        return true
    }
}
