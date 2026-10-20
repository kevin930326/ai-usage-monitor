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

/// 中繼 API 的讀取端（`GET /usage`）。
public struct RelayClient: Sendable {
    public var baseURL: URL
    public var readToken: String
    var session: URLSession

    public init(baseURL: URL, readToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.readToken = readToken
        self.session = session
    }

    /// 接受使用者輸入的網址字串，補上 https:// 並去掉結尾斜線。
    public init(urlString: String, readToken: String, session: URLSession = .shared) throws {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
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
