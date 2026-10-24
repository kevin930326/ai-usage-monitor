import Foundation
import Observation
import ServiceManagement

/// App 內建的收集器（FR-53、ADR-0013 第 3 節）：發布版的 App 內嵌 Python 與收集器，
/// 以 `SMAppService.agent` 註冊 App 內的 LaunchAgent（`Contents/Library/LaunchAgents/<bundle ID>.collector.plist`）。
///
/// - 開發版（`scripts/install-mac-app.sh`、Xcode）沒有內嵌的 Python：什麼都不做，照舊用 `install-launchd.sh` 的收集器。
/// - 偵測到 `install-launchd.sh` 的收集器時**不註冊**（避免每 5 分鐘跑兩次、重複上傳），只在設定與精靈提示，
///   由使用者按「改用內建收集器」才遷移。
/// - 沒有舊安裝、App 在「應用程式」資料夾、使用者沒停用過：首次打開自動註冊（第 0 層「打開就完成」）。
/// - App 搬家後 launchd 仍指向舊路徑（原型實測 `EX_CONFIG`），啟動時發現路徑變了就解除再註冊。
/// App 本身仍不連網、不持有密鑰：這裡只執行 `launchctl`、內建收集器的 `setup`（找 claude／codex、寫 config.json）與 `xattr`。
@Observable
@MainActor
final class CollectorService {
    static let shared = CollectorService()

    enum State: Hashable {
        /// App 內沒有內建的 Python（開發版）
        case devBuild
        /// `install-launchd.sh` 的收集器在執行：不註冊內建的，提示可以遷移
        case legacy
        /// App 不在「應用程式」資料夾，或從 .dmg／下載資料夾直接執行（App Translocation）：註冊了之後會失效
        case needsApplicationsFolder
        /// 內嵌的 Python 帶隔離屬性（.dmg 安裝）：等使用者按「允許內建收集器執行」
        case quarantined
        /// 還沒註冊，或使用者停用了
        case notRegistered
        /// 使用者在「系統設定 › 一般 › 登入項目」關掉了
        case requiresApproval
        case enabled
    }

    /// 與 `collector/scripts/install-launchd.sh` 的 LABEL 相同
    nonisolated static let legacyLabel = "io.github.kevin930326.ai-usage-monitor"
    private static let userDisabledKey = "collector.builtin.userDisabled"
    private static let registeredPathKey = "collector.builtin.registeredBundlePath"

    /// 偵測到舊安裝時，還不能改用內建收集器的原因（`.legacy` 才有值）
    enum MigrationBlocker: Hashable {
        /// App 不在「應用程式」：註冊了之後會失效
        case applicationsFolder
        /// 內嵌的 Python 帶隔離屬性：先按「允許內建收集器執行」
        case quarantine
    }

    private(set) var state: State = .devBuild
    private(set) var migrationBlocker: MigrationBlocker?
    /// 最後一次操作失敗的說明（不含指令輸出）
    private(set) var errorText: String?
    private(set) var busy = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bundle: Bundle

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
    }

    #if DEBUG
    /// 截圖用：固定狀態，不查詢 launchd、不註冊
    static func preview(_ state: State) -> CollectorService {
        let service = CollectorService()
        service.state = state
        return service
    }
    #endif

    // MARK: - 位置

    private var bundleID: String { bundle.bundleIdentifier ?? "io.github.kevin930326.AIUsageMenuBar" }
    var builtinLabel: String { "\(bundleID).collector" }
    private var plistName: String { "\(builtinLabel).plist" }
    private var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// 內嵌的 Python（`scripts/bundle-collector.sh` 放進去）
    var runtimeURL: URL { bundle.bundleURL.appendingPathComponent("Contents/Resources/python/bin/python3.13") }
    var hasRuntime: Bool { FileManager.default.isExecutableFile(atPath: runtimeURL.path) }

    private nonisolated static var launchAgentsDir: URL {
        #if DEBUG
        // 安裝測試：指到暫存資料夾，這台 Mac 真的舊安裝不影響「乾淨環境」的驗證
        if let custom = ProcessInfo.processInfo.environment["AUM_LAUNCH_AGENTS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    nonisolated static var legacyPlistURL: URL { launchAgentsDir.appendingPathComponent("\(legacyLabel).plist") }

    /// 安裝測試（Debug 且設定了 `AUM_LAUNCH_AGENTS_DIR`）：舊安裝是暫存資料夾裡的假 plist，
    /// 遷移時不能停止這台 Mac 真的舊收集器、也不能把假 plist 丟進真的垃圾桶
    private nonisolated static var testingLaunchAgents: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["AUM_LAUNCH_AGENTS_DIR"] != nil
        #else
        return false
        #endif
    }

    /// 設定 `AI_USAGE_MONITOR_HOME`（測試、截圖、效能量測）時不碰真的登入項目；Debug 的安裝測試以 `AUM_TEST_AGENT=1` 例外
    private var allowedToRegister: Bool {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        if env["AUM_TEST_AGENT"] == "1" { return true }
        #endif
        return (env["AI_USAGE_MONITOR_HOME"] ?? "").isEmpty
    }

    private var inApplicationsFolder: Bool {
        let path = bundle.bundleURL.path
        if path.contains("/AppTranslocation/") { return false }
        #if DEBUG
        if ProcessInfo.processInfo.environment["AUM_TEST_AGENT"] == "1" { return true }
        #endif
        let parent = bundle.bundleURL.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent == "/Applications" || parent == "\(home)/Applications"
    }

    private var runtimeQuarantined: Bool {
        getxattr(runtimeURL.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// 面板「更新」要踢的 label：內建的在執行就踢它，否則踢舊的（開發版、或還沒遷移）
    var kickLabel: String { state == .enabled ? builtinLabel : Self.legacyLabel }

    // MARK: - 狀態

    func refresh() async {
        state = await computeState()
        migrationBlocker = state == .legacy ? currentBlocker : nil
    }

    /// 位置與隔離屬性先於註冊狀態判斷：已註冊但 App 被搬走、或 Python 帶隔離屬性時，收集器其實跑不起來
    private func computeState() async -> State {
        guard hasRuntime else { return .devBuild }
        if await Self.legacyInstalled() { return .legacy }
        if !inApplicationsFolder { return .needsApplicationsFolder }
        if runtimeQuarantined { return .quarantined }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    private var currentBlocker: MigrationBlocker? {
        if !inApplicationsFolder { return .applicationsFolder }
        if runtimeQuarantined { return .quarantine }
        return nil
    }

    /// plist 在，或 launchd 有這個工作（plist 被移走但還沒登出）
    nonisolated static func legacyInstalled() async -> Bool {
        if FileManager.default.fileExists(atPath: legacyPlistURL.path) { return true }
        if testingLaunchAgents { return false }
        return await launchctl(["print", "gui/\(getuid())/\(legacyLabel)"]) == 0
    }

    // MARK: - 啟動時

    /// App 啟動後呼叫：首次打開自動註冊；App 搬家後重新註冊。偵測到舊安裝時什麼都不做。
    func start() async {
        await refresh()
        guard allowedToRegister else { return }
        switch state {
        case .notRegistered where !defaults.bool(forKey: Self.userDisabledKey):
            UsageStore.log("builtin collector: first launch, registering")
            await register()
        case .enabled where defaults.string(forKey: Self.registeredPathKey) != bundle.bundleURL.path:
            // 換了位置（或升級前沒記錄）：launchd 記的是舊路徑，解除再註冊才會生效
            UsageStore.log("builtin collector: app moved, re-registering")
            try? await service.unregister()
            await register()
        case .enabled:
            // 每次打開重新偵測登入狀態：之後才登入的服務在下一次收集時就會啟用
            await runSetup()
        default:
            break
        }
        #if DEBUG
        // 安裝測試：啟動後直接按「改用內建收集器」（scripts 的乾淨環境驗證用，只在 AUM_TEST_AGENT=1 時）
        if ProcessInfo.processInfo.environment["AUM_TEST_ACTION"] == "migrate" { await migrateFromLegacy() }
        #endif
    }

    // MARK: - 使用者的操作

    /// 註冊內建的收集器（設定或精靈的「啟用」、首次打開）。先以內建收集器偵測 claude／codex 寫進 config.json。
    func register() async {
        guard hasRuntime, allowedToRegister else { return }
        busy = true
        defer { busy = false }
        if await Self.legacyInstalled() {
            state = .legacy
            return
        }
        await runSetup()
        if registerService() {
            errorText = nil
            _ = await Self.launchctl(["kickstart", "gui/\(getuid())/\(builtinLabel)"])
        }
        await refresh()
    }

    /// `SMAppService.register()`；失敗時設定 `errorText` 並回傳 false
    private func registerService() -> Bool {
        do {
            try service.register()
            defaults.set(bundle.bundleURL.path, forKey: Self.registeredPathKey)
            defaults.set(false, forKey: Self.userDisabledKey)
            return true
        } catch {
            errorText = "無法註冊背景收集器，可到「系統設定 › 一般 › 登入項目與延伸功能」查看。"
            UsageStore.log("builtin collector register failed: \((error as NSError).code)")
            return false
        }
    }

    /// 停用內建的收集器（資料不刪）；之後不再自動註冊
    func disable() async {
        busy = true
        defer { busy = false }
        do {
            try await service.unregister()
            defaults.set(true, forKey: Self.userDisabledKey)
            errorText = nil
        } catch {
            errorText = "無法停用背景收集器，可到「系統設定 › 一般 › 登入項目與延伸功能」關閉。"
            UsageStore.log("builtin collector unregister failed: \((error as NSError).code)")
        }
        await refresh()
    }

    /// 改用內建收集器。資料與設定沿用；任何一步失敗都停在「舊的照常執行」：
    /// 1. 檢查位置與隔離屬性、以內建的 Python 跑一次 setup（跑不起來就不遷移）
    /// 2. 先註冊內建的並確認 launchd 已啟用（舊 plist 還在時，內建的每次執行都會直接結束，不會重複收集）
    /// 3. 舊 plist 移到垃圾桶（可放回），最後才停止舊的 launchd 工作，並請內建的立即執行一次
    func migrateFromLegacy() async {
        guard hasRuntime, allowedToRegister else { return }
        busy = true
        defer { busy = false }
        let kept = "舊的收集器照常執行。"
        if let blocker = currentBlocker {
            migrationBlocker = blocker
            errorText = blocker == .applicationsFolder
                ? "先把 App 放進「應用程式」資料夾再改用內建收集器；\(kept)"
                : "先按「允許內建收集器執行」；\(kept)"
            return
        }
        guard await runSetup() == 0 else {
            errorText = "內建收集器無法執行（偵測 Claude Code／Codex 時失敗），沒有遷移；\(kept)"
            return
        }
        guard registerService() else {
            errorText = "無法註冊內建收集器，沒有遷移；\(kept)"
            await refresh()
            return
        }
        guard service.status == .enabled else {
            // 例如被「登入項目」擋下：內建的不會執行，撤回註冊、保留舊的
            try? await service.unregister()
            errorText = "內建收集器需要在「系統設定 › 一般 › 登入項目與延伸功能」允許背景執行，沒有遷移；\(kept)"
            await refresh()
            return
        }
        let plist = Self.legacyPlistURL
        if FileManager.default.fileExists(atPath: plist.path) {
            do {
                if Self.testingLaunchAgents {
                    let trash = Self.launchAgentsDir.deletingLastPathComponent().appendingPathComponent("Trash")
                    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: plist, to: trash.appendingPathComponent(plist.lastPathComponent))
                } else {
                    try FileManager.default.trashItem(at: plist, resultingItemURL: nil)
                }
            } catch {
                try? await service.unregister()
                errorText = "無法移走舊的排程設定（\(plist.lastPathComponent)），沒有遷移；\(kept)"
                await refresh()
                return
            }
        }
        if !Self.testingLaunchAgents {
            _ = await Self.launchctl(["bootout", "gui/\(getuid())/\(Self.legacyLabel)"])
        }
        errorText = nil
        UsageStore.log("builtin collector: migrated from install-launchd.sh")
        _ = await Self.launchctl(["kickstart", "gui/\(getuid())/\(builtinLabel)"])
        await refresh()
    }

    /// .dmg 安裝時內嵌的 Python 帶隔離屬性：使用者已核准過這個 App，按下後移除 App 自己資料夾內的隔離屬性
    func allowQuarantinedRuntime() async {
        _ = await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundle.bundleURL.path])
        await refresh()
        if runtimeQuarantined { errorText = "無法移除隔離標記，可以重新用一行安裝指令安裝。" }
        if state == .notRegistered && !defaults.bool(forKey: Self.userDisabledKey) { await register() }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - 指令列

    /// `AIUsageMenuBar --unregister-collector`：`scripts/install.sh --uninstall` 用，解除註冊後立即結束。
    static func handleCommandLine() {
        guard CommandLine.arguments.contains("--unregister-collector") else { return }
        let id = Bundle.main.bundleIdentifier ?? "io.github.kevin930326.AIUsageMenuBar"
        let service = SMAppService.agent(plistName: "\(id).collector.plist")
        do {
            if service.status != .notRegistered && service.status != .notFound { try service.unregister() }
            print("unregistered")
            exit(0)
        } catch {
            print("unregister failed: \((error as NSError).code)")
            exit(1)
        }
    }

    // MARK: - 內部

    /// 以內建的 Python 執行 `usage_collector.setup`：找 claude／codex 的路徑、偵測登入狀態寫進 config.json（ADR-0013 第 4 節）。
    /// 回傳結束碼（無法啟動時為 nil）
    @discardableResult
    private func runSetup() async -> Int32? {
        let status = await Self.run(runtimeURL.path, ["-I", "-B", "-X", "utf8", "-m", "usage_collector.setup", "--json"])
        UsageStore.log("builtin collector setup exit=\(status.map(String.init) ?? "nil")")
        return status
    }

    private nonisolated static func launchctl(_ arguments: [String]) async -> Int32? {
        await run("/bin/launchctl", arguments)
    }

    /// 在背景執行指令，丟棄輸出，回傳結束碼（無法啟動時為 nil）
    private nonisolated static func run(_ path: String, _ arguments: [String]) async -> Int32? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }
}
