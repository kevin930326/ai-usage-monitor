import Foundation
import WatchConnectivity

/// 以 `sendMessage` 從 iPhone 取得中繼網址與讀取密鑰（FR-30），手錶上不需要輸入。
/// 不用 application context（系統會另存一份密鑰在 Keychain 以外）。
/// - App 開啟、回到前景或 iPhone 變得可連線時向 iPhone 要設定，iPhone App 會在背景被喚醒回覆。
/// - iPhone 儲存設定時若手錶 App 正開著，會直接送過來（`didReceiveMessage`）。
/// iPhone 端見 apple/iOSApp/AIUsageMonitor/Model/WatchSettingsSync.swift。
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

    /// 向 iPhone 要最新設定；iPhone 不在附近或 session 還沒啟用就略過，下次開啟再試。
    func requestSettings() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["requestSettings": true], replyHandler: { [weak self] reply in
            self?.handle(reply)
        }, errorHandler: nil)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        requestSettings()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        requestSettings()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    private func handle(_ message: [String: Any]) {
        guard let url = message["relayURL"] as? String, let token = message["readToken"] as? String else { return }
        let onSettings = onSettings
        Task { @MainActor in onSettings(url, token) }
    }
}
