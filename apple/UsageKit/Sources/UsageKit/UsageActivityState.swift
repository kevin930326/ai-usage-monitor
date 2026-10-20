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

    public static let maxErrorLength = 60
    /// ActivityKit 的狀態大小上限
    public static let maxEncodedBytes = 4096

    public init(providers: [Provider], updatedAt: Date, mode: UsageDisplayMode) {
        self.providers = providers
        self.updatedAt = updatedAt
        self.mode = mode
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
    /// 取「資料過期時間」與「下一個尚未到的重置時間」中較早者。
    public func staleDate(now: Date = .now) -> Date {
        let expiry = updatedAt.addingTimeInterval(UsageSnapshot.staleAfter)
        let nextReset = providers
            .flatMap(\.windows)
            .compactMap(\.resetsAt)
            .filter { $0 > now }
            .min()
        guard let nextReset else { return expiry }
        return min(expiry, nextReset)
    }

    public func encodedSize() throws -> Int {
        try JSONEncoder().encode(self).count
    }
}
