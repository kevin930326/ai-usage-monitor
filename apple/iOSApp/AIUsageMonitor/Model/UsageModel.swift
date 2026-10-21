import Foundation
import Observation
import UsageKit

@Observable
@MainActor
final class UsageModel {
    private(set) var snapshot: UsageSnapshot?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var liveActivityRunning = LiveActivityController.isRunning
    private(set) var liveActivityError: String?
    private(set) var isStartingActivity = false

    private(set) var relayURL: String {
        didSet { SharedStore.defaults.set(relayURL, forKey: UsageSource.relayURLKey) }
    }
    private(set) var readToken: String {
        didSet { KeychainStore.write(readToken, account: UsageSource.readTokenAccount) }
    }
    /// 已用／剩餘（FR-17），同時套用到 Live Activity。
    var displayMode: UsageDisplayMode {
        didSet {
            UsageSource.displayMode = displayMode
            SharedStore.publish(nil)
            Task { await updateLiveActivity() }
        }
    }

    /// DEBUG 示範情境（環境變數 AUM_DEMO），有值時只用假資料、不連網。
    let demoScenario: String?

    var isConfigured: Bool { demoScenario != nil || (!relayURL.isEmpty && !readToken.isEmpty) }

    init() {
        relayURL = UsageSource.relayURL
        readToken = UsageSource.readToken
        #if DEBUG
        let demo = DemoData.current
        demoScenario = demo?.rawValue
        displayMode = demo.map(DemoData.mode) ?? UsageSource.displayMode
        // 小工具讀不到 App 的環境變數，示範情境經由 App Group 傳過去
        if SharedStore.demoScenario != demoScenario {
            SharedStore.demoScenario = demoScenario
            SharedStore.publish(nil)
        }
        #else
        demoScenario = nil
        displayMode = UsageSource.displayMode
        #endif
        #if DEBUG
        // 開發用：以環境變數覆寫設定（只在記憶體中），方便在模擬器測試而不必手動輸入密鑰
        let env = ProcessInfo.processInfo.environment
        if let url = env["AUM_RELAY_URL"], !url.isEmpty { relayURL = url }
        if let token = env["AUM_READ_TOKEN"], !token.isEmpty { readToken = token }
        #endif
    }

    func refresh() async {
        guard isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await fetch()
            errorMessage = nil
            SharedStore.publish(snapshot)
            // App 開啟時順便更新卡片（FR-8）
            await updateLiveActivity()
        } catch {
            // 保留上一次成功的資料，只顯示錯誤
            errorMessage = error.localizedDescription
        }
        // 卡片可能已被滑掉或超過 8 小時被系統結束
        liveActivityRunning = LiveActivityController.isRunning
    }

    /// 設定畫面的「儲存」：兩個值都存好後才同步到手錶一次（FR-30）。
    /// 分開送會先送出「新網址＋舊密鑰」，手錶可能短暫顯示「讀取密鑰錯誤」。
    func saveSettings(url: String, token: String) {
        relayURL = url
        readToken = token
        WatchSettingsSync.shared.send(url: url, token: token)
        SharedStore.publish(nil)
    }

    /// 設定畫面的「測試連線」，成功時順便更新主畫面。
    func testConnection(url: String, token: String) async -> String? {
        do {
            let snap = try await RelayClient(urlString: url, readToken: token).fetch()
            snapshot = snap
            errorMessage = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Live Activity（FR-8）

    func startLiveActivity() async {
        // 連點時第二次直接忽略（第一次還在抓資料）
        guard !isStartingActivity else { return }
        isStartingActivity = true
        defer { isStartingActivity = false }
        do {
            let snap = try await fetch()
            snapshot = snap
            SharedStore.publish(snap)
            try await LiveActivityController.start(snapshot: snap, mode: displayMode, demoScenario: demoScenario)
            liveActivityError = nil
        } catch {
            liveActivityError = error.localizedDescription
        }
        liveActivityRunning = LiveActivityController.isRunning
    }

    func restartLiveActivity() async {
        do {
            _ = try await RestartUsageActivityIntent().perform()
            liveActivityError = nil
        } catch {
            liveActivityError = error.localizedDescription
        }
        liveActivityRunning = LiveActivityController.isRunning
    }

    func endLiveActivity() async {
        await LiveActivityController.endAll()
        liveActivityRunning = LiveActivityController.isRunning
    }

    private func updateLiveActivity() async {
        guard let snapshot, LiveActivityController.isRunning else { return }
        await LiveActivityController.update(snapshot: snapshot, mode: displayMode)
    }

    private func fetch() async throws -> UsageSnapshot {
        if demoScenario != nil { return try await UsageSource.fetch(demoScenario: demoScenario) }
        return try await RelayClient(urlString: relayURL, readToken: readToken).fetch()
    }
}
