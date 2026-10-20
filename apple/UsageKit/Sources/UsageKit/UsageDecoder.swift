import Foundation

public enum UsageDecodingError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): "資料格式版本 \(v) 不受支援，請更新 App"
        case .malformed: "資料格式錯誤"
        }
    }
}

public enum UsageDecoder {
    public static func decode(_ data: Data) throws -> UsageSnapshot {
        // 先只讀版本號，避免新版格式在完整解析時出現難懂的錯誤
        struct VersionProbe: Decodable {
            let schema_version: Int
        }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            throw UsageDecodingError.malformed
        }
        guard UsageSnapshot.supportedSchemaVersions.contains(probe.schema_version) else {
            throw UsageDecodingError.unsupportedSchema(probe.schema_version)
        }
        do {
            return try jsonDecoder.decode(UsageSnapshot.self, from: data)
        } catch {
            throw UsageDecodingError.malformed
        }
    }

    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
