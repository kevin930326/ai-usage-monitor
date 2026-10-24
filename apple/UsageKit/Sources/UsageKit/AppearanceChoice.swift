/// 外觀設定（FR-51 Mac、FR-52 iPhone）：跟隨系統（預設）、淺色、深色。
///
/// 只套用到 App 自己的畫面。Mac 的選單列圖示跟隨選單列本身；iPhone 的 Live Activity、動態島、
/// 主畫面與鎖定畫面小工具、手錶都由系統決定，不讀這個設定（所以只存在 App 自己的 UserDefaults，不放 App Group）。
public enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    /// App 自己的 UserDefaults 的鍵（Mac 與 iPhone 相同）
    public static let storageKey = "app.appearance"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "跟隨系統"
        case .light: "淺色"
        case .dark: "深色"
        }
    }

    /// 存的值認不得或沒有存過時為跟隨系統
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .system
    }
}
