import Foundation

// 第二層：多裝置的 Token 統計（FR-49、ADR-0011 第 2、4 節）。
// 收集器從中繼下載其他電腦的每日加總，寫進 history.sqlite3（daily_tokens 的其他 device_id 與 devices 表）；
// 這裡只有範圍的篩選與標籤文字，Linux 也能測試。

/// 中繼上的一台電腦（`devices` 表）。
public struct TokenDevice: Equatable, Sendable, Identifiable {
    /// 中繼的 device_id
    public var id: String
    public var name: String
    public var lastUpload: Date?
    public var revoked: Bool
    /// 這台 Mac 自己（它在中繼上的那一列；本機的數字以本機統計為準）
    public var isSelf: Bool

    public init(id: String, name: String, lastUpload: Date? = nil, revoked: Bool = false, isSelf: Bool = false) {
        self.id = id
        self.name = name
        self.lastUpload = lastUpload
        self.revoked = revoked
        self.isSelf = isSelf
    }
}

/// 統計的裝置範圍：這台 Mac、所有電腦，或某一台其他電腦。
public enum TokenDeviceScope: Hashable, Sendable {
    case thisMac
    case all
    case device(String)

    /// 存在 UserDefaults 的值
    public var rawValue: String {
        switch self {
        case .thisMac: "this"
        case .all: "all"
        case let .device(id): "device:\(id)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "this": self = .thisMac
        case "all": self = .all
        default:
            guard rawValue.hasPrefix("device:"), rawValue.count > 7 else { return nil }
            self = .device(String(rawValue.dropFirst(7)))
        }
    }
}

/// 第二層的裝置清單與上傳狀態。
public struct TokenDevices: Equatable, Sendable {
    /// `TokenDayRow.device` 裡代表這台 Mac 的值
    public static let local = ""
    /// 超過這麼久沒有上傳就在切換中標示「N 天前更新」
    public static let staleAfter: TimeInterval = 48 * 3600
    public static let none = TokenDevices()

    /// 中繼的裝置清單（含這台 Mac 自己）
    public var devices: [TokenDevice]
    /// 這台 Mac 的寫入密鑰失效，收集器已停止上傳（`meta.upload_status = revoked`）
    public var uploadRevoked: Bool

    public init(devices: [TokenDevice] = [], uploadRevoked: Bool = false) {
        self.devices = devices
        self.uploadRevoked = uploadRevoked
    }

    public var others: [TokenDevice] { devices.filter { !$0.isSelf } }

    /// 拿掉撤銷時一併刪除了資料的電腦（`relay-device.sh revoke --delete-data`）：中繼的清單仍有它（標撤銷），
    /// 但已沒有任何每日資料，不再列出、也不算在「N 台」裡；只剩這台 Mac 時回到「這台 Mac」。
    /// 中繼不回報資料是否刪除，以 `days`（收集器下載後本機的每日資料）裡沒有它判斷。
    /// 只撤銷、保留資料的電腦照常列出並標「已撤銷」；沒撤銷的電腦即使還沒有資料也列出（「尚未上傳」）
    public func removingDeleted(days: [TokenDayRow]) -> TokenDevices {
        let withData = Set(days.map(\.device))
        var result = self
        result.devices = devices.filter { $0.isSelf || !$0.revoked || withData.contains($0.id) }
        return result
    }

    /// 有其他電腦時才顯示裝置切換；沒有第二層時一律「這台 Mac」（ADR-0011 第 4 節）
    public var enabled: Bool { !others.isEmpty }

    /// 「所有電腦（N 台）」的 N：這台 Mac＋其他電腦
    public var count: Int { others.count + 1 }

    /// 切換的選項：所有電腦、這台 Mac、其他電腦（依中繼的清單順序）
    public var scopes: [TokenDeviceScope] {
        enabled ? [.all, .thisMac] + others.map { .device($0.id) } : [.thisMac]
    }

    /// 存下來的選擇已不存在（裝置被刪除）或第二層關閉時，退回預設：有第二層時「所有電腦」
    public func resolve(_ scope: TokenDeviceScope?) -> TokenDeviceScope {
        guard enabled else { return .thisMac }
        guard let scope, scopes.contains(scope) else { return .all }
        return scope
    }

    public func title(_ scope: TokenDeviceScope) -> String {
        switch scope {
        case .thisMac: "這台 Mac"
        case .all: "所有電腦（\(count) 台）"
        case let .device(id): others.first { $0.id == id }?.name ?? "其他電腦"
        }
    }

    /// 切換選單裡的一項：其他電腦超過 48 小時沒有上傳時加上「N 天前更新」
    public func menuTitle(_ scope: TokenDeviceScope, now: Date) -> String {
        guard case let .device(id) = scope, let device = others.first(where: { $0.id == id }),
              let note = Self.staleNote(device, now: now) else { return title(scope) }
        return "\(device.name)（\(note)）"
    }

    /// 撤銷了密鑰（保留資料）：「已撤銷」；超過 48 小時沒有上傳：「N 天前更新」；從未上傳：「尚未上傳」；
    /// 其他為 nil。合計仍包含它已上傳的資料
    public static func staleNote(_ device: TokenDevice, now: Date) -> String? {
        if device.revoked { return "已撤銷" }
        guard let last = device.lastUpload else { return "尚未上傳" }
        let age = now.timeIntervalSince(last)
        return age > staleAfter ? "\(Int(age / 86400)) 天前更新" : nil
    }

    /// 最後上傳時間（說明文字用）：剛剛／N 小時前／N 天前
    public static func uploadText(_ device: TokenDevice, now: Date) -> String {
        guard let last = device.lastUpload else { return "尚未上傳" }
        let age = max(now.timeIntervalSince(last), 0)
        if age < 3600 { return "剛剛上傳" }
        if age < 86400 { return "\(Int(age / 3600)) 小時前上傳" }
        return "\(Int(age / 86400)) 天前上傳"
    }

    public static let thisMacHelp = "只包含這台 Mac 上 Claude Code 與 Codex CLI 的對話紀錄（含它們的桌面 App 與編輯器外掛）。不包含 claude.ai 網頁、手機 App、其他電腦與雲端 session。額度 % 是整個帳號的數字。"

    /// 範圍標籤的滑鼠說明（ADR-0011 第 4 節）
    public func help(_ scope: TokenDeviceScope, now: Date) -> String {
        switch scope {
        case .thisMac:
            return Self.thisMacHelp
        case .all:
            let me = devices.first { $0.isSelf }.map { "這台 Mac（\(Self.uploadText($0, now: now))）" } ?? "這台 Mac"
            let list = [me] + others.map { "\($0.name)（\(Self.uploadText($0, now: now))）" }
            return "包含已安裝收集器的電腦：\(list.joined(separator: "、"))。其他電腦的數字是它們最後一次上傳的每日加總。"
                + "不包含 claude.ai 網頁、手機 App 與雲端 session。額度 % 是整個帳號的數字。"
        case let .device(id):
            guard let device = others.first(where: { $0.id == id }) else { return Self.thisMacHelp }
            return "只包含「\(device.name)」上傳的每日 Token（\(Self.uploadText(device, now: now))）。"
                + "不包含 claude.ai 網頁、手機 App 與雲端 session。額度 % 是整個帳號的數字。"
        }
    }
}

extension TokenStatsData {
    /// 依裝置範圍篩選。個人紀錄（`records`、`record_days`）與每小時資料只有這台 Mac 有：
    /// 所有電腦時個人紀錄改由每日資料計算（範圍是每日資料還在的期間）、每小時資料仍是這台 Mac 的；
    /// 其他電腦沒有每小時資料，也沒有首次掃描的進度。
    /// `dataFrom`（清除或延長保留期間留下的邊界）只描述這台 Mac 的資料：其他電腦的列清除後會重新下載
    /// （下載時已依保留期間刪除），所以只看一台其他電腦時不套用；所有電腦時本機那段確實沒有資料，維持邊界。
    public func scoped(_ scope: TokenDeviceScope) -> TokenStatsData {
        var result = self
        switch scope {
        case .thisMac:
            result.days = days.filter { $0.device == TokenDevices.local }
        case .all:
            result.records = [:]
            result.recordDays = [:]
        case let .device(id):
            result.days = days.filter { $0.device == id }
            result.records = [:]
            result.recordDays = [:]
            result.hours = []
            result.firstScanDone = true
            result.firstScanProgress = nil
            result.skippedLines = 0
            result.formatSuspect = false
            result.dataFrom = nil
        }
        return result
    }

    /// 空狀態的說明
    public static func emptyText(_ scope: TokenDeviceScope, devices: TokenDevices) -> String {
        switch scope {
        case .thisMac: "這台 Mac 還沒有 Claude Code 或 Codex CLI 的紀錄"
        case .all: "還沒有任何電腦的 Claude Code 或 Codex CLI 紀錄"
        case .device: "「\(devices.title(scope))」還沒有上傳 Token 統計"
        }
    }
}
