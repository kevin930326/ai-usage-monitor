import Foundation
import Observation
import UsageKit
import WidgetKit

@Observable
@MainActor
final class WatchModel {
    private(set) var snapshot: UsageSnapshot?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

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
        do {
            let snapshot = try await fetch()
            self.snapshot = snapshot
            errorMessage = nil
            WatchSnapshotStore.save(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// iPhone 傳來的中繼設定（FR-30）。密鑰只存在 Keychain（sendMessage 不會被系統保存）。
    private func apply(url rawURL: String, token rawToken: String) {
        // 較舊的 iPhone App 可能送來帶換行的值，存之前再清一次
        let url = RelayInput.clean(rawURL), token = RelayInput.clean(rawToken)
        guard url != relayURL || token != readToken else { return }
        relayURL = url
        readToken = token
        UserDefaults.standard.set(url, forKey: "relayURL")
        KeychainStore.write(token, account: "relay-read-token")
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
