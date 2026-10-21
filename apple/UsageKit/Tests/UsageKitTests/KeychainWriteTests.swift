import Foundation
import Testing
@testable import UsageKit

/// C-05：寫入失敗時不能弄丟原本的密鑰，也要讓呼叫端知道失敗。
@Suite struct KeychainWriteTests {
    /// 記憶體中的假 Keychain，可指定某個操作回傳錯誤
    final class FakeKeychain {
        var stored: Data?
        var failAdd: Int32?
        var failUpdate: Int32?
        var failDelete: Int32?

        var ops: KeychainOperations {
            KeychainOperations(
                update: { data in
                    if let status = self.failUpdate { return status }
                    guard self.stored != nil else { return KeychainWrite.itemNotFound }
                    self.stored = data
                    return KeychainWrite.success
                },
                add: { data in
                    if let status = self.failAdd { return status }
                    guard self.stored == nil else { return KeychainWrite.duplicateItem }
                    self.stored = data
                    return KeychainWrite.success
                },
                delete: {
                    if let status = self.failDelete { return status }
                    guard self.stored != nil else { return KeychainWrite.itemNotFound }
                    self.stored = nil
                    return KeychainWrite.success
                }
            )
        }

        var value: String? { stored.map { String(decoding: $0, as: UTF8.self) } }
    }

    static let interactionNotAllowed: Int32 = -25308

    @Test func addsWhenMissing() throws {
        let keychain = FakeKeychain()
        try KeychainWrite.write("new", using: keychain.ops)
        #expect(keychain.value == "new")
    }

    @Test func replacesExistingValue() throws {
        let keychain = FakeKeychain()
        keychain.stored = Data("old".utf8)
        try KeychainWrite.write("new", using: keychain.ops)
        #expect(keychain.value == "new")
    }

    @Test func failedWriteKeepsOldValueAndThrows() {
        let keychain = FakeKeychain()
        keychain.stored = Data("old".utf8)
        keychain.failUpdate = Self.interactionNotAllowed
        keychain.failAdd = Self.interactionNotAllowed
        #expect(throws: KeychainWriteError(status: Self.interactionNotAllowed)) {
            try KeychainWrite.write("new", using: keychain.ops)
        }
        #expect(keychain.value == "old")
    }

    @Test func failedAddOfNewItemThrows() {
        let keychain = FakeKeychain()
        keychain.failAdd = Self.interactionNotAllowed
        #expect(throws: KeychainWriteError(status: Self.interactionNotAllowed)) {
            try KeychainWrite.write("new", using: keychain.ops)
        }
    }

    @Test func emptyValueDeletes() throws {
        let keychain = FakeKeychain()
        keychain.stored = Data("old".utf8)
        try KeychainWrite.write("", using: keychain.ops)
        #expect(keychain.value == nil)
        // 本來就沒有也算成功
        try KeychainWrite.write("", using: keychain.ops)
    }

    @Test func failedDeleteThrows() {
        let keychain = FakeKeychain()
        keychain.stored = Data("old".utf8)
        keychain.failDelete = Self.interactionNotAllowed
        #expect(throws: KeychainWriteError(status: Self.interactionNotAllowed)) {
            try KeychainWrite.write("", using: keychain.ops)
        }
    }
}
