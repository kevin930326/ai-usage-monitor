import Foundation

/// Keychain 寫入的步驟。Security framework 的呼叫由呼叫端以閉包提供（iOS／watchOS 的 `KeychainStore`），
/// 這裡只決定呼叫順序與如何處理 OSStatus，以便在測試中模擬失敗。
public struct KeychainOperations {
    /// 更新既有項目的值（`SecItemUpdate`）
    public var update: (Data) -> Int32
    /// 新增項目（`SecItemAdd`）
    public var add: (Data) -> Int32
    /// 刪除項目（`SecItemDelete`）
    public var delete: () -> Int32

    public init(update: @escaping (Data) -> Int32, add: @escaping (Data) -> Int32, delete: @escaping () -> Int32) {
        self.update = update
        self.add = add
        self.delete = delete
    }
}

/// Keychain 操作失敗，`status` 為 OSStatus。
public struct KeychainWriteError: LocalizedError, Equatable {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }

    public var errorDescription: String? { "無法把密鑰存入 Keychain（錯誤 \(status)）" }
}

public enum KeychainWrite {
    // Security framework 的 OSStatus（Linux 沒有這個 framework，測試用相同數值）
    public static let success: Int32 = 0             // errSecSuccess
    public static let itemNotFound: Int32 = -25300   // errSecItemNotFound
    public static let duplicateItem: Int32 = -25299  // errSecDuplicateItem

    /// 有值時先更新，沒有既有項目才新增；空字串刪除。不先刪再加：新增失敗時原本的密鑰還在。
    /// 任何失敗都丟出錯誤，讓呼叫端不要把沒存成功的值當成已儲存（例如同步到手錶）。
    public static func write(_ value: String, using ops: KeychainOperations) throws(KeychainWriteError) {
        guard !value.isEmpty else {
            let status = ops.delete()
            guard status == success || status == itemNotFound else { throw KeychainWriteError(status: status) }
            return
        }
        let data = Data(value.utf8)
        var status = ops.update(data)
        if status == itemNotFound {
            status = ops.add(data)
        }
        guard status == success else { throw KeychainWriteError(status: status) }
    }
}
