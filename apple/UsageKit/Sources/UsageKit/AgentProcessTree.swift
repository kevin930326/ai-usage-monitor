#if os(macOS)
import Darwin

/// AI 程序底下的子孫程序（ADR-0017 第 7 節）：只用程序是否存在、PID、父 PID、開始時間；hook 端另外讀父程序的**名稱**
/// 判斷是不是 shell。不讀命令列參數、環境變數、工作目錄或任何內容；結果只放在記憶體。
public enum AgentProcessTree {
    /// 執行 hook 指令的 shell（指令含 `2>/dev/null || true`，shell 不會 exec，hook 的父程序是它，AI 是它的父程序）
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]
    /// 一次最多列幾個程序、往下幾層
    public static let maxProcesses = AgentSessions.maxProcesses
    public static let maxDepth = 16

    /// hook 端：AI 程序的 PID。父程序是 shell 就往上一層；找不到時回傳 0（不偵測背景工作）
    public static func aiProcess(hookParent parent: pid_t = getppid()) -> Int32 {
        guard parent > 1 else { return 0 }
        guard shells.contains(name(parent)) else { return parent }
        guard let info = info(parent), info.pbi_ppid > 1 else { return 0 }
        return Int32(info.pbi_ppid)
    }

    /// 程序的開始時間（微秒）；程序不在時是 nil
    public static func start(_ pid: Int32) -> Int64? {
        info(pid).map { Int64($0.pbi_start_tvsec) * 1_000_000 + Int64($0.pbi_start_tvusec) }
    }

    /// `pid` 底下所有子孫程序；`pid` 不在、不是這個使用者的（假事件填 launchd 之類，Fable F-02）、或開始時間不是 `start`
    /// （PID 被重用）時回傳 nil。子程序的開始時間早於父程序的不算（列的途中父程序結束、PID 給了別的程序）
    public static func descendants(of pid: Int32, start expected: Int64? = nil) -> Set<AgentProcess>? {
        guard pid > 1, let root = info(pid), root.pbi_uid == getuid() else { return nil }
        let rootStart = Int64(root.pbi_start_tvsec) * 1_000_000 + Int64(root.pbi_start_tvusec)
        guard expected.map({ $0 == rootStart }) ?? true else { return nil }
        var found: Set<AgentProcess> = []
        var level: [(pid: Int32, start: Int64)] = [(pid, rootStart)]
        for _ in 0..<maxDepth where !level.isEmpty {
            var next: [(pid: Int32, start: Int64)] = []
            for parent in level {
                for child in children(parent.pid) {
                    guard found.count < maxProcesses, let info = info(child), Int32(info.pbi_ppid) == parent.pid else { continue }
                    let begun = Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
                    guard begun >= parent.start else { continue }
                    let process = AgentProcess(pid: child, start: begun)
                    guard found.insert(process).inserted else { continue }
                    next.append((child, begun))
                }
            }
            level = next
        }
        return found
    }

    static func children(_ pid: Int32) -> [Int32] {
        var buffer = [Int32](repeating: 0, count: maxProcesses)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        return count > 0 ? Array(buffer.prefix(min(Int(count), buffer.count))).filter { $0 > 0 } : []
    }

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// 點工作階段跳回去（ADR-0017 第 10 節）：父 PID、開始時間、名稱與控制終端機（`/dev/ttysNNN`）。bundle ID 由 App 補上
    /// （UsageKit 不用 AppKit）。別的使用者的程序（例如 Terminal 底下的 `login`）也讀得到這些欄位；程序不在時 nil
    public static func jumpProcess(_ pid: Int32) -> AgentJump.Process? {
        guard pid > 0, let info = info(pid) else { return nil }
        var tty: String?
        // e_tdev 是 NODEV（-1）時沒有控制終端機
        if info.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }
        return AgentJump.Process(pid: pid, parent: Int32(info.pbi_ppid),
                                 start: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec),
                                 name: name(pid), tty: tty)
    }

    /// 程序名稱（最多 16 字的執行檔名稱，不是命令列）
    static func name(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }
}
#endif
