import Foundation
import Observation
import UsageKit
import WidgetKit

@Observable
@MainActor
final class WatchModel {
    private(set) var snapshot: UsageSnapshot?
    private(set) var errorMessage: String?
    /// iPhone 傳來的設定存不進 Keychain（整合審查 D-a）：與抓取錯誤分開，抓取成功不會把它洗掉，未設定時也顯示
    private(set) var settingsError: String?
    private(set) var isLoading = false
    /// 每套用一次新設定加一；抓取結束時世代不同就丟掉結果（整合審查 D-b：舊密鑰的 401 不能蓋過新密鑰的成功）
    @ObservationIgnored private var settingsGeneration = 0

    private(set) var relayURL = UserDefaults.standard.string(forKey: "relayURL") ?? ""
    private(set) var readToken = KeychainStore.read("relay-read-token") ?? ""

    /// DEBUG 示範情境（環境變數 AUM_DEMO），有值時只用假資料、不連網。
    let demoScenario: String?

    @ObservationIgnored private lazy var receiver = SettingsReceiver { [weak self] url, token in
        self?.apply(url: url, token: token)
    }

    var isConfigured: Bool { demoScenario != nil || (!relayURL.isEmpty && !readToken.isEmpty) }

    init() {
        #if DEBUG
        demoScenario = DemoData.current?.rawValue
        // 截圖用：模擬 iPhone 傳來的設定存不進 Keychain（整合審查 D-a）
        if ProcessInfo.processInfo.environment["AUM_DEMO_SETTINGS_ERROR"] == "1" {
            settingsError = "無法儲存 iPhone 傳來的設定（示範錯誤）"
        }
        #else
        demoScenario = nil
        #endif
    }

    func activateConnectivity() {
        receiver.activate()
    }

    /// 回到前景時向 iPhone 要最新設定（iPhone 改了網址或密鑰時，手錶下次打開就會跟上）
    func requestSettings() {
        receiver.requestSettings()
    }

    func refresh() async {
        guard isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        let generation = settingsGeneration
        do {
            let snapshot = try await fetch()
            guard generation == settingsGeneration else { return }
            self.snapshot = snapshot
            errorMessage = nil
            WatchSnapshotStore.save(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            guard generation == settingsGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// iPhone 傳來的中繼設定（FR-30）。密鑰只存在 Keychain（sendMessage 不會被系統保存）。
    private func apply(url rawURL: String, token rawToken: String) {
        // 較舊的 iPhone App 可能送來帶換行的值，存之前再清一次
        let url = RelayInput.clean(rawURL), token = RelayInput.clean(rawToken)
        guard url != relayURL || token != readToken else { return }
        do {
            try KeychainStore.write(token, account: "relay-read-token")
        } catch {
            // 沒存成功就沿用舊設定；iPhone 下次送設定時會再試
            settingsError = "無法儲存 iPhone 傳來的設定（\(error.localizedDescription)）"
            return
        }
        settingsError = nil
        settingsGeneration += 1
        relayURL = url
        readToken = token
        UserDefaults.standard.set(url, forKey: "relayURL")
        Task { await refresh() }
    }

    private func fetch() async throws -> UsageSnapshot {
        #if DEBUG
        if let demoScenario, let scenario = DemoData.Scenario(rawValue: demoScenario) {
            return DemoData.snapshot(for: scenario)
        }
        #endif
        return try await RelayClient(urlString: relayURL, readToken: readToken).fetch()
    }
}
