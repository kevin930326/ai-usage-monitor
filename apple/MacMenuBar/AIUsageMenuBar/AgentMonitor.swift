import AppKit
import Darwin
import Observation
import UsageKit

/// AI 的確切狀態（ADR-0017）：聽 hook 的 Unix socket，把事件彙總成每個工作階段的狀態，交給角色與瀏海。
/// 事件只放在記憶體；日誌只寫計數，不寫欄位內容。資料夾名稱只給畫面用。
@MainActor @Observable
final class AgentMonitor {
    static let shared = AgentMonitor()

    private(set) var sessions = AgentSessions(idleAfter: AgentMonitor.idleAfterMs)
    /// 收到與丟掉的事件數（只用來除錯，不記內容）
    @ObservationIgnored private(set) var received = 0
    @ObservationIgnored private(set) var dropped = 0
    @ObservationIgnored private var listener: Int32 = -1
    @ObservationIgnored private var source: DispatchSourceRead?
    @ObservationIgnored private var expireTimer: Timer?
    @ObservationIgnored private var socketURL: URL?
    @ObservationIgnored private var terminateSource: DispatchSourceSignal?
    /// 每秒上限只套用在「還在跑」的事件；決定狀態的事件一定處理（見 AgentRateLimiter）
    @ObservationIgnored private var limiter = AgentRateLimiter()

    private static var idleAfterMs: Int64 { Int64(PanelSettings.shared.mascotSleepMinutes) * 60_000 }

    var now: Int64 { Int64(Date.now.timeIntervalSince1970 * 1000) }

    /// App 啟動時：準備資料夾與鹽、開始聽。失敗（例如資料夾不能寫）就不接 hook，角色退回修改時間判斷
    func start() {
        guard listener < 0 else { return }
        let directory = UsageStore.shared.locator.directory
        do {
            _ = try AgentSocket.prepare(in: directory)
            let url = AgentSocket.socketURL(in: directory)
            listener = try AgentSocket.listen(at: url)
            socketURL = url
        } catch {
            UsageStore.log("agent socket unavailable: \(error)")
            return
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        let source = AgentSocket.serve(listener: listener) { message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentMonitor.shared.handle(message) }
            }
        }
        self.source = source
        // 被 kill（SIGTERM）時系統不會呼叫 applicationWillTerminate：自己接住，移除 socket 後結束
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler {
            MainActor.assumeIsolated { AgentMonitor.shared.stop() }
            exit(0)
        }
        terminate.resume()
        terminateSource = terminate
    }

    /// App 結束：停止聽並移除 socket 檔（hook 看到沒有 socket 就立刻結束）
    func stop() {
        // 只記數字（量測腳本用來確認有收到）
        if listener >= 0 { UsageStore.log("agent events received=\(received) dropped=\(dropped)") }
        source?.cancel()
        source = nil
        if listener >= 0 { close(listener) }
        listener = -1
        if let socketURL { unlink(socketURL.path) }
        socketURL = nil
    }

    private func handle(_ message: AgentHookMessage?) {
        guard let message else {
            dropped += 1
            return
        }
        guard limiter.admit(message, at: now) else {
            dropped += 1
            return
        }
        sessions.idleAfter = Self.idleAfterMs
        // 比同一工作階段已收到的事件舊（並行讀取時較晚讀完）：丟掉
        guard sessions.apply(message, at: now) else {
            dropped += 1
            return
        }
        received += 1
        changed()
    }

    /// 使用者看過了（展開瀏海或點角色）：完成未看、出錯變成等你
    func markSeen() {
        let before = sessions
        sessions.markSeen(at: now)
        if sessions != before { changed() }
    }

    /// 某個 AI 現在有沒有 hook 的工作階段
    func hasSessions(_ ai: AgentKind) -> Bool { sessions.has(ai) }

    private func changed() {
        scheduleExpire()
        MascotController.shared.agentStateChanged()
    }

    /// 有工作階段時每分鐘看一次：工作中太久沒事件變等你、等你變閒置、太久沒事件的移除
    private func scheduleExpire() {
        guard !sessions.isEmpty else {
            expireTimer?.invalidate()
            expireTimer = nil
            return
        }
        guard expireTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let monitor = AgentMonitor.shared
                monitor.sessions.idleAfter = AgentMonitor.idleAfterMs
                monitor.sessions.expire(at: monitor.now)
                monitor.changed()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        expireTimer = timer
    }
}
