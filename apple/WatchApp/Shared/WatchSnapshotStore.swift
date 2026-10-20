import Foundation
import UsageKit

/// 手錶 App 與錶面複雜功能交換資料的位置（App Group，需以 Team 簽署）。
/// 未簽署時容器不存在，複雜功能顯示「--」。
enum WatchSnapshotStore {
    static let appGroup = "group.io.github.kevin930326.AIUsageMonitor"

    static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("usage.json")
    }

    static func load() -> UsageSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? UsageDecoder.decode(data)
    }

    static func save(_ snapshot: UsageSnapshot) {
        guard let url, let data = try? UsageEncoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
