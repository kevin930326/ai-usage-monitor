import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// iPhone 配對（ADR-0012）：Mac 終端機顯示的 QR 碼內容。
/// 格式 `aiusage-pair:v1:<base64url(JSON {"url", "read"})>`，只含中繼網址與**讀取密鑰**。
public struct PairingPayload: Equatable, Sendable {
    public static let prefix = "aiusage-pair:v1:"
    /// QR 碼最多約 2.9 KB；超過這個長度一定不是我們產生的
    static let maxLength = 2048

    public let url: URL
    public let readToken: String

    /// 確認畫面只顯示主機名稱，不顯示密鑰
    public var host: String { url.host ?? "" }

    public init?(url: String, readToken: String) {
        guard url.hasPrefix("https://"), let relay = try? RelayClient(urlString: url, readToken: readToken),
              Self.isValidToken(readToken) else { return nil }
        self.url = relay.baseURL
        self.readToken = readToken
    }

    /// 掃描到的字串；格式不符就回傳 nil（呼叫端不顯示內容）
    public init?(scanned: String) {
        guard scanned.count <= Self.maxLength, scanned.hasPrefix(Self.prefix) else { return nil }
        var body = String(scanned.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, let read = object["read"] as? String else { return nil }
        self.init(url: url, readToken: read)
    }

    /// 與 `scripts/render-qr.swift` 產生的格式相同（測試與預覽用）
    public var encoded: String {
        let data = (try? JSONSerialization.data(withJSONObject: ["url": url.absoluteString, "read": readToken], options: [.sortedKeys])) ?? Data()
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + base64
    }

    /// 讀取密鑰：16～256 個可見 ASCII（不含空白）
    public static func isValidToken(_ token: String) -> Bool {
        (16...256).contains(token.utf8.count) && token.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}

/// 一次性短碼（ADR-0012）：8 個 Crockford base32 字元，顯示成 `XXXX-XXXX`。
public enum PairingCode {
    static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 8

    /// 忽略大小寫、空白與連字號，`O`→`0`、`I`／`L`→`1`；不是 8 個合法字元就回傳 nil
    public static func normalize(_ input: String) -> String? {
        let mapped = input.uppercased().compactMap { ch -> Character? in
            switch ch {
            case " ", "-", "\t", "\n": nil
            case "O": "0"
            case "I", "L": "1"
            default: ch
            }
        }
        guard mapped.count == length, mapped.allSatisfy(alphabet.contains) else { return nil }
        return String(mapped)
    }

    public static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        return "\(code.prefix(4))-\(code.suffix(4))"
    }
}

public enum PairingError: Error, Equatable, LocalizedError {
    case invalidCode
    /// 錯誤、到期或沒有短碼（中繼不區分）
    case rejected
    /// 舊中繼沒有 `/pair/claim`
    case unsupported
    case network
    case invalidResponse
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCode: "短碼是 8 個英數字（例如 7K3M-Q9TD）"
        case .rejected: "短碼錯誤或已過期，請在 Mac 重新產生"
        case .unsupported: "中繼還不支援短碼，改用 QR 碼"
        case .network: "無法連線到中繼"
        case .invalidResponse: "中繼回應的格式不正確"
        case .http(let code): "中繼回應錯誤（HTTP \(code)）"
        }
    }
}

extension RelayClient {
    /// 以短碼向中繼兌換讀取密鑰（`POST /pair/claim`，不需要密鑰），成功時回傳可以直接使用的 client。
    public static func claimPairing(urlString: String, code: String, session: URLSession = .shared) async throws -> RelayClient {
        guard let normalized = PairingCode.normalize(code) else { throw PairingError.invalidCode }
        let base = try RelayClient(urlString: urlString, readToken: "", session: session)
        var request = URLRequest(url: base.baseURL.appending(path: "pair/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": normalized])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PairingError.network
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = object["read_token"] as? String, PairingPayload.isValidToken(token) else {
                throw PairingError.invalidResponse
            }
            return RelayClient(baseURL: base.baseURL, readToken: token, session: session)
        case 403: throw PairingError.rejected
        case 404: throw PairingError.unsupported
        case let status: throw PairingError.http(status)
        }
    }
}
