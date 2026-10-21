import Foundation

/// iPhone 與 Apple Watch 之間以 WatchConnectivity `sendMessage` 交換中繼設定（FR-30）的訊息格式。
/// 兩端的 `WCSession` delegate 只負責收發；要送什麼、收到的能不能用都在這裡決定，所以可以單元測試。
///
/// - 手錶 → iPhone：`request`（開啟、回到前景、iPhone 變得可連線時）。
/// - iPhone → 手錶：`settings(url:token:)`，作為 `request` 的回覆，或 iPhone 儲存設定時直接推送。
/// 不用 application context：系統會把它存在兩端 App 的容器中，讀取密鑰會多一份在 Keychain 以外。
public enum WatchSettingsMessage {
    public static let requestKey = "requestSettings"
    static let urlKey = "relayURL"
    static let tokenKey = "readToken"

    /// 手錶向 iPhone 要設定的訊息。
    public static var request: [String: Any] { [requestKey: true] }

    public static func isRequest(_ message: [String: Any]) -> Bool {
        message[requestKey] as? Bool == true
    }

    /// iPhone 送給手錶的設定。任一為空時回空字典：手錶維持「請在 iPhone 設定」，不會把空值寫進 Keychain。
    public static func settings(url: String, token: String) -> [String: Any] {
        let url = RelayInput.clean(url), token = RelayInput.clean(token)
        guard !url.isEmpty, !token.isEmpty else { return [:] }
        return [urlKey: url, tokenKey: token]
    }

    /// iPhone 回覆手錶的要求：不是要設定的訊息、或 iPhone 還沒設定時回空字典。
    public static func reply(to message: [String: Any], url: String, token: String) -> [String: Any] {
        guard isRequest(message) else { return [:] }
        return settings(url: url, token: token)
    }

    /// 手錶解析收到的設定。缺任一鍵、型別不對或清掉空白後為空都回 nil（不套用）。
    /// 較舊的 iPhone App 可能送來帶換行的值，這裡先清一次。
    public static func parse(_ message: [String: Any]) -> (url: String, token: String)? {
        guard let rawURL = message[urlKey] as? String, let rawToken = message[tokenKey] as? String else { return nil }
        let url = RelayInput.clean(rawURL), token = RelayInput.clean(rawToken)
        guard !url.isEmpty, !token.isEmpty else { return nil }
        return (url, token)
    }

    /// 舊版以 application context 傳送，系統會一直保留最後一份（含讀取密鑰）；
    /// 配對且裝了手錶 App、session 已啟用、而且真的有殘留時，才以空的 context 覆蓋。
    public static func shouldClearLegacyContext(activated: Bool, paired: Bool, watchAppInstalled: Bool,
                                                contextIsEmpty: Bool) -> Bool {
        activated && paired && watchAppInstalled && !contextIsEmpty
    }
}
