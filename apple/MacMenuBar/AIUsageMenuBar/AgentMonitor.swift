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
    /// 同一秒最多處理幾個事件（同一使用者的其他程式塞假事件時，最多讓狀態跳來跳去，不會吃滿 CPU）
    @ObservationIgnored private var budget = (second: 0, count: 0)
    static let maxPerSecond = 40

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
        let fd = listener
        // 讀連線在背景佇列（每個連線最多 250 ms），解析好的事件回到主執行緒
        let queue = DispatchQueue(label: "aum.agent-socket", qos: .utility)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                let message = AgentSocket.receive(on: client)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AgentMonitor.shared.handle(message) }
                }
            }
        }
        source.resume()
        self.source = source
    }

    /// App 結束：停止聽並移除 socket 檔（hook 看到沒有 socket 就立刻結束）
    func stop() {
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
        let second = Int(now / 1000)
        if budget.second != second { budget = (second, 0) }
        budget.count += 1
        guard budget.count <= Self.maxPerSecond else {
            dropped += 1
            return
        }
        received += 1
        sessions.idleAfter = Self.idleAfterMs
        sessions.apply(message, at: now)
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
