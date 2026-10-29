import AppKit
import Carbon
import UsageKit

/// 點工作階段跳回那個 session（ADR-0017 第 10 節）：把 AI 所在的程式帶到前面，Terminal／iTerm2 與 tmux 再切到那個分頁。
/// 只在點的那一刻找（背景執行緒），不預先、不輪詢；只用 PID、父 PID、開始時間、bundle ID、程序名稱與 tty。
/// tmux 只讀 tty 與數字 ID；AppleScript 只送 Terminal 與 iTerm2、腳本寫死、tty 以參數傳入。結果不寫日誌（只記成功或失敗的種類）
@MainActor
enum AgentJumper {
    static let terminal = "com.apple.Terminal"
    static let iterm = "com.googlecode.iterm2"

    /// 「自動化」權限被拒絕過（設定的「AI 狀態」顯示怎麼打開）；只在記憶體，重開 App 後重新判斷
    static var automationDenied = false

    /// 跳到 `ai` 的工作階段 `id`；`done` 收到是否帶到前面了（false：找不到宿主，呼叫端顯示提示）
    static func jump(ai: AgentKind, id: String, done: @escaping @MainActor (Bool) -> Void) {
        let monitor = AgentMonitor.shared
        guard let session = monitor.sessions.sessions.first(where: { $0.ai == ai && $0.id == id }), session.pid > 0 else {
            UsageStore.log("agent jump: no process")
            done(false)
            return
        }
        let pid = session.pid
        let start = monitor.pidStart(ai: ai, session: id, pid: pid)
        let hosts = monitor.hostList
        Task.detached(priority: .userInitiated) {
            let target = Self.resolve(pid: pid, start: start, hosts: hosts)
            await MainActor.run {
                guard case let .app(host, bundleID, tty) = target else {
                    UsageStore.log("agent jump: no host")
                    done(false)
                    return
                }
                bringForward(pid: host, bundleID: bundleID, tty: tty, done: done)
            }
        }
    }

    /// 找宿主；在 tmux 裡時先切 pane，再從 client 往上找（client 的 tty 是終端機分頁的 tty）
    nonisolated private static func resolve(pid: Int32, start: Int64?, hosts: AgentHosts) -> AgentJump.Target {
        let target = AgentJump.macTarget(ai: pid, start: start, hosts: hosts, process: process)
        guard case let .tmux(tty) = target else { return target }
        guard let panes = Tmux.run(["list-panes", "-a", "-F", AgentJump.paneFormat]),
              let clients = Tmux.run(["list-clients", "-F", AgentJump.clientFormat]),
              let plan = AgentJump.plan(panes: AgentJump.panes(panes), clients: AgentJump.clients(clients), tty: tty) else { return .none }
        if plan.switchClient { _ = Tmux.run(["switch-client", "-c", plan.client.tty, "-t", plan.session]) }
        _ = Tmux.run(["select-window", "-t", plan.pane])
        _ = Tmux.run(["select-pane", "-t", plan.pane])
        return AgentJump.macTarget(ai: plan.client.pid, start: nil, hosts: hosts, process: process)
    }

    /// 程序圖：libproc 的欄位加上 App 的 bundle ID
    nonisolated private static func process(_ pid: Int32) -> AgentJump.Process? {
        guard var p = AgentProcessTree.jumpProcess(pid) else { return nil }
        p.bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return p
    }

    /// Terminal／iTerm2 有 tty 時先切分頁；不行（沒權限、找不到分頁）就只把 App 帶到前面
    private static func bringForward(pid: Int32, bundleID: String, tty: String?, done: @escaping @MainActor (Bool) -> Void) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            done(false)
            return
        }
        guard let tty, bundleID == terminal || bundleID == iterm else {
            activate(app)
            done(true)
            return
        }
        Task.detached(priority: .userInitiated) {
            // 第一次會跳出 macOS「自動化」的詢問（等使用者回答，所以不在主執行緒）
            let permission = Self.permission(bundleID)
            await MainActor.run {
                if permission == OSStatus(errAEEventNotPermitted) { automationDenied = true }
                if permission == noErr, AppleScripts.select(tty: tty, in: bundleID) {
                    automationDenied = false
                    UsageStore.log("agent jump: tab")
                } else {
                    activate(app)
                    UsageStore.log("agent jump: app")
                }
                done(true)
            }
        }
    }

    nonisolated private static func permission(_ bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
    }

    /// 帶到前面：和在 Dock 點那個 App 一樣（`activate()` 從背景 App 呼叫時 macOS 14 起可能不理）
    private static func activate(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}

/// 執行 tmux（只在點擊時、只用預設 socket）：`/opt/homebrew/bin` 或 `/usr/local/bin` 的 tmux，環境只給 PATH，
/// 輸出最多 64 KB、2 秒逾時、stderr 丟掉。輸出只交給 `AgentJump` 解析，不記錄
enum Tmux {
    static let directories = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func run(_ arguments: [String]) -> String? {
        guard let path = directories.map({ $0 + "/tmux" }).first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": directories.joined(separator: ":")]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        let data = output.fileHandleForReading.readData(ofLength: 64 * 1024)
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Terminal、iTerm2 依 tty 選分頁的 AppleScript：App 內寫死，tty 以 handler 的參數傳入（不拼字串），2 秒逾時
@MainActor
enum AppleScripts {
    private static let sources: [String: String] = [
        AgentJumper.terminal: """
        on jumpto(target)
        	with timeout of 2 seconds
        		tell application id "com.apple.Terminal"
        			repeat with w in windows
        				repeat with t in tabs of w
        					if (tty of t) is target then
        						set selected tab of w to t
        						set index of w to 1
        						activate
        						return true
        					end if
        				end repeat
        			end repeat
        		end tell
        	end timeout
        	return false
        end jumpto
        """,
        AgentJumper.iterm: """
        on jumpto(target)
        	with timeout of 2 seconds
        		tell application id "com.googlecode.iterm2"
        			repeat with w in windows
        				repeat with t in tabs of w
        					repeat with s in sessions of t
        						if (tty of s) is target then
        							select w
        							tell t to select
        							tell s to select
        							activate
        							return true
        						end if
        					end repeat
        				end repeat
        			end repeat
        		end tell
        	end timeout
        	return false
        end jumpto
        """,
    ]
    private static var compiled: [String: NSAppleScript] = [:]

    /// 找到並選了那個分頁時 true
    static func select(tty: String, in bundleID: String) -> Bool {
        guard AgentJump.isValidTTY(tty), let source = sources[bundleID] else { return false }
        let script: NSAppleScript
        if let cached = compiled[bundleID] {
            script = cached
        } else {
            guard let made = NSAppleScript(source: source) else { return false }
            var error: NSDictionary?
            guard made.compileAndReturnError(&error) else { return false }
            compiled[bundleID] = made
            script = made
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: NSAppleEventDescriptor.currentProcess(),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: "jumpto"), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(NSAppleEventDescriptor(string: tty), at: 1)
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let code = error?[NSAppleScript.errorNumber] as? Int {
            if code == Int(errAEEventNotPermitted) { AgentJumper.automationDenied = true }
            return false
        }
        return result.booleanValue
    }
}
