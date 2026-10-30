import Foundation

/// 看滑鼠時超標自動降幀（ADR-0016 第 6 節，TASK icons 第 4 部分「超標就降幀」）：每 2 秒算一次這段時間 App 用了多少 CPU，
/// **連續兩段**超過目標才換慢一級（每分鐘的更新、收到 hook 這類一次的尖峰不會降）；降下來後過一陣子試著升回一級，
/// 那一段超標就退回、下次再試的等待加倍（10 → 20 → 40 → 60 秒）。每一級都是螢幕更新率的整數分之一（`rates`）。
/// 很久沒看滑鼠（10 分鐘）就從最快的一級重新開始。
public struct MascotFrameGovernor: Sendable {
    /// 換了一級
    public struct Change: Sendable, Equatable {
        public let from: Int
        public let to: Int
        /// 判斷用的那一段的 CPU（%）
        public let cpu: Double
        /// 是試著升回去（`to > from`）
        public var isTrial: Bool { to > from }
    }

    /// 由快到慢的每秒格數
    public let rates: [Int]
    /// CPU 目標（%，整個 App）
    public let budget: Double
    public private(set) var level = 0
    private var window: (start: Int, cpu: Double)?
    private var last: Int?
    private var over = 0
    private var trial = false
    private var lowSince = 0
    private var backoff = MascotFrameGovernor.firstRetry

    public static let windowMs = 2000
    /// 停頓（眨眼時圖層停掉、由 SwiftUI 畫那一下）在這以內就接著算；更久就重新開始一段
    public static let gapMs = 1500
    public static let firstRetry = 10_000
    public static let maxRetry = 60_000
    public static let forgetMs = 600_000

    public init(rates: [Int], budget: Double) {
        self.rates = rates.isEmpty ? [30] : rates
        self.budget = budget
    }

    public var fps: Int { rates[level] }

    /// 螢幕更新率 `screen` 的整數分之一，介於 `floor` 與 `cap` 之間，由快到慢；沒有時用不超過 cap 的螢幕更新率
    public static func rates(screen: Int, cap: Int, floor: Int) -> [Int] {
        let found = (1...screen).filter { screen % $0 == 0 }.map { screen / $0 }.filter { $0 <= cap && $0 >= floor }
        return found.isEmpty ? [min(cap, screen)] : found
    }

    /// 每一格叫一次：`cpu` 是 App 到目前用掉的 CPU 秒數（只在一段滿了才讀）。換級時回傳那一次的變化
    public mutating func observe(at t: Int, cpu: () -> Double) -> Change? {
        defer { last = t }
        if let last, t - last > Self.forgetMs {
            self = Self(rates: rates, budget: budget)
        } else if let last, t - last > Self.gapMs {
            window = nil
            over = 0
        }
        guard let start = window?.start, let spent = window?.cpu else {
            window = (t, cpu())
            return nil
        }
        guard t - start >= Self.windowMs, rates.count > 1 else { return nil }
        let now = cpu()
        window = (t, now)
        let pct = (now - spent) / (Double(t - start) / 1000) * 100
        let from = fps
        if trial {
            trial = false
            lowSince = t
            guard pct > budget else {
                backoff = Self.firstRetry
                return nil
            }
            level += 1
            backoff = min(backoff * 2, Self.maxRetry)
            return Change(from: from, to: fps, cpu: pct)
        }
        over = pct > budget ? over + 1 : 0
        if over >= 2, level + 1 < rates.count {
            level += 1
            over = 0
            lowSince = t
            return Change(from: from, to: fps, cpu: pct)
        }
        if level > 0, over == 0, t - lowSince >= backoff {
            level -= 1
            trial = true
            return Change(from: from, to: fps, cpu: pct)
        }
        return nil
    }
}
