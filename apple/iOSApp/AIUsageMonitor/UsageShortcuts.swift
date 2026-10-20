import AppIntents

/// 捷徑 App 與 Siri 的「重新啟動用量監看」（FR-10）。只放在 App target：
/// Shared/ 也會編進 Widget 擴充，AppShortcutsProvider 不能出現在擴充裡。
struct UsageShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RestartUsageActivityIntent(),
            phrases: [
                "重新啟動\(.applicationName)",
                "用\(.applicationName)重新啟動用量監看",
                "Restart \(.applicationName)",
            ],
            shortTitle: "重新啟動用量監看",
            systemImageName: "arrow.clockwise.circle"
        )
    }
}
