import Foundation

// 額度通知的判斷（FR-19、ADR-0008 第 5 節「通知」）：剩不到 20%、用得太快、額度重置（從剩不到 20% 恢復）。
// 同一事件只通知一次：每個事件有一個鍵（種類｜服務｜額度｜這一輪的重置時間），送過的鍵由 App 保存。
// 這裡只有純計算；送出通知、保存鍵與設定開關在 Mac App。

public enum QuotaAlertKind: String, CaseIterable, Sendable {
    case low
    case tooFast
    case reset

    public var title: String {
        switch self {
        case .low: "剩不到 20%"
        case .tooFast: "用得太快"
        case .reset: "額度重置"
        }
    }
}

public struct QuotaAlert: Equatable, Sendable {
    public var kind: QuotaAlertKind
    public var provider: String
    public var windowID: String
    /// 去重用的鍵：`種類|服務|額度|重置時間（epoch 秒，不明時 0）`
    public var key: String
    public var title: String
    public var body: String

    /// 點通知打開面板時要亮一下的卡片：額度卡片（重置則是時間軸）
    public var cardID: String { kind == .reset ? "resets" : "quota" }
}

public enum QuotaAlerts {
    /// 送過的鍵保留天數（最長的額度是 7 天，多留一天）
    public static let keepDays: TimeInterval = 8 * 86400

    /// 目前快照中所有成立的事件（不論設定開關，呼叫端只送出開啟的種類，但全部記錄，
    /// 因為「重置」要知道這一輪曾經剩不到 20%）。已經在 `sent` 裡的事件不再回傳。
    public static func detect(snapshot: UsageSnapshot, now: Date, sent: Set<String>) -> [QuotaAlert] {
        guard !snapshot.isStale(now: now) else { return [] }
        var result: [QuotaAlert] = []
        for provider in snapshot.orderedProviderKeys {
            guard let usage = snapshot.providers[provider], usage.error == nil else { continue }
            for window in usage.visibleWindows {
                let item = ProviderWindow(provider: provider, window: window)
                let cycle = window.resetsAt.map { Int64($0.timeIntervalSince1970) } ?? 0
                func key(_ kind: QuotaAlertKind, _ epoch: Int64 = cycle) -> String { "\(kind.rawValue)|\(provider)|\(window.id)|\(epoch)" }

                // 重置：先前某一輪剩不到 20%，那一輪的重置時間已過
                for old in lowCycles(in: sent, provider: provider, windowID: window.id) where old > 0 && Double(old) <= now.timeIntervalSince1970 {
                    let k = key(.reset, old)
                    guard !sent.contains(k) else { continue }
                    result.append(QuotaAlert(kind: .reset, provider: provider, windowID: window.id, key: k,
                                             title: "\(item.displayName) 已重置", body: "額度已恢復，可以繼續使用"))
                }
                guard !window.isReset(at: now) else { continue }
                let remaining = window.effectiveRemainingPct(at: now)
                if remaining < UsageSeverity.criticalBelow, !sent.contains(key(.low)) {
                    result.append(QuotaAlert(kind: .low, provider: provider, windowID: window.id, key: key(.low),
                                             title: "\(item.displayName) 剩不到 20%",
                                             body: "剩 \(Int(remaining.rounded()))%" + resetText(window, now: now)))
                }
                if let pace = UsagePace(window: window, stale: false, now: now), let exhausts = pace.exhaustsAt,
                   !sent.contains(key(.tooFast)) {
                    let when = ResetCountdown.text(until: exhausts, now: now).map { "約 \($0)後用完" } ?? "很快就會用完"
                    result.append(QuotaAlert(kind: .tooFast, provider: provider, windowID: window.id, key: key(.tooFast),
                                             title: "\(item.displayName) 用得太快",
                                             body: "照目前速度\(when)，比重置早" + resetText(window, now: now)))
                }
            }
        }
        return result
    }

    /// 去掉過期的鍵（重置時間早於 `keepDays` 以前）
    public static func pruned(_ sent: Set<String>, now: Date) -> Set<String> {
        let cutoff = Int64(now.addingTimeInterval(-keepDays).timeIntervalSince1970)
        return sent.filter { key in
            guard let epoch = key.split(separator: "|").last.flatMap({ Int64($0) }) else { return false }
            return epoch == 0 || epoch >= cutoff
        }
    }

    /// 記錄中這個額度剩不到 20% 的各輪重置時間
    static func lowCycles(in sent: Set<String>, provider: String, windowID: String) -> [Int64] {
        let prefix = "\(QuotaAlertKind.low.rawValue)|\(provider)|\(windowID)|"
        return sent.filter { $0.hasPrefix(prefix) }.compactMap { Int64($0.dropFirst(prefix.count)) }.sorted()
    }

    private static func resetText(_ window: UsageWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt, let text = ResetCountdown.text(until: resetsAt, now: now) else { return "" }
        return "，\(text)後重置"
    }
}
