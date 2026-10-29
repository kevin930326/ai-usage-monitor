import Foundation
import Observation
import UsageKit

/// 選單列圖示的樣式（FR-33）。
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case dualRing
    case bar
    case percent
    case ringPercent
    /// 角色（ADR-0016）：設定裡選的角色，額度用眼睛的形狀表示（沒有狀態點）
    case character
    case characterPercent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dualRing: "雙圓環"
        case .bar: "橫條"
        case .percent: "只有 %"
        case .ringPercent: "圓環＋%"
        case .character: "角色"
        case .characterPercent: "角色＋%"
        }
    }

    var showsCharacter: Bool { self == .character || self == .characterPercent }
}

/// 面板的區塊（FR-34、FR-35）。之後的區塊（走勢、統計…）在這裡加一個 case 與預設順序即可，
/// 舊的設定會依 `PanelLayout.resolve` 自動插入新區塊，不需要改設定格式。
/// 順序同 ADR-0008 第 2 節的表。
enum PanelSection: String, CaseIterable, Identifiable {
    case ring
    case suggest
    case quota
    case resets
    case trend
    case consumption
    case stats
    case status

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
        case .status: "服務狀態"
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
        case .stats: "這台 Mac（有第二層時含其他電腦）的 Token：本週、單日最高、最長任務、連續天數、Token 活動與活動熱力圖"
        case .status: "Anthropic 與 OpenAI 公開狀態頁的結果，分辨服務異常與額度用完；正常時只有一行"
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

    /// Debug 版的面板預覽、截圖、實際視窗檢查與效能量測（`DebugTools.isDemo`）用獨立、每次清空的設定，不動到正式設定，
    /// 結果也不受使用者隱藏或收合的卡片影響。
    private static var storage: UserDefaults {
        #if DEBUG
        if DebugTools.isDemo {
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
        static let statsDevice = "panel.statsDevice"
        static let statsMeasure = "panel.statsMeasure"
        static let celebratedStreak = "panel.celebratedStreak"
        static let celebratedLevel = "mascot.celebratedLevel"
        static let notifyLow = "notify.low"
        static let notifyTooFast = "notify.tooFast"
        static let notifyReset = "notify.reset"
        static let notifyCreditExpiring = "notify.creditExpiring"
        static let notifyAskedAtLaunch = "notify.askedAtLaunch"
        static let hotKey = "hotKey.panel"
        static let notchEnabled = "notch.enabled"
        static let mascotCharacter = "notch.character"
        static let mascotLook = "notch.look"
        static let menuBarIconShown = "menubar.iconShown"
        static let notchClickOpensPanel = "notch.clickOpensPanel"
        static let notchIntro = "notch.intro"
        static let mascotMotion = "notch.motion"
        static let mascotFollowPointer = "notch.followPointer"
        static let mascotSleepMinutes = "notch.sleepMinutes"
        static let mascotQuietUntil = "notch.quietUntil"
        static let notchHintShown = "notch.hintShown"
        static let agentNeedsYouSeconds = "agent.notifyNeedsYouSeconds"
        static let agentLongTaskMinutes = "agent.notifyLongTaskMinutes"
        static let notchWaitingPulse = "notch.waitingPulse"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// 外觀（FR-51）：套用到面板、設定、完整統計與設定精靈的視窗（`windowAppearance`）；選單列圖示跟隨選單列
    var appearance: AppearanceChoice {
        didSet { defaults.set(appearance.rawValue, forKey: AppearanceChoice.storageKey) }
    }

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

    /// 第二層的裝置範圍（所有電腦／這台 Mac／某台電腦）；nil＝預設（有其他電腦時「所有電腦」）。
    /// 面板與完整統計視窗共用；選的電腦不在清單中時由 `TokenDevices.resolve` 退回預設
    var statsDevice: TokenDeviceScope? {
        didSet { defaults.set(statsDevice?.rawValue, forKey: Key.statsDevice) }
    }

    /// 統計是否含快取讀取（FR-60）；預設不含。面板與完整統計視窗共用
    var statsMeasure: TokenMeasure {
        didSet { defaults.set(statsMeasure.rawValue, forKey: Key.statsMeasure) }
    }

    /// 已經播過 🔥 的連續天數紀錄（每個新紀錄只播一次）
    var celebratedStreak: Int {
        didSet { defaults.set(celebratedStreak, forKey: Key.celebratedStreak) }
    }

    /// 已經慶祝過的角色等級（ADR-0020；0＝還沒看過等級：第一次只記下、不慶祝）
    var celebratedLevel: Int {
        didSet { defaults.set(celebratedLevel, forKey: Key.celebratedLevel) }
    }

    /// 額度通知的三個開關（FR-19）。「剩不到 20%」預設開（第一次打開 App 時向系統要求權限），其他兩個預設關
    var notifyLow: Bool {
        didSet { defaults.set(notifyLow, forKey: Key.notifyLow) }
    }

    var notifyTooFast: Bool {
        didSet { defaults.set(notifyTooFast, forKey: Key.notifyTooFast) }
    }

    var notifyReset: Bool {
        didSet { defaults.set(notifyReset, forKey: Key.notifyReset) }
    }

    /// 重置卷 3 天內到期（FR-59），預設開
    var notifyCreditExpiring: Bool {
        didSet { defaults.set(notifyCreditExpiring, forKey: Key.notifyCreditExpiring) }
    }

    func notifies(_ kind: QuotaAlertKind) -> Bool {
        switch kind {
        case .low: notifyLow
        case .tooFast: notifyTooFast
        case .reset: notifyReset
        case .creditExpiring: notifyCreditExpiring
        }
    }

    var notifiesAnything: Bool { notifyLow || notifyTooFast || notifyReset || notifyCreditExpiring }

    /// 啟動時是否該向系統要求通知權限：有任一個開關打開、而且還沒在啟動時問過（只問一次，之後由設定的開關處理）
    func takeLaunchAuthorizationRequest() -> Bool {
        guard notifiesAnything, !defaults.bool(forKey: Key.notifyAskedAtLaunch) else { return false }
        defaults.set(true, forKey: Key.notifyAskedAtLaunch)
        return true
    }

    /// 打開面板的全域快捷鍵（FR-47，ADR-0008 第 7、9 節）：沒設定過時是 ⌥⌘U；清除後存空資料，表示「不使用」
    var hotKey: HotKeyShortcut? {
        didSet { defaults.set(hotKey?.encoded() ?? Data(), forKey: Key.hotKey) }
    }

    /// 顯示選單列圖示（ADR-0008 第 9 節，預設開）。和瀏海面板不能同時關：關最後一個時由設定頁擋下
    var menuBarIconShown: Bool {
        didSet { defaults.set(menuBarIconShown, forKey: Key.menuBarIconShown) }
    }

    /// 點收合的瀏海直接打開完整面板（預設關；滑過仍是原本的展開）
    var notchClickOpensPanel: Bool {
        didSet { defaults.set(notchClickOpensPanel, forKey: Key.notchClickOpensPanel) }
    }

    /// 選單列標籤已經出現過、取得了打開視窗的動作（不存）；圖示設成不顯示時，啟動後先放出來到這時為止
    var windowActionsReady = false

    /// 選單列圖示與瀏海面板至少要留一個（沒有的話就沒有地方打開 App）；瀏海要真的顯示才算（Fable F-12）
    var canHideMenuBarIcon: Bool { notchEnabled && MascotController.shared.baseConfig != nil }
    var canDisableNotch: Bool { menuBarIconShown }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceChoice(stored: defaults.string(forKey: AppearanceChoice.storageKey))
        iconStyle = defaults.string(forKey: Key.iconStyle).flatMap(MenuBarIconStyle.init) ?? .dualRing
        iconWindow = MenuBarWindowChoice(rawValue: defaults.string(forKey: Key.iconWindow) ?? "auto")
        layout = PanelLayout.resolve(stored: defaults.data(forKey: Key.sections), defaultOrder: PanelSection.defaultOrder)
        collapsed = Set(defaults.stringArray(forKey: Key.collapsed) ?? [])
        showsExpectedMarker = defaults.object(forKey: Key.expectedMarker) as? Bool ?? true
        trendWindow = defaults.string(forKey: Key.trendWindow)
        consumptionWindow = defaults.string(forKey: Key.consumptionWindow)
        statsScope = defaults.string(forKey: Key.statsScope).flatMap(TokenScope.init) ?? .all
        statsRange = defaults.string(forKey: Key.statsRange).flatMap(TokenActivityRange.init) ?? .days30
        statsDevice = defaults.string(forKey: Key.statsDevice).flatMap(TokenDeviceScope.init)
        statsMeasure = defaults.string(forKey: Key.statsMeasure).flatMap(TokenMeasure.init) ?? .main
        celebratedStreak = defaults.integer(forKey: Key.celebratedStreak)
        celebratedLevel = defaults.integer(forKey: Key.celebratedLevel)
        notifyLow = defaults.object(forKey: Key.notifyLow) as? Bool ?? true
        notifyTooFast = defaults.bool(forKey: Key.notifyTooFast)
        notifyReset = defaults.bool(forKey: Key.notifyReset)
        notifyCreditExpiring = defaults.object(forKey: Key.notifyCreditExpiring) as? Bool ?? true
        hotKey = defaults.object(forKey: Key.hotKey) == nil ? .defaultShortcut
            : defaults.data(forKey: Key.hotKey).flatMap(HotKeyShortcut.decode)
        let notchOn = defaults.object(forKey: Key.notchEnabled) as? Bool ?? true
        notchEnabled = notchOn
        mascotCharacter = defaults.string(forKey: Key.mascotCharacter).flatMap(MascotCharacter.init) ?? .claude
        mascotLook = defaults.string(forKey: Key.mascotLook)
        // 兩個都關（例如舊版關了瀏海，又用 ⌘ 拖走圖示）時把圖示放回來
        menuBarIconShown = (defaults.object(forKey: Key.menuBarIconShown) as? Bool ?? true) || !notchOn
        notchClickOpensPanel = defaults.bool(forKey: Key.notchClickOpensPanel)
        notchIntro = defaults.string(forKey: Key.notchIntro).flatMap(NotchIntroChoice.init) ?? .firstOnly
        mascotMotion = defaults.string(forKey: Key.mascotMotion).flatMap(MascotMotionLevel.init) ?? .full
        mascotFollowPointer = defaults.object(forKey: Key.mascotFollowPointer) as? Bool ?? true
        let minutes = defaults.integer(forKey: Key.mascotSleepMinutes)
        mascotSleepMinutes = Self.sleepMinuteChoices.contains(minutes) ? minutes : Self.defaultSleepMinutes
        mascotQuietUntil = defaults.object(forKey: Key.mascotQuietUntil) as? Date
        notchHintShown = defaults.bool(forKey: Key.notchHintShown)
        let seconds = defaults.object(forKey: Key.agentNeedsYouSeconds) as? Int ?? 20
        agentNeedsYouSeconds = Self.needsYouSecondChoices.contains(seconds) ? seconds : 20
        let taskMinutes = defaults.object(forKey: Key.agentLongTaskMinutes) as? Int ?? 3
        agentLongTaskMinutes = Self.longTaskMinuteChoices.contains(taskMinutes) ? taskMinutes : 3
        notchWaitingPulse = defaults.object(forKey: Key.notchWaitingPulse) as? Bool ?? true
    }

    /// 瀏海面板（ADR-0016）：預設開啟；關掉時選單列圖示與面板照常
    var notchEnabled: Bool {
        didSet {
            defaults.set(notchEnabled, forKey: Key.notchEnabled)
            NotchPanelController.shared.apply()
        }
    }

    /// 瀏海裡的角色（一次只顯示一隻）
    var mascotCharacter: MascotCharacter {
        didSet {
            defaults.set(mascotCharacter.rawValue, forKey: Key.mascotCharacter)
            MascotController.shared.updateStatus()
        }
    }

    /// 角色外觀（ADR-0021）：`shared/mascot-looks.json` 的代號；nil 是跟著服務（預設）
    var mascotLook: String? {
        didSet {
            defaults.set(mascotLook, forKey: Key.mascotLook)
            MascotController.shared.lookChanged()
        }
    }

    /// 過場：每次展開／只有第一次（預設）／關閉
    var notchIntro: NotchIntroChoice {
        didSet { defaults.set(notchIntro.rawValue, forKey: Key.notchIntro) }
    }

    /// 角色的動畫：完整（預設）／簡單／關閉；「減少動態效果」時完整當成簡單
    var mascotMotion: MascotMotionLevel {
        didSet {
            defaults.set(mascotMotion.rawValue, forKey: Key.mascotMotion)
            MascotController.shared.motionChanged()
        }
    }

    /// 角色的眼睛跟著游標（整個螢幕；展開一律看，收合時工作中與睡著不看，ADR-0016 第 3 節第 8 點；預設開）
    var mascotFollowPointer: Bool {
        didSet {
            defaults.set(mascotFollowPointer, forKey: Key.mascotFollowPointer)
            MascotController.shared.followPointerChanged()
        }
    }

    static let sleepMinuteChoices = [1, 3, 5, 10, 15, 20, 30]
    /// 睡覺的預設（ADR-0017 第 4 節，2026-10-29 從 5 改成 20：AI 叫背景指令等 CI 時 5 分鐘就睡太快）。
    /// 只有使用者選過才存進 UserDefaults，所以改過的人不受影響
    static let defaultSleepMinutes = 20

    /// Claude 與 Codex 都閒置超過幾分鐘角色就睡（預設 20，ADR-0017 第 4 節）
    var mascotSleepMinutes: Int {
        didSet {
            defaults.set(mascotSleepMinutes, forKey: Key.mascotSleepMinutes)
            MascotController.shared.checkActivitySoon()
        }
    }

    /// 靜音或勿擾到這個時間（角色的提醒動畫與瀏海的通知都不出現）；nil 表示沒有
    var mascotQuietUntil: Date? {
        didSet {
            if let mascotQuietUntil { defaults.set(mascotQuietUntil, forKey: Key.mascotQuietUntil) }
            else { defaults.removeObject(forKey: Key.mascotQuietUntil) }
        }
    }

    /// 第一次展開瀏海時的提示（右鍵有更多）已經顯示過
    var notchHintShown: Bool {
        didSet { defaults.set(notchHintShown, forKey: Key.notchHintShown) }
    }

    /// 0 表示關閉
    static let needsYouSecondChoices = [0, 10, 20, 30, 60, 120]
    static let longTaskMinuteChoices = [0, 1, 3, 5, 10, 20]

    /// AI 需要你超過幾秒還沒處理就發系統通知（預設 20；0 關閉）
    var agentNeedsYouSeconds: Int {
        didSet {
            defaults.set(agentNeedsYouSeconds, forKey: Key.agentNeedsYouSeconds)
            AgentMonitor.shared.noticeSettingsChanged()
        }
    }

    /// 跑超過幾分鐘的任務完成時發系統通知（預設 3；0 關閉）
    var agentLongTaskMinutes: Int {
        didSet { defaults.set(agentLongTaskMinutes, forKey: Key.agentLongTaskMinutes) }
    }

    /// AI 等你下一個指令時，收合的瀏海輕微脈動（預設開）
    var notchWaitingPulse: Bool {
        didSet {
            defaults.set(notchWaitingPulse, forKey: Key.notchWaitingPulse)
            MascotController.shared.agentStateChanged()
        }
    }

    /// 通知的門檻（毫秒；關閉時是 Int64.max，永遠不到）
    var agentNoticePolicy: AgentNoticePolicy {
        AgentNoticePolicy(needsYouAfter: agentNeedsYouSeconds > 0 ? Int64(agentNeedsYouSeconds) * 1000 : .max,
                          longTask: agentLongTaskMinutes > 0 ? Int64(agentLongTaskMinutes) * 60_000 : .max)
    }

    func isMascotQuiet(at now: Date) -> Bool {
        mascotQuietUntil.map { now < $0 } ?? false
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
