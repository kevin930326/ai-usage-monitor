/// Mac 首次設定精靈（FR-54、ADR-0013）的判斷：每一步的狀態、缺什麼時要給的指令、什麼時候自動打開。
///
/// 只引導自動化不了的步驟；每一步的輸入都是 App 自己看得到的狀態（App 的位置、背景收集器、
/// `usage_collector.setup --json --dry-run` 的偵測結果、usage.json 有沒有這個服務的資料、通知權限、登入項目、
/// config.json 有沒有中繼網址）。不讀任何憑證、密鑰或對話內容。
public enum SetupStepID: String, CaseIterable, Identifiable, Sendable {
    /// App 在「應用程式」資料夾（.dmg 安裝時的「強制打開」與搬移）
    case location
    /// 背景收集器（內建的或 install-launchd.sh 的）
    case collector
    case claude
    case codex
    case notifications
    case loginItem
    case appearance
    /// 要不要接 iPhone（第一層，需要中繼）
    case iphone

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .location: "放進「應用程式」資料夾"
        case .collector: "背景收集器"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .notifications: "通知"
        case .loginItem: "登入時自動打開"
        case .appearance: "外觀"
        case .iphone: "在 iPhone 上看"
        }
    }
}

public enum SetupStepStatus: Equatable, Sendable {
    case done
    case needsAction
    /// 不做也可以（沒用這個服務、不接 iPhone、不要通知）
    case optional
}

/// `usage_collector.setup --json` 的服務狀態（與收集器的字串相同）
public enum ProviderLoginState: String, Sendable {
    case enabled
    case notLoggedIn = "not_logged_in"
    case apiKey = "api_key"
    case notInstalled = "not_installed"
    case unknown
}

public struct ProviderSetupInput: Equatable, Sendable {
    /// 偵測結果；開發版（沒有內建的 Python）或還沒偵測時為 nil
    public var login: ProviderLoginState?
    /// usage.json 有這個服務、而且沒有錯誤
    public var collecting: Bool
    /// usage.json 裡這個服務的錯誤（收集器寫的說明，不含憑證）
    public var collectError: String?

    public init(login: ProviderLoginState? = nil, collecting: Bool = false, collectError: String? = nil) {
        self.login = login
        self.collecting = collecting
        self.collectError = collectError
    }
}

public struct SetupInputs: Equatable, Sendable {
    public var appInApplications: Bool
    /// 背景收集器需要使用者處理（不在「應用程式」、隔離屬性、登入項目被關、停用）
    public var collectorNeedsAction: Bool
    public var claude: ProviderSetupInput
    public var codex: ProviderSetupInput
    /// nil：還沒問過
    public var notificationsAllowed: Bool?
    public var loginItemEnabled: Bool
    /// config.json 有中繼網址（只看欄位在不在）
    public var relayConfigured: Bool

    public init(appInApplications: Bool, collectorNeedsAction: Bool, claude: ProviderSetupInput, codex: ProviderSetupInput,
                notificationsAllowed: Bool?, loginItemEnabled: Bool, relayConfigured: Bool) {
        self.appInApplications = appInApplications
        self.collectorNeedsAction = collectorNeedsAction
        self.claude = claude
        self.codex = codex
        self.notificationsAllowed = notificationsAllowed
        self.loginItemEnabled = loginItemEnabled
        self.relayConfigured = relayConfigured
    }
}

public enum SetupChecklist {
    /// 使用者看過並按「完成」後記在 App 的 UserDefaults；之後只從設定重新打開
    public static let completedKey = "wizard.completed"

    public static func status(of step: SetupStepID, _ inputs: SetupInputs) -> SetupStepStatus {
        switch step {
        case .location: return inputs.appInApplications ? .done : .needsAction
        case .collector: return inputs.collectorNeedsAction ? .needsAction : .done
        case .claude: return providerStatus(inputs.claude, other: inputs.codex)
        case .codex: return providerStatus(inputs.codex, other: inputs.claude)
        case .notifications: return inputs.notificationsAllowed == true ? .done : .optional
        case .loginItem: return inputs.loginItemEnabled ? .done : .optional
        case .appearance: return .done
        case .iphone: return inputs.relayConfigured ? .done : .optional
        }
    }

    /// 一個服務目前的情況。狀態、說明與指令都由這裡決定，三者一致。
    /// 優先序：最新偵測的明確結果（沒登入、API key、沒安裝）> 還沒過期的 usage.json > 偵測「不知道」
    enum ProviderSituation: Equatable {
        /// usage.json 有這個服務、沒過期、沒有錯誤
        case collecting
        /// 偵測是已登入，但還沒有資料
        case loggedIn
        case notLoggedIn
        case apiKey
        case notInstalled
        case collectError(String)
        /// 偵測結果認不得，也沒有資料
        case unknown
        /// 沒有偵測結果（開發版），也沒有資料
        case noInfo
    }

    static func situation(_ p: ProviderSetupInput) -> ProviderSituation {
        switch p.login {
        case .notLoggedIn: return .notLoggedIn
        case .apiKey: return .apiKey
        case .enabled: return p.collecting ? .collecting : .loggedIn
        case .notInstalled: return p.collecting ? .collecting : .notInstalled
        case .unknown, nil:
            if p.collecting { return .collecting }
            if let error = p.collectError { return .collectError(error) }
            return p.login == .unknown ? .unknown : .noInfo
        }
    }

    static func isUsable(_ p: ProviderSetupInput) -> Bool {
        [.collecting, .loggedIn].contains(situation(p))
    }

    /// 可以用＝完成；沒安裝或沒有任何資訊＝可選（另一個服務可用時），兩個都不能用時兩個都要處理
    static func providerStatus(_ provider: ProviderSetupInput, other: ProviderSetupInput) -> SetupStepStatus {
        switch situation(provider) {
        case .collecting, .loggedIn: .done
        case .notInstalled, .noInfo: isUsable(other) ? .optional : .needsAction
        case .notLoggedIn, .apiKey, .collectError, .unknown: .needsAction
        }
    }

    /// 首次打開時要不要自動顯示：沒有按過「完成」，而且還沒有任何資料（usage.json 不存在）。
    /// 已經在用的人（有資料）不會被打擾，從設定的「重新執行設定精靈」打開。
    public static func showsAutomatically(completed: Bool, hasUsageData: Bool) -> Bool {
        !completed && !hasUsageData
    }

    /// 終端機指令（給「複製」按鈕）；不需要時是空的
    public static func commands(for step: SetupStepID, _ inputs: SetupInputs) -> [String] {
        guard step == .claude || step == .codex else { return [] }
        let claude = step == .claude
        switch situation(claude ? inputs.claude : inputs.codex) {
        case .notInstalled:
            return claude ? ["curl -fsSL https://claude.ai/install.sh | bash", "claude auth login"]
                          : ["npm install -g @openai/codex", "codex login"]
        case .notLoggedIn, .unknown, .collectError, .noInfo:
            return [claude ? "claude auth login" : "codex login"]
        case .apiKey:
            return ["codex logout", "codex login"]
        case .collecting, .loggedIn:
            return []
        }
    }

    /// 服務那一步的說明
    public static func providerDetail(_ step: SetupStepID, _ inputs: SetupInputs) -> String {
        let name = step == .codex ? "Codex CLI" : "Claude Code"
        switch situation(step == .codex ? inputs.codex : inputs.claude) {
        case .collecting: return "已登入，正在收集用量。"
        case .loggedIn: return "已登入，下一次收集（5 分鐘內）就會出現在面板。"
        case .collectError(let error): return "收集時發生問題：\(error)"
        case .notLoggedIn: return "已安裝但還沒登入。在終端機執行下面的指令，用訂閱的帳號登入。"
        case .apiKey: return "目前用 API key 登入，沒有訂閱的額度可以顯示。改用 ChatGPT 帳號登入："
        case .notInstalled:
            return status(of: step, inputs) == .optional
                ? "沒有安裝。沒在用 \(name) 的話可以略過。"
                : "沒有安裝。至少要有 Claude Code 或 Codex 其中一個：安裝後登入。"
        case .unknown: return "無法確認登入狀態（指令沒有回應或結果認不得）。在終端機登入一次後按「重新檢查」。"
        case .noInfo:
            return status(of: step, inputs) == .optional
                ? "還沒有資料。沒在用 \(name) 的話可以略過。"
                : "還沒有資料。登入 \(name) 後，下一次收集就會出現。"
        }
    }
}
