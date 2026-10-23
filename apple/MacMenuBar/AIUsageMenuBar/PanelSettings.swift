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
/// 順序同 ADR-0008 第 2 節的表；之後的統計、服務狀態接在後面。
enum PanelSection: String, CaseIterable, Identifiable {
    case ring
    case suggest
    case quota
    case resets
    case trend
    case consumption
    case stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ring: "主圓環"
        case .suggest: "建議接下來用"
        case .quota: "額度"
        case .resets: "接下來的重置"
        case .trend: "本週額度走勢"
        case .consumption: "額度消耗"
        case .stats: "統計"
        }
    }

    var detail: String {
        switch self {
        case .ring: "剩餘最少的額度：雙圓環、剩餘 %、重置倒數與用量節奏"
        case .suggest: "某服務快用完、另一個服務還充足時提示；都充足時不顯示"
        case .quota: "各服務的 5 小時與每週額度"
        case .resets: "未來 8 小時的重置時間軸，與照目前速度每週額度可撐到星期幾"
        case .trend: "目前這一輪的剩餘 % 曲線與照時間的預期，沒有紀錄的時段畫斜線"
        case .consumption: "每小時消耗的額度 %（熱力圖與每日合計），包含所有裝置"
        case .stats: "這台 Mac 的 Token：本週、單日最高、最長任務、連續天數、Token 活動與活動熱力圖"
        }
    }

    /// 需要額度歷史（history.sqlite3）的區塊
    var needsHistory: Bool { self == .trend || self == .consumption || self == .stats }

    static let defaultOrder = allCases.map(\.rawValue)
    static let knownIDs = Set(defaultOrder)
}

/// 使用者設定，存在 App 的 UserDefaults（ADR-0008 第 3、5 節）。不同步到 iPhone 或手錶。
@Observable
@MainActor
final class PanelSettings {
    static let shared = PanelSettings(defaults: storage)

    /// Debug 版的面板預覽、截圖與效能量測用獨立、每次清空的設定，不動到正式設定，
    /// 結果也不受使用者隱藏或收合的卡片影響。
    private static var storage: UserDefaults {
        #if DEBUG
        if ProcessInfo.processInfo.environment["AUM_DEMO_PANEL"] == "1" {
            let suite = "io.github.kevin930326.ai-usage-monitor.demo-panel"
            let demo = UserDefaults(suiteName: suite) ?? .standard
            demo.removePersistentDomain(forName: suite)
            return demo
        }
        #endif
        return .standard
    }

    private enum Key {
        static let iconStyle = "menuBar.iconStyle"
        static let iconWindow = "menuBar.window"
        static let sections = "panel.sections"
        static let collapsed = "panel.collapsed"
        static let expectedMarker = "panel.expectedMarker"
        static let trendWindow = "panel.trendWindow"
        static let consumptionWindow = "panel.consumptionWindow"
        static let statsScope = "panel.statsScope"
        static let statsRange = "panel.statsRange"
        static let celebratedStreak = "panel.celebratedStreak"
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

    /// 本週額度走勢與額度消耗選的額度（「服務/額度 id」）；nil＝自動（第一個服務的每週額度）
    var trendWindow: String? {
        didSet { defaults.set(trendWindow, forKey: Key.trendWindow) }
    }

    var consumptionWindow: String? {
        didSet { defaults.set(consumptionWindow, forKey: Key.consumptionWindow) }
    }

    /// 統計卡片的全部／Claude／Codex 與 Token 活動的範圍
    var statsScope: TokenScope {
        didSet { defaults.set(statsScope.rawValue, forKey: Key.statsScope) }
    }

    var statsRange: TokenActivityRange {
        didSet { defaults.set(statsRange.rawValue, forKey: Key.statsRange) }
    }

    /// 已經播過 🔥 的連續天數紀錄（每個新紀錄只播一次）
    var celebratedStreak: Int {
        didSet { defaults.set(celebratedStreak, forKey: Key.celebratedStreak) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        iconStyle = defaults.string(forKey: Key.iconStyle).flatMap(MenuBarIconStyle.init) ?? .dualRing
        iconWindow = MenuBarWindowChoice(rawValue: defaults.string(forKey: Key.iconWindow) ?? "auto")
        layout = PanelLayout.resolve(stored: defaults.data(forKey: Key.sections), defaultOrder: PanelSection.defaultOrder)
        collapsed = Set(defaults.stringArray(forKey: Key.collapsed) ?? [])
        showsExpectedMarker = defaults.object(forKey: Key.expectedMarker) as? Bool ?? true
        trendWindow = defaults.string(forKey: Key.trendWindow)
        consumptionWindow = defaults.string(forKey: Key.consumptionWindow)
        statsScope = defaults.string(forKey: Key.statsScope).flatMap(TokenScope.init) ?? .all
        statsRange = defaults.string(forKey: Key.statsRange).flatMap(TokenActivityRange.init) ?? .days30
        celebratedStreak = defaults.integer(forKey: Key.celebratedStreak)
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
