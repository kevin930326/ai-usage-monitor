#if DEBUG
import Foundation
import UsageKit

/// 截圖與測試用的假資料（只在 DEBUG 版本存在）。時間以呼叫當下為基準，每次結果一致。
/// 以環境變數 `AUM_DEMO=<情境>` 啟動 App 即進入示範模式，不會連線中繼。
enum DemoData {
    enum Scenario: String, CaseIterable {
        case normal   // 兩個服務都正常
        case stale    // 45 分鐘前的資料（FR-11）
        case error    // Codex 失敗、Claude 正常（FR-12）
        case reset    // Claude 5 小時的重置時間已過（FR-26）
        case used     // 顯示已用 %（FR-17）
        case codex    // Codex 剩最少：動態島與錶面顯示 Codex 圖示
        case claudeOnly = "claude-only"  // 只用 Claude：收集器沒有啟用 Codex
        case codexOnly = "codex-only"    // 只用 Codex：收集器沒有啟用 Claude
        case noProviders = "none"  // 收集器沒有啟用任何服務
    }

    static var current: Scenario? {
        ProcessInfo.processInfo.environment["AUM_DEMO"].flatMap(Scenario.init)
    }

    static func mode(for scenario: Scenario) -> UsageDisplayMode {
        scenario == .used ? .used : .remaining
    }

    static func snapshot(for scenario: Scenario, now: Date = RenderClock.now) -> UsageSnapshot {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        let updatedAt: Date = switch scenario {
        case .stale: at(-45)
        case .reset: at(-20)
        default: at(-1)
        }
        let claude = ProviderUsage(plan: "Max", windows: [
            UsageWindow(id: "five_hour", label: "5 小時", usedPct: scenario == .reset ? 88 : 62,
                        resetsAt: scenario == .reset ? at(-10) : at(100)),
            UsageWindow(id: "weekly", label: "每週", usedPct: 35, resetsAt: at(3 * 24 * 60)),
            UsageWindow(id: "weekly_opus", label: "每週 Opus", usedPct: 12, resetsAt: at(3 * 24 * 60), hidden: true),
        ])
        let codex = scenario == .error
            ? ProviderUsage(plan: "Team", error: "token 過期，請在 Mac 重新登入 Codex")
            : ProviderUsage(plan: "Team", windows: [
                UsageWindow(id: "five_hour", label: "5 小時", usedPct: scenario == .codex ? 81 : 12, resetsAt: at(240)),
                UsageWindow(id: "weekly", label: "每週", usedPct: 48, resetsAt: at(5 * 24 * 60)),
            ], resetCredits: ResetCredits(available: 2, credits: [  // 重置卷 2 張，一張 2 天後到期
                .init(expiresAt: at(2 * 24 * 60)), .init(expiresAt: at(30 * 24 * 60)),
            ]))
        // 未啟用的服務不在 providers 裡（不是錯誤）
        let providers: [String: ProviderUsage] = switch scenario {
        case .claudeOnly: ["claude": claude]
        case .codexOnly: ["codex": codex]
        case .noProviders: [:]
        default: ["claude": claude, "codex": codex]
        }
        return UsageSnapshot(updatedAt: updatedAt, providers: providers)
    }
}
#endif
