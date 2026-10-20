import Foundation
import UsageKit

/// 取得用量的唯一入口，App 畫面與 Live Activity 的 Intent 共用。
enum UsageSource {
    static let relayURLKey = "relayURL"
    static let readTokenAccount = "relay-read-token"
    static let displayModeKey = "displayMode"

    static var relayURL: String { UserDefaults.standard.string(forKey: relayURLKey) ?? "" }
    static var readToken: String { KeychainStore.read(readTokenAccount) ?? "" }

    /// 顯示已用或剩餘（FR-17），預設剩餘。
    static var displayMode: UsageDisplayMode {
        get { UserDefaults.standard.string(forKey: displayModeKey).flatMap(UsageDisplayMode.init) ?? .remaining }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: displayModeKey) }
    }

    /// 有示範情境時只回傳假資料，完全不連網；否則以讀取密鑰呼叫中繼。
    static func fetch(demoScenario: String?) async throws -> UsageSnapshot {
        #if DEBUG
        if let demoScenario, let demo = DemoData.Scenario(rawValue: demoScenario) {
            return DemoData.snapshot(for: demo)
        }
        #endif
        return try await RelayClient(urlString: relayURL, readToken: readToken).fetch()
    }
}
