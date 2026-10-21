import Foundation
import Security
import UsageKit

/// 讀取密鑰只存在 Keychain，不放 UserDefaults（NFR-1）。
enum KeychainStore {
    private static let service = "io.github.kevin930326.AIUsageMonitor"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 空字串刪除密鑰。失敗時丟出 `KeychainWriteError`，原本的密鑰保持不變（順序見 `KeychainWrite`）。
    static func write(_ value: String, account: String) throws(KeychainWriteError) {
        let base = query(account)
        // 第一次解鎖後背景也能讀，之後 Live Activity 的 Intent 會在背景抓資料
        let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try KeychainWrite.write(value, using: KeychainOperations(
            update: { data in
                SecItemUpdate(base as CFDictionary, [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: accessible,
                ] as CFDictionary)
            },
            add: { data in
                var add = base
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = accessible
                return SecItemAdd(add as CFDictionary, nil)
            },
            delete: { SecItemDelete(base as CFDictionary) }
        ))
    }
}
