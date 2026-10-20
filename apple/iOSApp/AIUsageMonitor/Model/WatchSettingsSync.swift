import Foundation
import WatchConnectivity

/// 把中繼網址與讀取密鑰送到配對的 Apple Watch（FR-30），手錶上不需要輸入。
/// 使用 `updateApplicationContext`：只保留最後一份，手錶下次啟動時也收得到。
/// 手錶端見 apple/WatchApp/AIUsageWatch/SettingsReceiver.swift。
final class WatchSettingsSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSettingsSync()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(url: String, token: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(["relayURL": url, "readToken": token])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let url = UsageSource.relayURL
        let token = UsageSource.readToken
        guard !url.isEmpty, !token.isEmpty else { return }
        send(url: url, token: token)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 換了一支手錶：重新啟用以連上新的手錶
        session.activate()
    }
}
