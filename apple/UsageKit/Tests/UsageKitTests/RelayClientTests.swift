import Foundation
import Testing
@testable import UsageKit

/// 攔截 URLSession 請求，回傳預先設定的回應。
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (status, data) = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// handler 是共用的靜態變數，測試需依序執行
@Suite(.serialized) struct RelayClientTests {
    let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }()

    func client() throws -> RelayClient {
        try RelayClient(urlString: "relay.example.dev/", readToken: "r-token", session: session)
    }

    @Test func sendsBearerTokenToUsageEndpoint() async throws {
        StubProtocol.handler = { req in
            #expect(req.url?.absoluteString == "https://relay.example.dev/usage")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer r-token")
            return (200, Data(sampleJSON.utf8))
        }
        let snap = try await client().fetch()
        #expect(snap.providers.count == 2)
    }

    @Test(arguments: [(401, RelayError.unauthorized), (404, .noData), (500, .http(500))])
    func mapsHTTPErrors(status: Int, expected: RelayError) async throws {
        StubProtocol.handler = { _ in (status, Data()) }
        await #expect(throws: expected) { try await client().fetch() }
    }

    @Test func mapsNetworkFailure() async throws {
        StubProtocol.handler = nil
        await #expect(throws: RelayError.network) { try await client().fetch() }
    }

    @Test func mapsUnsupportedSchema() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"schema_version":2,"updated_at":"x","providers":{}}"#.utf8)) }
        await #expect(throws: RelayError.decoding(.unsupportedSchema(2))) { try await client().fetch() }
    }

    @Test(arguments: ["http://insecure.example", "", "https://"])
    func rejectsInvalidURLs(url: String) {
        #expect(throws: RelayError.invalidURL) {
            try RelayClient(urlString: url, readToken: "t")
        }
    }
}
