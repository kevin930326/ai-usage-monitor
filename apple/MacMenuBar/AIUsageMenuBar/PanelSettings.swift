import Foundation
import Observation
import UsageKit

/// 選單列圖示的樣式（FR-33）。
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case dualRing
    case bar
    case percent
    case ringPercent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dualRing: "雙圓環"
        case .bar: "橫條"
        case .percent: "只有 %"
        case .ringPercent: "圓環＋%"
        }
    }
}

/// 面板的區塊（FR-34、FR-35）。之後的區塊（走勢、統計…）在這裡加一個 case 與預設順序即可，
/// 舊的設定會依 `PanelLayout.resolve` 自動插入新區塊，不需要改設定格式。
enum PanelSection: String, CaseIterable, Identifiable {
    case ring
    case quota

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ring: "最吃緊的額度"
        case .quota: "額度"
        }
    }

    var detail: String {
        switch self {
        case .ring: "雙圓環、剩餘 %、重置倒數與用量節奏"
        case .quota: "各服務的 5 小時與每週額度"
        }
    }

    static let defaultOrder = allCases.map(\.rawValue)
    static let knownIDs = Set(defaultOrder)
}

/// 使用者設定，存在 App 的 UserDefaults（ADR-0008 第 3、5 節）。不同步到 iPhone 或手錶。
@Observable
@MainActor
final class PanelSettings {
    static let shared = PanelSettings()

    private enum Key {
        static let iconStyle = "menuBar.iconStyle"
        static let iconWindow = "menuBar.window"
        static let sections = "panel.sections"
        static let collapsed = "panel.collapsed"
        static let expectedMarker = "panel.expectedMarker"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var iconStyle: MenuBarIconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: Key.iconStyle) }
    }

    var iconWindow: MenuBarWindowChoice {
        didSet { defaults.set(iconWindow.rawValue, forKey: Key.iconWindow) }
    }

    var layout: PanelLayout {
        didSet { defaults.set(layout.encoded(), forKey: Key.sections) }
    }

    var collapsed: Set<String> {
        didSet { defaults.set(Array(collapsed).sorted(), forKey: Key.collapsed) }
    }

    /// 額度卡片的預期進度標記
    var showsExpectedMarker: Bool {
        didSet { defaults.set(showsExpectedMarker, forKey: Key.expectedMarker) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        iconStyle = defaults.string(forKey: Key.iconStyle).flatMap(MenuBarIconStyle.init) ?? .dualRing
        iconWindow = MenuBarWindowChoice(rawValue: defaults.string(forKey: Key.iconWindow) ?? "auto")
        layout = PanelLayout.resolve(stored: defaults.data(forKey: Key.sections), defaultOrder: PanelSection.defaultOrder)
        collapsed = Set(defaults.stringArray(forKey: Key.collapsed) ?? [])
        showsExpectedMarker = defaults.object(forKey: Key.expectedMarker) as? Bool ?? true
    }

    var visibleSections: [PanelSection] {
        layout.visibleIDs(known: PanelSection.knownIDs).compactMap(PanelSection.init)
    }

    /// 設定畫面列出的區塊（認得的、依目前順序，含關閉的）。
    var configurableSections: [(section: PanelSection, enabled: Bool)] {
        layout.entries.compactMap { entry in PanelSection(rawValue: entry.id).map { ($0, entry.enabled) } }
    }

    func moveSections(fromOffsets source: IndexSet, toOffset destination: Int) {
        layout.move(knownIDs: PanelSection.knownIDs, fromOffsets: source, toOffset: destination)
    }

    func setEnabled(_ enabled: Bool, for section: PanelSection) {
        layout.setEnabled(enabled, for: section.rawValue)
    }

    func resetPanel() {
        layout = PanelLayout(defaultOrder: PanelSection.defaultOrder)
        collapsed = []
        showsExpectedMarker = true
    }
}
