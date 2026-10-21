import Foundation
import WatchConnectivity

/// 把中繼網址與讀取密鑰送到配對的 Apple Watch（FR-30），手錶上不需要輸入。
/// 只用 `sendMessage`（即時傳送、系統不保存），不用 application context：
/// application context 會被系統存在兩端 App 的容器中，讀取密鑰會多一份在 Keychain 以外。
/// - 手錶 App 開啟時會向 iPhone 要設定（`didReceiveMessage` 的 replyHandler 回覆），
///   iPhone App 沒在執行時系統會在背景喚醒它。
/// - iPhone 儲存設定時，若手錶 App 正開著（`isReachable`）就直接送過去。
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
        guard session.activationState == .activated, session.isWatchAppInstalled, session.isReachable else { return }
        // 送不到沒關係：手錶下次開啟時會自己來要
        session.sendMessage(Self.settingsMessage(url: url, token: token), replyHandler: nil, errorHandler: nil)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        clearLegacyContext(session)
    }

    /// 手錶 App 開啟時來要設定。iPhone 還沒設定時回空字典，手錶維持「請在 iPhone 設定」。
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[Self.requestKey] as? Bool == true else { return replyHandler([:]) }
        let url = UsageSource.relayURL
        let token = UsageSource.readToken
        replyHandler(url.isEmpty || token.isEmpty ? [:] : Self.settingsMessage(url: url, token: token))
    }

    /// 配對了另一支手錶或手錶 App 剛安裝：清掉舊版留下的 context
    func sessionWatchStateDidChange(_ session: WCSession) {
        clearLegacyContext(session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 換了一支手錶：重新啟用以連上新的手錶
        session.activate()
    }

    /// 舊版以 application context 傳送，系統會一直保留最後一份（含讀取密鑰）。
    /// 以空的 context 覆蓋，兩端保存的副本都會被取代。
    private func clearLegacyContext(_ session: WCSession) {
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              !session.applicationContext.isEmpty else { return }
        try? session.updateApplicationContext([:])
    }

    /// 手錶要設定時送的鍵，見 SettingsReceiver.requestSettings()
    static let requestKey = "requestSettings"

    private static func settingsMessage(url: String, token: String) -> [String: Any] {
        ["relayURL": url, "readToken": token]
    }
}
