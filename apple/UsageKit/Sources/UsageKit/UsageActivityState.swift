import Foundation

/// Live Activity 的內容狀態（ActivityKit `ContentState` 使用），App 與 Widget 共用。
///
/// 只保留畫面需要的欄位：可見額度、各服務錯誤、更新時間、顯示模式。
/// ActivityKit 限制狀態編碼後不超過 4KB，因此錯誤訊息會截短。
public struct UsageActivityState: Codable, Hashable, Sendable {
    public struct Provider: Codable, Hashable, Sendable, Identifiable {
        public var key: String
        public var plan: String?
        public var error: String?
        public var windows: [UsageWindow]

        public var id: String { key }
        public var displayName: String { ProviderInfo.displayName(key) }
    }

    public var providers: [Provider]
    public var updatedAt: Date
    public var mode: UsageDisplayMode
    /// 「更新」按鈕抓不到新資料的原因。資料沿用上一份，頁尾在更新時間後加上這段；下次成功就清掉。
    /// 沒有這個欄位的舊版狀態解碼為 nil。
    public private(set) var refreshError: String?

    public static let maxErrorLength = 60
    /// ActivityKit 的狀態大小上限
    public static let maxEncodedBytes = 4096

    public init(providers: [Provider], updatedAt: Date, mode: UsageDisplayMode) {
        self.providers = providers
        self.updatedAt = updatedAt
        self.mode = mode
    }

    /// 同一份資料加上（或清掉）更新失敗的原因，訊息截短以控制大小。
    public func withRefreshError(_ message: String?) -> UsageActivityState {
        var state = self
        state.refreshError = message.map { String($0.prefix(Self.maxErrorLength)) }
        return state
    }

    /// 從快照建立：依固定順序排列服務，只保留可見額度（FR-14）。
    public init(snapshot: UsageSnapshot, mode: UsageDisplayMode) {
        self.init(
            providers: snapshot.orderedProviderKeys.compactMap { key in
                guard let usage = snapshot.providers[key] else { return nil }
                return Provider(
                    key: key,
                    plan: usage.plan,
                    error: usage.error.map { String($0.prefix(Self.maxErrorLength)) },
                    windows: usage.visibleWindows
                )
            },
            updatedAt: snapshot.updatedAt,
            mode: mode
        )
    }

    /// 還原成快照，以便重用 UsageKit 的排序與挑選邏輯。
    public var snapshot: UsageSnapshot {
        UsageSnapshot(updatedAt: updatedAt, providers: Dictionary(uniqueKeysWithValues: providers.map {
            ($0.key, ProviderUsage(plan: $0.plan, error: $0.error, windows: $0.windows))
        }))
    }

    /// 最吃緊的額度（FR-15），已重置的額度視為剩餘 100%（FR-26）。
    public func tightest(at now: Date = .now) -> ProviderWindow? {
        snapshot.tightestWindow(at: now)
    }

    /// 超過 30 分鐘沒更新（FR-11）。
    public func isStale(at now: Date = .now) -> Bool {
        snapshot.isStale(now: now)
    }

    /// 有服務失敗、但至少有一個服務正常（FR-12）。
    public var hasPartialFailure: Bool {
        providers.contains { $0.error != nil } && providers.contains { $0.error == nil }
    }

    /// 交給 ActivityKit 的 `staleDate`：Live Activity 不會依時間自動重繪，
    /// 系統在這個時間點把卡片標為 stale 並重繪，畫面才會改成灰色或「已重置」。
    /// 每份內容只會重繪這一次，App 也沒有在背景更新卡片，所以資料過期時間還沒到時一律給它：
    /// 若給較早的重置時間，重置後就沒有事件讓卡片在過期時轉灰。過期前就重置的額度，
    /// 在過期那次重繪時一併顯示「已重置」（最多晚 30 分鐘）。
    /// 過期時間已過時改給下一個尚未到的重置時間，都已過去時回傳 nil。
    /// 給過去的時間會讓系統直接把卡片從鎖定畫面拿掉，而畫面本身已會依 `updatedAt` 顯示「資料已過期」。
    public func staleDate(now: Date = .now) -> Date? {
        let expiry = updatedAt.addingTimeInterval(UsageSnapshot.staleAfter)
        if expiry > now { return expiry }
        return providers.flatMap(\.windows).compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    public func encodedSize() throws -> Int {
        try JSONEncoder().encode(self).count
    }
}
