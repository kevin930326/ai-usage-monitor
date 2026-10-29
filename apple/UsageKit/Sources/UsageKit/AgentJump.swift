import Foundation

/// 點工作階段跳回那個 session（ADR-0017 第 10 節）：從 AI 程序沿父程序往上找宿主程式（終端機、編輯器、Claude App），
/// 以及 tmux 指令輸出的解析。只用 PID、父 PID、開始時間、bundle ID／執行檔名稱、程序名稱、tty 與「有沒有可見的視窗」；
/// 不讀命令列、環境變數、工作目錄、視窗標題或任何內容。程序樹由呼叫端注入（App 包 libproc／Toolhelp32，測試用字典），
/// Swift 與 C#（UsageCore/AgentJump.cs）跑同一份 `fixtures/agent-jump/cases.json`。
public enum AgentJump {
    /// 往上最多幾層（同背景偵測往下的層數）
    public static let maxDepth = 16

    /// 程序圖上的一個程序（只有這些欄位）
    public struct Process: Sendable, Equatable {
        public var pid: Int32
        public var parent: Int32
        /// 開始時間（微秒，只在同一台電腦上比較）
        public var start: Int64
        /// 程序名稱（執行檔名稱，最多 16 字，不是命令列）
        public var name: String
        /// Mac：`NSRunningApplication` 的 bundle ID（不是 App 是 nil）
        public var bundleID: String?
        /// 控制終端機（`/dev/ttysNNN`）；沒有是 nil
        public var tty: String?
        /// Windows：這個程序有可見、沒有擁有者的頂層視窗
        public var hasWindow: Bool

        public init(pid: Int32, parent: Int32, start: Int64, name: String, bundleID: String? = nil, tty: String? = nil, hasWindow: Bool = false) {
            self.pid = pid
            self.parent = parent
            self.start = start
            self.name = name
            self.bundleID = bundleID
            self.tty = tty
            self.hasWindow = hasWindow
        }
    }

    /// Mac 的結果
    public enum Target: Sendable, Equatable {
        /// 宿主 App（`pid`）；`tty` 是 AI 程序的控制終端機（Terminal／iTerm2 用它切分頁）
        case app(pid: Int32, bundleID: String, tty: String?)
        /// AI 在 tmux 裡：先用 tty 找 pane 與 client（`plan`），再從 client 的 PID 往上找宿主
        case tmux(tty: String)
        case none
    }

    /// Mac：從 AI 程序往上找宿主。`start` 是收到事件時記下的開始時間（PID 被重用時不一樣，當成找不到）；不知道時 nil。
    /// 每一層要求「父的開始時間 ≤ 子的」（父 PID 被重用就斷鏈）；有 bundle ID 但不在清單（例如 VS Code 的 helper）繼續往上；
    /// 遇到 `tmux`（伺服器 daemonize 後父程序是 launchd，往上永遠到不了終端機）改走 client 路徑
    public static func macTarget(ai: Int32, start: Int64?, hosts: AgentHosts, process: (Int32) -> Process?) -> Target {
        guard ai > 1, let first = process(ai), start.map({ $0 == first.start }) ?? true else { return .none }
        let tty = first.tty.flatMap { isValidTTY($0) ? $0 : nil }
        var current = first
        for _ in 0..<maxDepth {
            if current.name == "tmux" { return tty.map { .tmux(tty: $0) } ?? .none }
            if let bundleID = current.bundleID, !hosts.ais(bundleID: bundleID).isEmpty {
                return .app(pid: current.pid, bundleID: bundleID, tty: tty)
            }
            guard current.parent > 1, let parent = process(current.parent), parent.start <= current.start else { return .none }
            current = parent
        }
        return .none
    }

    /// Windows：從 AI 程序往上，第一個「執行檔名稱在清單裡、而且有可見頂層視窗」的程序（shell、OpenConsole 沒有自己的視窗，
    /// 會繼續往上到 Windows Terminal；傳統主控台的視窗由系統算在 shell 上）。找不到時 nil
    public static func windowsTarget(ai: Int32, start: Int64?, hosts: AgentHosts, process: (Int32) -> Process?) -> Int32? {
        guard ai > 4, let first = process(ai), start.map({ $0 == first.start }) ?? true else { return nil }
        var current = first
        for _ in 0..<maxDepth {
            if current.hasWindow, hosts.windows[current.name.lowercased()] != nil { return current.pid }
            guard current.parent > 4, let parent = process(current.parent), parent.start <= current.start else { return nil }
            current = parent
        }
        return nil
    }

    /// Mac 的 pty：`/dev/ttys` 加 3～4 位數字（其他一律不收，也不會交給 AppleScript 或 tmux）
    public static func isValidTTY(_ value: String) -> Bool {
        guard value.hasPrefix("/dev/ttys") else { return false }
        let digits = value.dropFirst("/dev/ttys".count)
        return (3...4).contains(digits.count) && digits.allSatisfy { ("0"..."9").contains($0) }
    }

    // MARK: - tmux

    /// `tmux list-panes -a -F '#{pane_tty} #{pane_id} #{session_id}'` 的一列
    public struct Pane: Sendable, Equatable {
        public var tty: String
        public var id: String
        public var session: String
    }

    /// `tmux list-clients -F '#{client_tty} #{client_pid} #{client_session} #{client_activity}'` 的一列（`client_session` 是 ID，見 `clientFormat`）
    public struct Client: Sendable, Equatable {
        public var tty: String
        public var pid: Int32
        public var session: String
        public var activity: Int64
    }

    /// 要執行的 tmux 動作
    public struct Plan: Sendable, Equatable {
        public var pane: String
        public var session: String
        public var client: Client
        /// client 掛在別的 session：先 `switch-client -c <client tty> -t <session>`
        public var switchClient: Bool
    }

    /// 只讀 tty 與數字 ID，不讀 session、window、pane 的名稱（Fable H-02）
    public static let paneFormat = "#{pane_tty} #{pane_id} #{session_id}"
    /// `client_session` 是名稱，所以用 `#{session_id}`：在 list-clients 裡是 client 目前那個 session 的 ID
    public static let clientFormat = "#{client_tty} #{client_pid} #{session_id} #{client_activity}"

    /// 每列三欄、格式都對才收；其他列略過（不記錄、不顯示）
    public static func panes(_ output: String) -> [Pane] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: false)
            guard f.count == 3, isValidTTY(String(f[0])), isID(f[1], prefix: "%"), isID(f[2], prefix: "$") else { return nil }
            return Pane(tty: String(f[0]), id: String(f[1]), session: String(f[2]))
        }
    }

    public static func clients(_ output: String) -> [Client] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: false)
            guard f.count == 4, isValidTTY(String(f[0])), let pid = Int32(f[1]), pid > 1, isID(f[2], prefix: "$"),
                  let activity = Int64(f[3]), activity >= 0 else { return nil }
            return Client(tty: String(f[0]), pid: pid, session: String(f[2]), activity: activity)
        }
    }

    /// AI 的 tty 對到的 pane；client 取最近有動作的（同時間取 tty 小的，結果固定）。沒有 pane 或沒有 client 時 nil
    public static func plan(panes: [Pane], clients: [Client], tty: String) -> Plan? {
        guard let pane = panes.first(where: { $0.tty == tty }),
              let client = clients.max(by: { ($0.activity, $1.tty) < ($1.activity, $0.tty) }) else { return nil }
        return Plan(pane: pane.id, session: pane.session, client: client, switchClient: client.session != pane.session)
    }

    private static func isID(_ value: Substring, prefix: Character) -> Bool {
        value.count >= 2 && value.first == prefix && value.dropFirst().allSatisfy { ("0"..."9").contains($0) }
    }
}
