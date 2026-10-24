import Foundation
import Testing
@testable import UsageKit

struct PairingPayloadTests {
    let token = "r-token-0123456789abcdef"

    @Test func roundTripsTheEncodedForm() throws {
        let payload = try #require(PairingPayload(url: "https://ai-usage-relay.example.workers.dev/", readToken: token))
        #expect(payload.encoded.hasPrefix("aiusage-pair:v1:"))
        #expect(!payload.encoded.contains("="))
        let scanned = try #require(PairingPayload(scanned: payload.encoded))
        #expect(scanned == payload)
        #expect(scanned.url.absoluteString == "https://ai-usage-relay.example.workers.dev")
        #expect(scanned.host == "ai-usage-relay.example.workers.dev")
    }

    /// scripts/render-qr.swift 的輸出（固定字串，兩邊格式改變時這裡會失敗）
    @Test func decodesTheScriptFormat() throws {
        let json = #"{"read":"r-token-0123456789abcdef","url":"https:\/\/relay.example.dev"}"#
        let body = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let payload = try #require(PairingPayload(scanned: "aiusage-pair:v1:" + body))
        #expect(payload.readToken == token)
        #expect(payload.host == "relay.example.dev")
    }

    @Test(arguments: [
        "https://relay.example.dev",                // 沒有前綴
        "aiusage-pair:v2:e30",                      // 版本不對
        "aiusage-pair:v1:!!!",                      // 不是 base64url
        "aiusage-pair:v1:e30",                      // {}：缺欄位
        "aiusage-pair:v1:" + String(repeating: "A", count: 3000), // 過長
    ])
    func rejectsMalformedScans(raw: String) {
        #expect(PairingPayload(scanned: raw) == nil)
    }

    @Test func requiresHTTPSAndAReasonableToken() {
        #expect(PairingPayload(url: "http://relay.example.dev", readToken: token) == nil)
        #expect(PairingPayload(url: "relay.example.dev", readToken: token) == nil)  // 掃描時不補 https://
        #expect(PairingPayload(url: "https://relay.example.dev", readToken: "short") == nil)
        #expect(PairingPayload(url: "https://relay.example.dev", readToken: "has space 0123456789") == nil)
        #expect(PairingPayload(url: "https://relay.example.dev", readToken: "密鑰密鑰密鑰密鑰密鑰密鑰") == nil)
        #expect(PairingPayload(url: "https://relay.example.dev", readToken: String(repeating: "a", count: 257)) == nil)
    }

    /// Codex C-02：網址會存進 UserDefaults，確認畫面只顯示主機名稱
    @Test(arguments: ["https://alice:secret@relay.example.dev", "https://alice@relay.example.dev",
                      "https://relay.example.dev/?token=x", "https://relay.example.dev/#x"])
    func rejectsURLsCarryingCredentialsOrExtras(url: String) {
        #expect(PairingPayload(url: url, readToken: token) == nil)
    }
}

struct PairingCodeTests {
    @Test(arguments: [("7k3m-q9td", "7K3MQ9TD"), ("7K3M Q9TD", "7K3MQ9TD"), ("OIL0-1234", "01101234"), (" 7k3mq9td\n", "7K3MQ9TD")])
    func normalizesUserInput(raw: String, expected: String) {
        #expect(PairingCode.normalize(raw) == expected)
    }

    @Test(arguments: ["7K3M-Q9T", "7K3M-Q9TDX", "7K3M-Q9TU", "7K3M-Q9T#", ""])
    func rejectsInvalidCodes(raw: String) {
        #expect(PairingCode.normalize(raw) == nil)
    }

    @Test func displaysWithAHyphen() {
        #expect(PairingCode.display("7K3MQ9TD") == "7K3M-Q9TD")
    }
}

/// 與 RelayClientTests 共用 StubProtocol，必須在同一個依序執行的 suite 裡
extension RelayClientTests {
    private func body(of request: URLRequest) -> [String: String] {
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    @Test func claimsAReadTokenWithANormalizedCode() async throws {
        StubProtocol.handler = { [self] req in
            #expect(req.url?.absoluteString == "https://relay.example.dev/pair/claim")
            #expect(req.httpMethod == "POST")
            #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(body(of: req) == ["code": "7K3MQ9TD"])
            return (200, Data(#"{"read_token":"r-token-0123456789abcdef"}"#.utf8))
        }
        let client = try await RelayClient.claimPairing(urlString: "relay.example.dev/", code: "7k3m-q9td", session: session)
        #expect(client.readToken == "r-token-0123456789abcdef")
        #expect(client.baseURL.absoluteString == "https://relay.example.dev")
    }

    @Test(arguments: [(403, PairingError.rejected), (404, .unsupported), (500, .http(500))])
    func mapsClaimFailures(status: Int, expected: PairingError) async {
        StubProtocol.handler = { _ in (status, Data()) }
        await #expect(throws: expected) {
            _ = try await RelayClient.claimPairing(urlString: "relay.example.dev", code: "7K3M-Q9TD", session: session)
        }
    }

    @Test func rejectsABadResponseAndBadCodesBeforeSending() async {
        StubProtocol.handler = { _ in (200, Data(#"{"read_token":"x"}"#.utf8)) }
        await #expect(throws: PairingError.invalidResponse) {
            _ = try await RelayClient.claimPairing(urlString: "relay.example.dev", code: "7K3M-Q9TD", session: session)
        }
        StubProtocol.handler = { _ in
            Issue.record("短碼格式不對時不應送出")
            return (200, Data())
        }
        await #expect(throws: PairingError.invalidCode) {
            _ = try await RelayClient.claimPairing(urlString: "relay.example.dev", code: "123", session: session)
        }
        await #expect(throws: RelayError.invalidURL) {
            _ = try await RelayClient.claimPairing(urlString: "alice:secret@relay.example.dev", code: "7K3M-Q9TD", session: session)
        }
        await #expect(throws: RelayError.invalidURL) {
            _ = try await RelayClient.claimPairing(urlString: "relay.example.dev/?x=1", code: "7K3M-Q9TD", session: session)
        }
    }
}
