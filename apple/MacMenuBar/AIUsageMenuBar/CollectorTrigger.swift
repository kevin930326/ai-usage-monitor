import Foundation
import UsageKit

/// 面板「更新」按鈕：請 launchd 立即執行收集器（FR-50、ADR-0008 第 8 節）。
/// App 本身不連網；連網的是收集器，這裡只執行 `launchctl kickstart`。
/// 不帶 `-k`，收集器正在執行時不會被中斷。選單列 App 沒有沙盒，可以執行 `/bin/launchctl`。
@MainActor
final class CollectorTrigger {
    static let shared = CollectorTrigger()

    enum Outcome: Equatable {
        /// 已請收集器執行，新的 usage.json 寫入後資料夾監看會自動重讀
        case started
        /// 60 秒內已觸發過，只重讀檔案
        case tooSoon
        /// 最近 24 小時已達上限，只重讀檔案
        case dailyLimitReached
        /// launchd 沒有這個工作（收集器未安裝）
        case notInstalled
        /// 其他失敗（只記錄結束碼，不顯示指令輸出）
        case failed
        /// 以 AI_USAGE_MONITOR_HOME 讀假資料時（測試、截圖、效能量測）不碰真的收集器
        case skipped
    }

    /// 與 `collector/scripts/install-launchd.sh` 的 LABEL 相同
    nonisolated static let label = "io.github.kevin930326.ai-usage-monitor"
    /// `launchctl` 找不到服務時的結束碼（`Could not find service`）
    private static let serviceNotFound: Int32 = 113
    private static let throttleKey = "collector.kicks"

    private let defaults: UserDefaults
    private var throttle: CollectorKickThrottle
    private var running = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        throttle = defaults.data(forKey: Self.throttleKey)
            .flatMap { try? JSONDecoder().decode(CollectorKickThrottle.self, from: $0) } ?? CollectorKickThrottle()
    }

    func trigger(usesCustomHome: Bool) async -> Outcome {
        if usesCustomHome { return .skipped }
        let now = Date.now
        switch throttle.decision(at: now) {
        case .tooSoon: return .tooSoon
        case .dailyLimitReached: return .dailyLimitReached
        case .kick: break
        }
        // 上一次的 launchctl 還沒結束（通常只要幾十毫秒）就當作剛觸發過
        guard !running else { return .tooSoon }
        running = true
        defer { running = false }
        // 先記錄再執行：就算 launchctl 失敗，60 秒內也不會連續重試
        throttle.record(at: now)
        if let data = try? JSONEncoder().encode(throttle) { defaults.set(data, forKey: Self.throttleKey) }

        let status = await Self.kickstart()
        UsageStore.log("kickstart collector exit=\(status.map(String.init) ?? "nil")")
        switch status {
        case 0: return .started
        case Self.serviceNotFound: return .notInstalled
        default: return .failed
        }
    }

    /// 在背景執行 `launchctl kickstart gui/<uid>/<label>`，回傳結束碼（無法啟動時為 nil）。
    private nonisolated static func kickstart() async -> Int32? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }
}

/// 按下「更新」後檔案沒有變化時，頁尾說明接下來會怎樣。收集器寫入新資料時清掉。
enum RefreshHint: Equatable {
    case collecting
    case tooSoon
    case dailyLimitReached
    case notInstalled
    case failed
    case unchanged

    init(_ outcome: CollectorTrigger.Outcome) {
        self = switch outcome {
        case .started: .collecting
        case .tooSoon: .tooSoon
        case .dailyLimitReached: .dailyLimitReached
        case .notInstalled: .notInstalled
        case .failed: .failed
        case .skipped: .unchanged
        }
    }

    var text: String {
        switch self {
        case .collecting: "收集器更新中，完成後自動顯示"
        case .tooSoon: "1 分鐘內已請收集器更新過，完成後自動顯示"
        case .dailyLimitReached: "24 小時內手動更新已達 100 次，改為每 5 分鐘自動更新"
        case .notInstalled: "收集器未安裝，請執行 collector/scripts/install-launchd.sh"
        case .failed: "無法啟動收集器；收集器每 5 分鐘仍會自動更新"
        case .unchanged: "資料沒有變化；收集器每 5 分鐘更新一次"
        }
    }

    /// 需要使用者處理的問題用提示色（設計 skill 第 1 節），其他用 secondary
    var isProblem: Bool { self == .notInstalled || self == .failed }
}
