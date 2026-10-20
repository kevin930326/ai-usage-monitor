import Foundation
import UsageKit

/// 選單列 App 與桌面小工具交換資料的位置。
/// 小工具在沙盒中執行，讀不到 `~/Library/Application Support`，所以 App 每次讀到新資料時
/// 複製一份到 App Group 容器。App Group 需要以 Apple 帳號（Team）簽署，否則小工具顯示範例資料。
enum SharedSnapshot {
    static let appGroup = "group.io.github.kevin930326.AIUsageMonitor"

    static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(UsageFileLocator.fileName)
    }

    static func load() -> UsageSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? UsageDecoder.decode(data)
    }

    /// 小工具預覽與尚未取得資料時使用的範例。
    static func sample(now: Date = .now) -> UsageSnapshot {
        UsageSnapshot(updatedAt: now.addingTimeInterval(-120), providers: [
            "claude": ProviderUsage(plan: "Max", windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: 62, resetsAt: now.addingTimeInterval(6000)),
                UsageWindow(id: "weekly", label: "每週", usedPct: 35, resetsAt: now.addingTimeInterval(3 * 86400)),
            ]),
            "codex": ProviderUsage(plan: "Team", windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: 12, resetsAt: now.addingTimeInterval(14400)),
                UsageWindow(id: "weekly", label: "每週", usedPct: 48, resetsAt: now.addingTimeInterval(5 * 86400)),
            ]),
        ])
    }
}
