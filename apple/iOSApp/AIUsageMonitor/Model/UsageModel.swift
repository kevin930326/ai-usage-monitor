import Foundation
import Observation
import UsageKit

@Observable
@MainActor
final class UsageModel {
    private(set) var snapshot: UsageSnapshot?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    var relayURL: String {
        didSet { UserDefaults.standard.set(relayURL, forKey: Self.relayURLKey) }
    }
    var readToken: String {
        didSet { KeychainStore.write(readToken, account: Self.readTokenAccount) }
    }

    var isConfigured: Bool { !relayURL.isEmpty && !readToken.isEmpty }

    private static let relayURLKey = "relayURL"
    private static let readTokenAccount = "relay-read-token"

    init() {
        relayURL = UserDefaults.standard.string(forKey: Self.relayURLKey) ?? ""
        readToken = KeychainStore.read(Self.readTokenAccount) ?? ""
    }

    func refresh() async {
        guard isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await makeClient().fetch()
            errorMessage = nil
        } catch {
            // 保留上一次成功的資料，只顯示錯誤
            errorMessage = error.localizedDescription
        }
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

    private func makeClient() throws -> RelayClient {
        try RelayClient(urlString: relayURL, readToken: readToken)
    }
}
