import Foundation
import UsageKit
import WidgetKit

/// App 與主畫面／鎖定畫面小工具交換資料的位置（App Group）。
/// 免費 Apple ID（Personal Team）的佈建描述檔也包含 App Group 與 Keychain 共享。
/// 讀取密鑰仍只在 Keychain：兩個 target 的 `keychain-access-groups` 都是 App 自己的
/// application identifier，舊版寫入的密鑰不必搬移，小工具就讀得到（NFR-1）。
enum SharedStore {
    static let appGroup = "group.io.github.kevin930326.AIUsageMonitor"
    /// 主畫面與鎖定畫面小工具的 kind，加入後不能更改
    static let widgetKind = "UsageHomeWidget"

    /// 中繼網址與顯示模式。舊版存在 App 自己的 UserDefaults，第一次使用時複製過來。
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let shared = UserDefaults(suiteName: appGroup) else { return .standard }
        for key in [UsageSource.relayURLKey, UsageSource.displayModeKey]
        where shared.object(forKey: key) == nil {
            if let value = UserDefaults.standard.object(forKey: key) { shared.set(value, forKey: key) }
        }
        return shared
    }()

    private static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(UsageFileLocator.fileName)
    }

    /// 最後一次成功取得的資料，小工具抓不到中繼時顯示這份。
    static func loadSnapshot() -> UsageSnapshot? {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? UsageDecoder.decode(data)
    }

    static func saveSnapshot(_ snapshot: UsageSnapshot) {
        guard let snapshotURL, let data = try? UsageEncoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    /// App 取得新資料或改了設定時呼叫：存一份給小工具並要求重新整理。
    /// App 在前景時的重新整理不扣 WidgetKit 的每日次數；背景只有捷徑與卡片上的「更新」會呼叫（每天約 5 次）。
    static func publish(_ snapshot: UsageSnapshot?) {
        if let snapshot { saveSnapshot(snapshot) }
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    #if DEBUG
    /// 示範情境：小工具在另一個程序，讀不到 App 的環境變數，由 App 寫進 App Group。
    private static let demoScenarioKey = "demoScenario"

    static var demoScenario: String? {
        get { defaults.string(forKey: demoScenarioKey) }
        set { defaults.set(newValue, forKey: demoScenarioKey) }
    }
    #endif
}
