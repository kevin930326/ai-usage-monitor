import Foundation

/// Mac 面板區塊的順序與開關（FR-35、ADR-0008 第 3 節）。存在 UserDefaults，格式為 JSON 陣列。
/// 區塊以穩定的字串 id 識別：新版本加入的區塊依預設順序插入、預設開啟；
/// 程式不認得的 id（降版、之後的區塊）保留在設定裡但不顯示，避免遺失設定。
public struct PanelLayout: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var enabled: Bool

        public init(id: String, enabled: Bool) {
            self.id = id
            self.enabled = enabled
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// 依預設順序全部開啟。
    public init(defaultOrder: [String]) {
        entries = defaultOrder.map { Entry(id: $0, enabled: true) }
    }

    /// 讀取儲存的設定並補上缺少的區塊：插在預設順序中前一個已存在區塊的後面（沒有就放最前面）。
    /// 重複的 id 只保留第一個。資料損毀時退回預設。
    public static func resolve(stored: Data?, defaultOrder: [String]) -> PanelLayout {
        var entries: [Entry] = []
        if let stored, let decoded = try? JSONDecoder().decode(PanelLayout.self, from: stored) {
            var seen = Set<String>()
            entries = decoded.entries.filter { seen.insert($0.id).inserted }
        }
        for (index, id) in defaultOrder.enumerated() where !entries.contains(where: { $0.id == id }) {
            let previous = defaultOrder[..<index].reversed().first { prev in entries.contains { $0.id == prev } }
            let insertAt = previous.flatMap { prev in entries.firstIndex { $0.id == prev }.map { $0 + 1 } } ?? 0
            entries.insert(Entry(id: id, enabled: true), at: insertAt)
        }
        return PanelLayout(entries: entries)
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// 要顯示的區塊（開啟且程式認得），依設定的順序。
    public func visibleIDs(known: Set<String>) -> [String] {
        entries.filter { $0.enabled && known.contains($0.id) }.map(\.id)
    }

    /// 只在認得的區塊之間移動（設定畫面只列出認得的區塊），不認得的保持原位。
    public mutating func move(knownIDs known: Set<String>, fromOffsets source: IndexSet, toOffset destination: Int) {
        let slots = entries.indices.filter { known.contains(entries[$0].id) }
        var visible = slots.map { entries[$0] }
        let moving = source.sorted().map { visible[$0] }
        let before = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { visible.remove(at: index) }
        visible.insert(contentsOf: moving, at: min(max(before, 0), visible.count))
        for (slot, entry) in zip(slots, visible) { entries[slot] = entry }
    }

    public mutating func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].enabled = enabled
    }
}
