import Foundation

/// 把我們的 hook 合併進 Claude Code 的 `settings.json` 或 Codex 的 `hooks.json`（ADR-0017 第 3 節）。
/// 兩者的形狀相同：`{"hooks": {"<事件>": [{"matcher": "...", "hooks": [{"type": "command", "command": "..."}]}]}}`。
///
/// - 只動我們的項目（指令含 `Contents/Helpers/aum-hook`）；別人的 matcher 群組與 hook 一律保留，同一事件可以共存。
/// - 重複安裝不會多一份：先拿掉我們舊的（含路徑已經不同的），再加上新的。
/// - 移除只刪我們的；某事件因此變空就刪掉該事件，`hooks` 因此變空就刪掉 `hooks`。
/// - 檔案不是 JSON 物件、或 `hooks` 不是物件時不改（丟出錯誤，由畫面提示）。
public enum AgentHookConfig {
    /// 認出我們的 hook 的字串（App 包裡的位置）
    public static let marker = "Contents/Helpers/aum-hook"
    /// hook 的逾時（秒）：程式本身幾毫秒就結束；Codex 的 SessionEnd、Interrupt 最多允許 3 秒
    public static let timeoutSeconds = 3

    public enum ConfigError: Error, Equatable {
        /// 不是合法的 JSON
        case invalidJSON
        /// 最上層不是物件，或 `hooks` 不是物件、事件不是陣列
        case unexpectedShape(String)
    }

    public enum Status: Equatable, Sendable {
        /// 沒有我們的 hook
        case notInstalled
        /// 每個事件都有、指向目前的 App
        case installed
        /// 有我們的 hook，但缺事件或指向別的路徑（App 被移動）：可以一鍵修好
        case needsRepair(missing: [AgentHookEvent], wrongPath: Bool)
    }

    /// hook 的指令：App 包裡的程式路徑（單引號包起來，經 shell 執行也安全）加上 AI 名稱
    public static func command(executable: String, ai: AgentKind) -> String {
        "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' " + ai.rawValue
    }

    public static func isOurs(_ command: String) -> Bool {
        command.contains(marker)
    }

    /// 安裝或修好：回傳新的檔案內容（原本沒有檔案時傳 nil）
    public static func install(into data: Data?, ai: AgentKind, command: String,
                               events: [AgentHookEvent]? = nil) throws -> Data {
        var root = try parseRoot(data)
        var hooks = try hooksObject(of: root)
        hooks = try removeOurs(from: hooks)
        for event in events ?? AgentHookEvent.installed(for: ai) {
            let entry = OrderedJSON.object([
                .init("hooks", .array([.object([
                    .init("type", .text("command")),
                    .init("command", .text(command)),
                    .init("timeout", .number(String(timeoutSeconds))),
                ])])),
            ])
            if let index = hooks.firstIndex(where: { $0.key == event.rawValue }) {
                guard case .array(var groups) = hooks[index].value else {
                    throw ConfigError.unexpectedShape("hooks.\(event.rawValue)")
                }
                groups.append(entry)
                hooks[index].value = .array(groups)
            } else {
                hooks.append(.init(event.rawValue, .array([entry])))
            }
        }
        root = setHooks(hooks, in: root)
        return OrderedJSON.object(root).serialized()
    }

    /// 移除：回傳新的檔案內容；沒有我們的 hook 時回傳 nil（不必寫檔）
    public static func uninstall(from data: Data?) throws -> Data? {
        guard data != nil else { return nil }
        let root = try parseRoot(data)
        let hooks = try hooksObject(of: root)
        let removed = try removeOurs(from: hooks)
        guard removed != hooks else { return nil }
        return OrderedJSON.object(setHooks(removed, in: root)).serialized()
    }

    /// 目前的狀態（`command` 是目前 App 的指令）
    public static func status(of data: Data?, ai: AgentKind, command: String,
                              events: [AgentHookEvent]? = nil) throws -> Status {
        guard data != nil else { return .notInstalled }
        let hooks = try hooksObject(of: try parseRoot(data))
        var found: Set<String> = []
        var wrongPath = false
        for member in hooks {
            for existing in commands(in: member.value) where isOurs(existing) {
                found.insert(member.key)
                // 指令與目前 App 的不同：App 被移動，或是舊版本的指令
                if existing != command { wrongPath = true }
            }
        }
        guard !found.isEmpty else { return .notInstalled }
        let missing = (events ?? AgentHookEvent.installed(for: ai)).filter { !found.contains($0.rawValue) }
        return missing.isEmpty && !wrongPath ? .installed : .needsRepair(missing: missing, wrongPath: wrongPath)
    }

    // MARK: - 內部

    private static func parseRoot(_ data: Data?) throws -> [OrderedJSON.Member] {
        guard let data, !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return [] }
        let value: OrderedJSON
        do { value = try OrderedJSON.parse(data) } catch { throw ConfigError.invalidJSON }
        guard let members = value.members else { throw ConfigError.unexpectedShape("最上層") }
        return members
    }

    private static func hooksObject(of root: [OrderedJSON.Member]) throws -> [OrderedJSON.Member] {
        guard let value = root.last(where: { $0.key == "hooks" })?.value else { return [] }
        guard let members = value.members else { throw ConfigError.unexpectedShape("hooks") }
        return members
    }

    private static func setHooks(_ hooks: [OrderedJSON.Member], in root: [OrderedJSON.Member]) -> [OrderedJSON.Member] {
        var root = root
        let index = root.lastIndex { $0.key == "hooks" }
        switch (index, hooks.isEmpty) {
        case (let index?, true): root.remove(at: index)
        case (let index?, false): root[index].value = .object(hooks)
        case (nil, false): root.append(.init("hooks", .object(hooks)))
        case (nil, true): break
        }
        return root
    }

    /// 某事件底下所有 hook 的指令
    private static func commands(in groups: OrderedJSON) -> [String] {
        (groups.elements ?? []).flatMap { group in
            (group["hooks"]?.elements ?? []).compactMap { $0["command"]?.stringValue }
        }
    }

    /// 拿掉每個事件裡我們的 hook；群組因此變空就拿掉群組，事件因此變空就拿掉事件（別人的原樣保留）
    private static func removeOurs(from hooks: [OrderedJSON.Member]) throws -> [OrderedJSON.Member] {
        var result: [OrderedJSON.Member] = []
        for member in hooks {
            guard case .array(let groups) = member.value else {
                result.append(member)   // 不是陣列：不是我們能懂的格式，原樣保留
                continue
            }
            var kept: [OrderedJSON] = []
            var touched = false
            for group in groups {
                guard case .object(var fields) = group,
                      let index = fields.lastIndex(where: { $0.key == "hooks" }),
                      case .array(let handlers) = fields[index].value else {
                    kept.append(group)
                    continue
                }
                let others = handlers.filter { !isOurs($0["command"]?.stringValue ?? "") }
                if others.count == handlers.count {
                    kept.append(group)
                } else {
                    touched = true
                    if !others.isEmpty {
                        fields[index].value = .array(others)
                        kept.append(.object(fields))
                    }
                }
            }
            if touched && kept.isEmpty { continue }
            result.append(.init(member.key, .array(kept)))
        }
        return result
    }
}
