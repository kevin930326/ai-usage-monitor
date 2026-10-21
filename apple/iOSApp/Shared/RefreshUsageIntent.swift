import AppIntents

/// 卡片上的「更新」按鈕（FR-9）。LiveActivityIntent 由系統在 App 程序中執行，
/// 所以 Widget 擴充不需要網路或 Keychain 權限。
struct RefreshUsageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "更新 AI 用量"
    static let description = IntentDescription("重新讀取用量並更新鎖定畫面卡片。")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await LiveActivityController.refresh()
        return .result()
    }
}
