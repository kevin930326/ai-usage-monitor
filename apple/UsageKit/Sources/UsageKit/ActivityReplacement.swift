import Foundation

/// 換 Live Activity 卡片的順序（FR-8、FR-10）：先開新卡片，成功後才結束其他卡片。
/// 開卡失敗（使用者關閉即時動態、超過系統上限等）時舊卡片留著，鎖定畫面不會變成沒有卡片。
/// ActivityKit 無法在單元測試中使用，所以把順序抽到這裡測試。
public enum ActivityReplacement {
    /// 在呼叫端的 actor 上執行（App 端是 MainActor），ActivityKit 的 Activity 不必跨 actor 傳遞。
    public static func replace<Card>(
        isolation: isolated (any Actor)? = #isolation,
        start: () async throws -> Card,
        endOthers: (Card) async -> Void
    ) async throws -> Card {
        let card = try await start()
        await endOthers(card)
        return card
    }
}
