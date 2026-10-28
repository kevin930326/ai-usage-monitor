#if canImport(Darwin)
import Darwin
import CryptoKit
import Foundation

/// hook 與 App 之間的本機 Unix socket（ADR-0017 第 2 節）。只在 Mac 上；Windows 見 ADR-0019。
///
/// 位置：`<資料夾>/agent/hook.sock`（資料夾 0700、socket 0600），鹽：`<資料夾>/agent/salt`（0600）。
/// 資料夾預設 `~/Library/Application Support/AIUsageMonitor`，測試時是 `AI_USAGE_MONITOR_HOME`。
public enum AgentSocket {
    public static let folderName = "agent"
    public static let socketName = "hook.sock"
    public static let saltName = "salt"
    /// hook 連線與送出的上限（毫秒）：App 沒回應也不會卡住 AI
    public static let sendTimeoutMs: Int32 = 100
    /// App 讀一個連線的上限（毫秒）
    public static let readTimeoutMs = 250

    public static func folder(in directory: URL) -> URL { directory.appendingPathComponent(folderName, isDirectory: true) }
    public static func socketURL(in directory: URL) -> URL { folder(in: directory).appendingPathComponent(socketName) }
    public static func saltURL(in directory: URL) -> URL { folder(in: directory).appendingPathComponent(saltName) }

    /// 工作階段 ID 的加鹽雜湊（前 16 個十六進位字元）
    public static func sessionHash(_ sessionID: String, salt: Data) -> String {
        let digest = SHA256.hash(data: salt + Data(sessionID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    // MARK: - hook 端

    /// hook 送出一行；任何失敗都安靜地回傳 false（呼叫端照樣 exit 0）
    @discardableResult
    public static func send(_ message: AgentHookMessage, to socket: URL) -> Bool {
        let path = socket.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return false }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: suseconds_t(sendTimeoutMs * 1000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // 非阻塞連線，最多等 100 ms（App 卡住時 backlog 滿也不會卡住 hook）
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return false }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, sendTimeoutMs) == 1, poller.revents & Int16(POLLOUT) != 0 else { return false }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return false }
        }
        _ = fcntl(fd, F_SETFL, flags)
        let line = Array(message.encoded()) + [UInt8(ascii: "\n")]
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return written == line.count
    }

    // MARK: - App 端

    /// 準備資料夾與鹽：資料夾 0700、鹽 0600（沒有就產生 32 個隨機位元組）。回傳鹽
    public static func prepare(in directory: URL) throws -> Data {
        let folder = folder(in: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let salt = saltURL(in: directory)
        if let existing = try? Data(contentsOf: salt), existing.count == 32 { return existing }
        // SystemRandomNumberGenerator 在 Apple 平台是密碼學安全的亂數（arc4random）
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        // 先建 0600 的空檔再寫入，鹽不會有一刻是別人可讀的
        FileManager.default.createFile(atPath: salt.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: salt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: salt.path)
        return data
    }

    /// hook 讀鹽：檔案要是 32 位元組；沒有（App 沒跑過）就回傳 nil
    public static func readSalt(in directory: URL) -> Data? {
        guard let data = try? Data(contentsOf: saltURL(in: directory)), data.count == 32 else { return nil }
        return data
    }

    /// 開始聽：移除舊的 socket 檔、綁定、設成 0600。回傳聽的 fd
    public static func listen(at socket: URL) throws -> Int32 {
        let path = socket.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }
        // 綁定前先把 umask 收緊，socket 檔一建立就是 0600
        let mask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(mask)
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        return fd
    }

    /// 讀一個連線：只接受同一個使用者，最多 1 KB、250 ms；讀到的一行交給 `AgentHookMessage.parse`
    public static func receive(on client: Int32) -> AgentHookMessage? {
        defer { close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return nil }
        // App 的監聽 socket 是非阻塞的，BSD 的 accept 會讓連線繼承：改回阻塞，等資料由下面的讀取逾時把關
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: suseconds_t(readTimeoutMs * 1000))
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: AgentHookMessage.maxLength + 2)
        var count = 0
        let deadline = Date.now.addingTimeInterval(Double(readTimeoutMs) / 1000)
        while count < buffer.count, Date.now < deadline {
            let n = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress! + count, $0.count - count) }
            if n <= 0 { break }
            count += n
            if buffer[..<count].contains(UInt8(ascii: "\n")) { break }
        }
        guard let end = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")), end <= AgentHookMessage.maxLength else { return nil }
        return AgentHookMessage.parse(Data(buffer[..<end]))
    }
}

/// hook 程式的本體（`aum-hook <claude|codex>`）：讀事件、只挑需要的欄位、加鹽雜湊、送到 App。
/// 任何失敗都只回傳 false；呼叫端一律 exit 0、不印任何東西。
public enum AgentHookRunner {
    public static func run(ai: AgentKind, input: Data, directory: URL, now: Date = .now) -> Bool {
        guard let event = AgentHookInput.extract(input), let salt = AgentSocket.readSalt(in: directory) else { return false }
        let message = AgentHookMessage(ai: ai, event: event.event, need: event.need,
                                       session: AgentSocket.sessionHash(event.sessionID, salt: salt),
                                       time: Int64(now.timeIntervalSince1970 * 1000), folder: event.folder, sub: event.sub)
        return AgentSocket.send(message, to: AgentSocket.socketURL(in: directory))
    }

    /// 從標準輸入讀事件：最多 1 MB 多一個位元組（超過就整個丟掉），標準輸入是終端機時不等
    public static func readInput(from fd: Int32 = STDIN_FILENO) -> Data? {
        guard isatty(fd) == 0 else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= AgentHookInput.maxInput {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            data.append(contentsOf: buffer[..<n])
        }
        return data.count <= AgentHookInput.maxInput ? data : nil
    }
}
#endif
