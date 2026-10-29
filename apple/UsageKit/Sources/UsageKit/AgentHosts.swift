import Foundation

/// 切回 AI 的程式就算看過（ADR-0017 第 8 節）：`shared/agent-hosts.json` 列出宿主程式（Mac 的 bundle ID、Windows 的執行檔名稱）
/// 與它代表的 AI。只比對程式識別，不讀視窗標題或內容；判斷規則在 `AgentSessions.markSeenByHost`。C# 是 UsageCore/AgentHosts.cs
public struct AgentHosts: Sendable, Equatable {
    /// 完成時宿主程式已經在前景：停留多久也算看過
    public static let dwellMs: Int64 = 3_000

    /// 識別（小寫）→ 代表的 AI
    public let mac: [String: Set<AgentKind>]
    public let windows: [String: Set<AgentKind>]

    struct File: Decodable {
        var hosts: [Host]
    }

    struct Host: Decodable {
        var ais: [String]
        var mac: [String]?
        var windows: [String]?
    }

    public init(mac: [String: Set<AgentKind>] = [:], windows: [String: Set<AgentKind>] = [:]) {
        self.mac = mac
        self.windows = windows
    }

    /// 讀 `agent-hosts.json`；格式不對時沒有宿主（功能關閉，其他照常）
    public static func decode(_ data: Data) -> AgentHosts {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return AgentHosts() }
        var mac: [String: Set<AgentKind>] = [:], windows: [String: Set<AgentKind>] = [:]
        for host in file.hosts {
            let ais = Set(host.ais.compactMap(AgentKind.init(rawValue:)))
            guard !ais.isEmpty else { continue }
            for id in host.mac ?? [] { mac[id.lowercased(), default: []].formUnion(ais) }
            for id in host.windows ?? [] { windows[id.lowercased(), default: []].formUnion(ais) }
        }
        return AgentHosts(mac: mac, windows: windows)
    }

    /// Mac 前景 App 的 bundle ID 代表哪些 AI（不是宿主就是空的）
    public func ais(bundleID: String?) -> Set<AgentKind> {
        bundleID.flatMap { mac[$0.lowercased()] } ?? []
    }
}
