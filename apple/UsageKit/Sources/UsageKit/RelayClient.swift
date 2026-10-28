import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux 上 URLSession 在這個模組
#endif

public enum RelayError: Error, Equatable, LocalizedError {
    case invalidURL
    case unauthorized
    case noData
    case http(Int)
    case network
    case decoding(UsageDecodingError)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "中繼網址格式不正確"
        case .unauthorized: "讀取密鑰錯誤"
        case .noData: "中繼還沒有資料，請確認 Mac 收集器正在執行"
        case .http(let code): "中繼回應錯誤（HTTP \(code)）"
        case .network: "無法連線到中繼"
        case .decoding(let e): e.errorDescription
        }
    }
}

/// 使用者貼上的中繼網址與密鑰常多帶空白或換行（例如從終端機複製），
/// 密鑰多一個換行就會被中繼判為「讀取密鑰錯誤」，所以儲存與送出前一律去除。
public enum RelayInput {
    public static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 中繼 API 的讀取端（`GET /usage`）。
public struct RelayClient: Sendable {
    public var baseURL: URL
    public var readToken: String
    var session: URLSession

    public init(baseURL: URL, readToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        // 先前存下的密鑰可能帶著換行，這裡也清一次
        self.readToken = RelayInput.clean(readToken)
        self.session = session
    }

    /// 接受使用者輸入的網址字串，補上 https:// 並去掉結尾斜線。
    public init(urlString: String, readToken: String, session: URLSession = .shared) throws {
        var s = RelayInput.clean(urlString)
        // 先補 scheme 再去斜線，否則 "https://" 會被削成 "https:" 再補成 "https://https:"
        if !s.contains("://") { s = "https://" + s }
        guard var components = URLComponents(string: s),
              components.scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw RelayError.invalidURL
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw RelayError.invalidURL }
        self.init(baseURL: url, readToken: readToken, session: session)
    }

    /// 其他電腦的 AI 狀態（ADR-0019 第 2 節，`GET /agents/state`）。中繼沒打開（404）、逾時或任何錯誤時 nil：
    /// 畫面不顯示這一區，額度照常
    public func fetchAgents(localNow: Int64) async -> [RemoteAgent]? {
        var request = URLRequest(url: baseURL.appending(path: "agents/state"))
        request.setValue("Bearer \(readToken)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return RemoteAgents.parseRelay(data, localNow: localNow)
    }

    public func fetch() async throws -> UsageSnapshot {
        var request = URLRequest(url: baseURL.appending(path: "usage"))
        request.setValue("Bearer \(readToken)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayError.network
        }

        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            do {
                return try UsageDecoder.decode(data)
            } catch let e as UsageDecodingError {
                throw RelayError.decoding(e)
            }
        case 401: throw RelayError.unauthorized
        case 404: throw RelayError.noData
        case let code: throw RelayError.http(code)
        }
    }
}
