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
    /// 下一次檢查通知（需要你到了設定的秒數）
    @ObservationIgnored private var noticeTimer: Timer?
    @ObservationIgnored private var socketURL: URL?
    @ObservationIgnored private var terminateSource: DispatchSourceSignal?
    /// 每秒上限只套用在「還在跑」的事件；決定狀態的事件一定處理（見 AgentRateLimiter）
    @ObservationIgnored private var limiter = AgentRateLimiter()
    /// 下一次看背景工作（ADR-0017 第 7 節）；沒有工作階段要看時不排
    @ObservationIgnored private var backgroundTimer: Timer?
    /// AI 程序的開始時間（拍基準時記下）：之後 PID 被重用就當成 AI 已結束。只在記憶體
    @ObservationIgnored private var aiStarts: [Int32: Int64] = [:]
    /// 收到事件時記下的 AI 程序開始時間（點工作階段跳回去時檢查 PID 沒被重用，ADR-0017 第 10 節）。
    /// 以「AI、工作階段、PID」為鍵：工作階段結束後 PID 被新的工作階段重用時，新的有自己的紀錄（Codex C-02）。只在記憶體
    @ObservationIgnored private var pidStarts: [String: Int64] = [:]
    /// 列程序中（同時只跑一次）
    @ObservationIgnored private var probingProcesses = false
    /// 前景的宿主程式代表哪些 AI、從什麼時候開始在前景（ADR-0017 第 8 節）；只記這兩個，不記程式名稱
    @ObservationIgnored private var foregroundAIs: Set<AgentKind> = []
    @ObservationIgnored private var foregroundSince: Int64 = 0
    @ObservationIgnored private var hostTimer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private lazy var hosts = AgentHosts.decode(
        Bundle.main.url(forResource: "agent-hosts", withExtension: "json").flatMap { try? Data(contentsOf: $0) } ?? Data())

    /// 宿主程式的清單（`shared/agent-hosts.json`）
    var hostList: AgentHosts { hosts }

    /// 工作階段的 AI 程序（第一次收到帶這個 PID 的事件時）的開始時間；不知道時 nil
    func pidStart(ai: AgentKind, session: String, pid: Int32) -> Int64? { pidStarts[Self.startKey(ai, session, pid)] }

    private static func startKey(_ ai: AgentKind, _ session: String, _ pid: Int32) -> String { "\(ai.rawValue)/\(session)/\(pid)" }

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
            // 只記 errno 或錯誤類別：Foundation 的錯誤描述會帶出完整路徑（Codex C-01）
            let kind = (error as? POSIXError).map { "errno \($0.code.rawValue)" }
                ?? (error as NSError).domain + " \((error as NSError).code)"
            UsageStore.log("agent socket unavailable: \(kind)")
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
        // 在背景佇列接、先移除 socket：主執行緒卡住時 2 秒後自己結束，SIGTERM 不會被吞掉（Fable 總審查 F-03）
        terminateSource = Self.makeTerminateSource(socketPath: socketURL?.path ?? "")
        // 跨裝置的 AI 狀態（ADR-0019 第 2 節）：先寫一次現在的（全部閒置），之後改變時寫
        AgentStateFile.shared.start()
        AgentStateFile.shared.update(sessions, at: now)
        watchForeground()
    }

    /// 前景 App 換了（ADR-0017 第 8 節）：只取 bundle ID 比對宿主清單，比對完就丟
    private func watchForeground() {
        guard activationObserver == nil else { return }
        setForeground(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { AgentMonitor.shared.setForeground(id) }
        }
    }

    private func setForeground(_ bundleID: String?) {
        // 點瀏海、開設定時本 App 會短暫在前景：不算切走，切回原本的程式也不算「完成之後才切過來」（Fable F-18）
        if let bundleID, bundleID == Bundle.main.bundleIdentifier { return }
        foregroundAIs = hosts.ais(bundleID: bundleID)
        foregroundSince = now
        checkHost()
    }

    /// 宿主程式在前景：完成之後才切過來的、或完成後停留滿 3 秒的「完成未看」標成已看；需要你與出錯不動
    private func checkHost() {
        hostTimer?.invalidate()
        hostTimer = nil
        guard !foregroundAIs.isEmpty else { return }
        let at = now
        if sessions.markSeenByHost(foregroundAIs, foregroundSince: foregroundSince, at: at) { changed() }
        guard let next = sessions.nextHostCheck(foregroundAIs, foregroundSince: foregroundSince, after: at) else { return }
        let timer = Timer(timeInterval: max(Double(next - at) / 1000, 0.05), repeats: false) { _ in
            MainActor.assumeIsolated { AgentMonitor.shared.checkHost() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        hostTimer = timer
    }

    /// 不在主執行緒上的處理器（nonisolated）：從 @MainActor 方法裡建立的閉包會被當成主執行緒專用，在背景佇列執行會當掉
    private nonisolated static func makeTerminateSource(socketPath: String) -> DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        terminate.setEventHandler { @Sendable in
            if !socketPath.isEmpty { unlink(socketPath) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentMonitor.shared.stop() }
                exit(0)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { _exit(0) }
        }
        terminate.resume()
        return terminate
    }

    /// App 結束：停止聽並移除 socket 檔（hook 看到沒有 socket 就立刻結束）
    func stop() {
        // 只記數字（量測腳本用來確認有收到）
        if listener >= 0 { UsageStore.log("agent events received=\(received) dropped=\(dropped)") }
        source?.cancel()
        source = nil
        if listener >= 0 { close(listener) }
        listener = -1
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        hostTimer?.invalidate()
        hostTimer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let socketURL { unlink(socketURL.path) }
        socketURL = nil
        AgentStateFile.shared.stop()
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
        let before = sessions.sessions.first { $0.ai == message.ai && $0.id == message.session }?.stored
        // 比同一工作階段已收到的事件舊（並行讀取時較晚讀完）：丟掉
        guard sessions.apply(message, at: now) else {
            dropped += 1
            return
        }
        received += 1
        if message.pid > 0, !message.sub {
            let key = Self.startKey(message.ai, message.session, message.pid)
            if pidStarts[key] == nil {
                // 已經結束的工作階段不必再記
                let live = Set(sessions.sessions.map { Self.startKey($0.ai, $0.id, $0.pid) })
                pidStarts = pidStarts.filter { live.contains($0.key) }
                pidStarts[key] = AgentProcessTree.start(message.pid)
            }
        }
        let after = sessions.sessions.first { $0.ai == message.ai && $0.id == message.session }?.stored
        changed()
        // 一個回合剛完成：角色揮手（收著時瀏海鼓一下）；宿主程式在前景的話 3 秒後算看過
        if after == .done, before != .done {
            MascotController.shared.agentFinished()
            checkHost()
        }
    }

    #if DEBUG
    /// 效能量測：送一個假的事件（同 socket 收到的處理方式）
    func debugApply(_ event: AgentHookEvent, need: AgentNeed? = nil) {
        handle(AgentHookMessage(ai: .claude, event: event, need: need, session: "0123456789abcdef", time: now, folder: "perf"))
    }
    #endif

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
        scheduleBackground()
        AgentStateFile.shared.update(sessions, at: now)
        MascotController.shared.agentStateChanged()
        evaluateNotices()
    }

    /// 設定的通知秒數改了：重新排下一次檢查
    func noticeSettingsChanged() {
        evaluateNotices()
    }

    /// 送出該發的通知，並排下一次檢查（需要你還沒到設定的秒數時）；不輪詢
    private func evaluateNotices() {
        noticeTimer?.invalidate()
        noticeTimer = nil
        let at = now
        AgentNotifier.shared.evaluate(sessions, at: at)
        guard let next = sessions.nextNoticeCheck(after: at, policy: PanelSettings.shared.agentNoticePolicy) else { return }
        let timer = Timer(timeInterval: max(Double(next - at) / 1000, 0.05), repeats: false) { _ in
            MainActor.assumeIsolated { AgentMonitor.shared.evaluateNotices() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        noticeTimer = timer
    }

    /// 背景工作（ADR-0017 第 7 節）：要拍基準的馬上拍；有工作階段要看時照最早的時間排一次計時器，沒有就不排（不輪詢）
    private func scheduleBackground() {
        if !sessions.baselineRequests.isEmpty || !sessions.backgroundChecks(at: now).isEmpty {
            probeProcesses()
            return
        }
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        guard let next = sessions.nextBackgroundCheck else { return }
        let timer = Timer(timeInterval: max(Double(next - now) / 1000, 0.05), repeats: false) { _ in
            MainActor.assumeIsolated { AgentMonitor.shared.probeProcesses() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    /// 在背景佇列列 AI 程序的子孫程序（只有 PID、父 PID、開始時間），回到主執行緒套用
    private func probeProcesses() {
        guard !probingProcesses else { return }
        let at = now
        let baselines = sessions.baselineRequests
        let checks = sessions.backgroundChecks(at: at)
        guard !baselines.isEmpty || !checks.isEmpty else {
            scheduleBackground()
            return
        }
        probingProcesses = true
        let starts = aiStarts
        Task.detached(priority: .utility) {
            let taken = baselines.map { r in (r, AgentProcessTree.start(r.pid), AgentProcessTree.descendants(of: r.pid)) }
            let seen = checks.map { c in (c, AgentProcessTree.descendants(of: c.pid, start: starts[c.pid])) }
            await MainActor.run {
                let monitor = AgentMonitor.shared
                monitor.probingProcesses = false
                for (r, start, processes) in taken {
                    if let start { monitor.aiStarts[r.pid] = start }
                    monitor.sessions.setBaseline(ai: r.ai, id: r.id, pid: r.pid, probe: r.probe, processes: processes)
                }
                var different = false
                for (c, processes) in seen {
                    different = monitor.sessions.observe(ai: c.ai, id: c.id, pid: c.pid, probe: c.probe, processes: processes, at: monitor.now) || different
                }
                // 已經沒有工作階段用的 AI 程序不必再記
                let live = Set(monitor.sessions.sessions.map(\.pid))
                monitor.aiStarts = monitor.aiStarts.filter { live.contains($0.key) }
                if different { monitor.changed() } else { monitor.scheduleBackground() }
            }
        }
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
