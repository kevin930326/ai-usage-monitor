import Foundation
import UsageKit

/// 跨裝置的 AI 狀態（ADR-0019 第 2 節）：把這台的彙總寫到 `agent-state.json`，由收集器的 `--agent-sync` 上傳。
/// 只有 AI、最高狀態、工作階段數與進入時間（`AgentSummary`），沒有資料夾名稱或任何內容。App 本身仍不連網。
///
/// - 內容改變時寫，並以 `launchctl kickstart` 觸發 AI 狀態同步（內建收集器的 `<bundle ID>.agent-sync`，
///   或 install-launchd.sh 的 `io.github.kevin930326.ai-usage-monitor.agent-sync`；沒有安裝時 launchctl 失敗、不影響）。
/// - 每 5 分鐘重寫一次（不觸發）：收集器把超過 10 分鐘沒更新的檔當成 App 沒在跑；一般 5 分鐘一輪也會同步。
/// - App 結束時寫「全部閒置」並觸發一次。
/// 同步沒打開（config.json 沒有 `agent_sync`）時收集器什麼都不做，所以這裡不讀設定。
@MainActor
final class AgentStateFile {
    static let shared = AgentStateFile()
    static let rewriteInterval: TimeInterval = 300

    private var last: Data?
    private var timer: Timer?
    /// 合併中的同步觸發（1 秒內只觸發一次）
    private var kickPending = false

    private var url: URL { UsageStore.shared.locator.directory.appendingPathComponent(AgentSummary.fileName) }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.rewriteInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                let monitor = AgentMonitor.shared
                AgentStateFile.shared.update(monitor.sessions, at: monitor.now, rewrite: true)
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 狀態可能改變時呼叫（AgentMonitor 的 changed）：內容一樣就不寫
    func update(_ sessions: AgentSessions, at now: Int64, rewrite: Bool = false) {
        let data = AgentSummary.encoded(sessions, at: now)
        let changed = data != last
        guard changed || rewrite else { return }
        guard write(data) else { return }
        last = data
        if changed { kick() }
    }

    /// App 結束：全部閒置（其他電腦馬上看到這台沒事，而不是等 30 分鐘過期）
    func stop() {
        timer?.invalidate()
        timer = nil
        guard last != nil, last != AgentSummary.empty, write(AgentSummary.empty) else { return }
        last = AgentSummary.empty
        // App 正要結束：馬上觸發，不等合併
        kickNow()
    }

    private func write(_ data: Data) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            // 只記錯誤類別：Foundation 的描述會帶出完整路徑
            UsageStore.log("agent state write failed: \((error as NSError).domain) \((error as NSError).code)")
            return false
        }
    }

    /// 狀態接連改變時（例如很多工具事件）合併成 1 秒後觸發一次，不會每個事件都開一個 launchctl（Fable F-01）
    private func kick() {
        guard !kickPending else { return }
        kickPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.kickPending = false
            self?.kickNow()
        }
    }

    /// 觸發 AI 狀態同步；測試（`AI_USAGE_MONITOR_HOME`）時不觸發真的 launchd 工作
    private func kickNow() {
        guard !UsageStore.shared.usesCustomHome else { return }
        let label = CollectorService.shared.syncKickLabel
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
