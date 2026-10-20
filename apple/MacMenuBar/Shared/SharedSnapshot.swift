import Foundation
import Security
import UsageKit

/// 選單列 App 與桌面小工具交換資料的位置。
/// 小工具在沙盒中執行，讀不到 `~/Library/Application Support`，所以 App 每次讀到新資料時
/// 複製一份到 App Group 容器。App Group 需要以 Apple 帳號（Team）簽署並在 project.yml 加入
/// entitlement（見 README），否則 App 不寫入、小工具顯示範例資料。
enum SharedSnapshot {
    static let appGroup = "group.io.github.kevin930326.AIUsageMonitor"

    /// 目前程序是否有這個 App Group 的 entitlement。macOS 上 `containerURL` 一律回傳路徑，
    /// 不能用它判斷；未簽署（Sign to Run Locally）的建置沒有 entitlement。
    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String]
        else { return false }
        return groups.contains(appGroup)
    }()

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
