import Foundation

/// 某個服務的某個額度，用來表示「剩餘最少的額度」（`tightestWindow(at:)`）。
public struct ProviderWindow: Equatable, Sendable {
    public var provider: String
    public var window: UsageWindow

    /// 「服務/額度 id」，同一份快照中唯一
    public var key: String { "\(provider)/\(window.id)" }

    public init(provider: String, window: UsageWindow) {
        self.provider = provider
        self.window = window
    }

    /// 畫面上代表這一項的名稱：服務名稱＋額度名稱，例如「Claude 每週」。
    /// 能用服務圖示＋這個名稱表達時，不另外加「剩餘最少」之類的標題。
    public var displayName: String { "\(ProviderInfo.displayName(provider)) \(window.label)" }

    /// VoiceOver 用的完整說法：「剩餘最少的額度：Claude 每週，剩 67%」（已用模式為「已用 33%」）。
    /// 畫面上只放圖示＋名稱，輔助說明仍要說清楚這是剩餘最少的一項。
    public func leastRemainingAccessibilityLabel(mode: UsageDisplayMode = .remaining, at now: Date) -> String {
        let pct = Int(window.displayedPct(mode, at: now).rounded())
        return "剩餘最少的額度：\(displayName)，\(mode == .remaining ? "剩" : "已用") \(pct)%"
    }
}

public extension UsageSnapshot {
    /// 固定順序：已知服務在前，其他依名稱排序。
    static let knownProviderOrder = ["claude", "codex"]

    var orderedProviderKeys: [String] {
        providers.keys.sorted { a, b in
            let ia = Self.knownProviderOrder.firstIndex(of: a) ?? Int.max
            let ib = Self.knownProviderOrder.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }
    }

    /// 所有服務的可見額度中，剩餘最少的一項（FR-15）；同分時取較早重置的。
    /// 不考慮重置時間，畫面上請用 `tightestWindow(at:)`（FR-26）。
    var tightestWindow: ProviderWindow? {
        // 在 distantPast 時沒有額度已重置，結果等同只看 remainingPct
        tightestWindow(at: .distantPast)
    }

    /// 超過門檻沒更新就視為過期（FR-11），例如 Mac 關機。iPhone 與 Mac 用這個。
    static let staleAfter: TimeInterval = 30 * 60

    /// 手錶 App 與錶面複雜功能的過期門檻（FR-11）。手錶約每 30 分鐘背景更新一次，
    /// 實際時間由 watchOS 決定、常會延後；門檻與間隔相同時稍有延後就會轉灰。
    static let watchStaleAfter: TimeInterval = 45 * 60

    /// 資料時間比裝置時間晚（未來）超過同一個門檻也算過期：兩邊時鐘差這麼多時無法判斷資料新舊，
    /// 不能讓 Mac 時鐘快了幾小時的舊資料一直顯示成新的。門檻內的小偏差照常顯示。
    func isStale(now: Date = RenderClock.now, after threshold: TimeInterval = staleAfter) -> Bool {
        abs(now.timeIntervalSince(updatedAt)) > threshold
    }

    /// 收集器沒有啟用任何服務（Mac 上還沒登入 Claude Code 或 Codex CLI）。
    /// 只用其中一個服務時 `providers` 只有一個 key，這是正常狀態，不是錯誤。
    var hasNoProviders: Bool { providers.isEmpty }
}

public enum ProviderInfo {
    /// 沒有啟用任何服務時的提示（`UsageSnapshot.hasNoProviders`）。
    public static let noProvidersTitle = "沒有啟用任何服務"
    public static let noProvidersHint = "在 Mac 登入 Claude Code 或 Codex CLI 後，重新執行收集器的安裝腳本。"

    public static func displayName(_ key: String) -> String {
        switch key {
        case "claude": "Claude"
        case "codex": "Codex"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    /// 兩個字母的文字標示，給沒有空間放服務名稱的純文字場合。
    /// 動態島與錶面改用 UsageKitUI 的 `ProviderIcon`。Claude 與 Codex 都是 C 開頭，只取首字母無法分辨。
    public static func shortName(_ key: String) -> String {
        switch key {
        case "claude": "CL"
        case "codex": "CX"
        default: String(key.prefix(2)).uppercased()
        }
    }
}
