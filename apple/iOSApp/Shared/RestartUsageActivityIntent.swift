import AppIntents

/// 捷徑動作「重新啟動用量監看」（FR-10）：結束舊卡片並開新卡片。
/// Live Activity 最長 8 小時，搭配捷徑 App 的定時自動化即可整天顯示。
/// 採 LiveActivityIntent，讓系統在 App 程序中執行，背景也能開始新卡片。
struct RestartUsageActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "重新啟動用量監看"
    static let description = IntentDescription("結束目前的用量卡片，抓取最新資料後在鎖定畫面開一張新的。")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await LiveActivityController.restart()
        return .result(dialog: "已重新啟動用量監看")
    }
}

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
