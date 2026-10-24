import Foundation

/// 畫面用的「現在」。截圖比對（`scripts/snapshots.sh`）要每次畫出一模一樣的畫面，
/// Debug 版本設了 `AUM_RENDER_NOW=<ISO 8601>` 時固定成那個時間；Release 版本永遠是真的現在。
public enum RenderClock {
    #if DEBUG
    public static let fixed: Date? = ProcessInfo.processInfo.environment["AUM_RENDER_NOW"].flatMap {
        ISO8601DateFormatter().date(from: $0)
    }
    #else
    public static let fixed: Date? = nil
    #endif

    public static var now: Date { fixed ?? Date() }
}
