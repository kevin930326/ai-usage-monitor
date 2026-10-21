import Foundation
import WatchConnectivity

/// 接收 iPhone 以 `updateApplicationContext` 傳來的中繼網址與讀取密鑰（FR-30），
/// 手錶上不需要輸入。iPhone 端見 apple/iOSApp/AIUsageMonitor/Model/WatchSettingsSync.swift。
final class SettingsReceiver: NSObject, WCSessionDelegate {
    private let onSettings: @MainActor (String, String) -> Void

    init(onSettings: @escaping @MainActor (String, String) -> Void) {
        self.onSettings = onSettings
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // 啟用前 iPhone 已送出的最後一份設定
        handle(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    private func handle(_ context: [String: Any]) {
        guard let url = context["relayURL"] as? String, let token = context["readToken"] as? String else { return }
        let onSettings = onSettings
        Task { @MainActor in onSettings(url, token) }
    }
}
